defmodule Gralkor.GeneralisationReflectionFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Reflection.Runner

  defmodule GeneralisationConsumerAgent do
    use Jido.Agent,
      name: "generalisation_reflection_consumer",
      default_plugins: false,
      plugins: [
        {JidoGralkor.Plugin,
         %{
           agent_name: "Generalisation Reflection Consumer",
           capture_destination: "personal",
           runtime_config: %{
             destinations: [
               %{name: "observations-memory"},
               %{name: "decisions-memory"},
               %{name: "unrepresented-memory"}
             ],
             lenses: [
               %{
                 name: "observations",
                 destination: "observations-memory",
                 write: :append,
                 ingestion: Gralkor.Lens.Ingestion.Store
               },
               %{
                 name: "decisions",
                 destination: "decisions-memory",
                 write: :append,
                 ingestion: Gralkor.Lens.Ingestion.Store
               }
             ],
             reflections: []
           }
         }}
      ]
  end

  defmodule SearchStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def put_artefact(_output, _reflection_name, _operator_id, artefact) do
      send(test_pid(), {:generalisation_delivered, artefact})
      :ok
    end

    @impl true
    def get_artefact(_output, _reflection_name, _operator_id, _artefact_id),
      do: {:error, :not_found}

    @impl true
    def search(destination, operator_id, query, result_type, max_results, opts) do
      send(test_pid(), {
        :related_memory_search,
        destination.name,
        operator_id,
        query,
        result_type,
        max_results,
        opts
      })

      responses = Application.fetch_env!(:jido_gralkor, :generalisation_search_responses)
      Map.get(responses, destination.name, {:ok, []})
    end

    defp test_pid, do: Application.fetch_env!(:jido_gralkor, :generalisation_test_pid)
  end

  defmodule UnavailableGlobalMemoryStorage do
    @behaviour Gralkor.Destination.Storage

    alias Gralkor.Destination.Storage.InMemory

    @impl true
    def put_artefact(output, reflection_name, operator_id, artefact),
      do: InMemory.put_artefact(output, reflection_name, operator_id, artefact)

    @impl true
    def get_artefact(output, reflection_name, operator_id, artefact_id),
      do: InMemory.get_artefact(output, reflection_name, operator_id, artefact_id)

    @impl true
    def search(%{name: "global"}, _operator_id, _query, _result_type, _max_results, _opts),
      do: {:error, :memory_unavailable}

    def search(destination, operator_id, query, result_type, max_results, opts),
      do: InMemory.search(destination, operator_id, query, result_type, max_results, opts)
  end

  setup do
    keys = [
      :destination_storage,
      :generalisation_search_responses,
      :generalisation_test_pid,
      :lens_storage
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})

    Application.put_env(:jido_gralkor, :destination_storage, SearchStorage)
    Application.put_env(:jido_gralkor, :generalisation_search_responses, %{})
    Application.put_env(:jido_gralkor, :generalisation_test_pid, self())

    on_exit(fn -> Enum.each(previous, &restore_env/1) end)
  end

  describe "when the packaged generalisation Reflection inspects a completed ingestion" do
    test "then one default related-memory episode search completes before generalisation inference begins" do
      parent = self()

      assert %{outcome: :delivered} =
               reflect!(start_agent(), fn request ->
                 if request.step.label == "inspect-world" do
                   send(parent, {:generalisation_inference, request.step.label})
                 end

                 output_for(request)
               end)

      events =
        for _ <- 1..6 do
          receive do
            {:related_memory_search, _, _, _, :episodes, _, _} = search -> search
            {:generalisation_inference, _} = inference -> inference
          end
        end

      assert Enum.all?(
               Enum.take(events, 5),
               &match?({:related_memory_search, _, _, _, _, _, _}, &1)
             )

      assert List.last(events) == {:generalisation_inference, "inspect-world"}
    end

    test "and the search query contains the content of every completed representation" do
      assert %{outcome: :delivered} = reflect!(start_agent(), &output_for/1)

      assert_receive {:related_memory_search, _, "operator-one", query, :episodes, _, _}
      assert query =~ "Prefer explicit APIs"
      assert query =~ "Choose direct designs"
    end

    test "and the same search reads every accessible registered Destination" do
      assert %{outcome: :delivered} = reflect!(start_agent(), &output_for/1)

      searches =
        for _ <- 1..5 do
          assert_receive {:related_memory_search, destination, _, _, :episodes, _, _}
          destination
        end

      assert MapSet.new(searches) ==
               MapSet.new([
                 "personal",
                 "global",
                 "observations-memory",
                 "decisions-memory",
                 "unrepresented-memory"
               ])

      refute_receive {:related_memory_search, _, _, _, _, _, _}
    end

    test "and every related observation identifies its originating Lens" do
      {_stored_generalisation, stored_information} = stored_information_from_real_memory()

      observations =
        Enum.filter(stored_information, &(Map.get(&1.episode, :reflection) == nil))

      assert Enum.sort(Enum.map(observations, &{&1.destination, &1.episode.content})) == [
               {"decisions-memory", "A related decision"},
               {"observations-memory", "A related observation"}
             ]

      assert Enum.all?(observations, fn
               %{destination: "observations-memory", episode: %{lens: "observations"}} -> true
               %{destination: "decisions-memory", episode: %{lens: "decisions"}} -> true
               _ -> false
             end)
    end

    test "and related-memory results distinguish prior generalisations from Lens-authored observations" do
      {stored_generalisation, stored_information} = stored_information_from_real_memory()

      assert Enum.any?(stored_information, fn
               %{
                 destination: "global",
                 episode: %{reflection: "generalisations"} = episode
               } ->
                 decode_episode(episode) == %{
                   "id" => "generalisation-artefact",
                   "payload" => stored_generalisation.payload
                 }

               _ ->
                 false
             end)
    end

    test "and inference receives every current representation separately from related observations and generalisations" do
      Application.put_env(:jido_gralkor, :generalisation_search_responses, %{
        "global" => {:ok, [%{content: "stored", source_description: "global"}]}
      })

      parent = self()

      assert %{outcome: :delivered} =
               reflect!(start_agent(), fn request ->
                 send(
                   parent,
                   {:inference_inputs, request.representations, request.stored_information}
                 )

                 output_for(request)
               end)

      assert_receive {:inference_inputs, representations, stored_information}
      assert Enum.map(representations, & &1.id) == ["representation-one", "representation-two"]
      assert [%{destination: "global", episode: %{content: "stored"}}] = stored_information

      prompt_stored_information = [
        %{destination: "global", episode: %{content: "A prior generalisation"}}
      ]

      request = %{
        directions: "Synthesize a generalisation.",
        operator_id: "operator-one",
        output_schema: %{
          "generalisations" =>
            "Array<{ content: string; level: integer; evolves_from: Array<{ content: string; level: integer }> }>"
        },
        representations: ingestion().representations,
        stored_information: prompt_stored_information,
        tool_context: %{},
        tools: []
      }

      call = fn prompt, _config, _opts ->
        send(self(), {:default_inference_prompt, prompt})
        %{termination_reason: :final_answer, result: Jason.encode!(%{"generalisations" => []})}
      end

      assert {:ok, %{output: %{"generalisations" => []}}} =
               Runner.default_inference(request, call)

      assert_receive {:default_inference_prompt, prompt}
      assert prompt =~ "Lensed representations available"
      assert prompt =~ "Prefer explicit APIs"
      assert prompt =~ "Related stored information available"
      assert prompt =~ "A prior generalisation"
    end

    test "and inference is directed to revisit current and related observations together with prior generalisations" do
      directions = step_directions("inspect-world")

      assert normalized_whitespace(directions) =~
               "Revisit current and related observations together with prior generalisations"
    end

    test "and inference is directed to carry forward, combine, broaden, narrow, split, replace, or otherwise revise generalisations as observations warrant" do
      directions =
        "evolve-generalisations"
        |> step_directions()
        |> normalized_whitespace()
        |> String.downcase()

      for operation <- [
            "carry forward",
            "combine",
            "broaden",
            "narrow",
            "split",
            "replace",
            "otherwise revise"
          ] do
        assert directions =~ operation
      end
    end

    test "and inference is directed to give a new generalisation level one and an evolved generalisation one level above its highest lineage snapshot" do
      directions =
        "evolve-generalisations"
        |> step_directions()
        |> normalized_whitespace()
        |> String.downcase()

      assert directions =~ "new generalisation with no lineage uses level 1"
      assert directions =~ "one greater than the highest level in its evolves_from snapshots"
    end

    test "and inference is directed to provide non-blank content for every current generalisation and lineage snapshot" do
      directions =
        "evolve-generalisations"
        |> step_directions()
        |> normalized_whitespace()
        |> String.downcase()

      assert directions =~ "non-blank content"
      assert directions =~ "every current generalisation and lineage snapshot"
    end
  end

  describe "when the packaged generalisation Reflection's default related-memory search returns no stored information" do
    test "then generalisation inference still inspects every current representation" do
      parent = self()

      assert %{outcome: :delivered} =
               reflect!(start_agent(), fn request ->
                 send(
                   parent,
                   {:empty_search_inference, request.representations,
                    request.stored_information}
                 )

                 output_for(request)
               end)

      assert_receive {:empty_search_inference, representations, []}
      assert Enum.map(representations, & &1.id) == ["representation-one", "representation-two"]
    end
  end

  describe "if the packaged generalisation Reflection's default related-memory search fails" do
    test "then the Reflection fails before generalisation inference begins and identifies the search failure" do
      Application.put_env(:jido_gralkor, :generalisation_search_responses, %{
        "global" => {:error, :memory_unavailable}
      })

      parent = self()

      assert %{
               outcome:
                 {:production_failed,
                  %{
                    reflection: "generalisations",
                    reason: {:related_memory_search, :memory_unavailable}
                  }}
             } = reflect!(start_agent(), fn _ -> send(parent, :inference) end)

      refute_receive :inference
    end

    test "and the completed ingestion remains unchanged" do
      use_real_memory()
      Application.put_env(:jido_gralkor, :destination_storage, UnavailableGlobalMemoryStorage)
      agent = start_agent()
      ingest_representations!(agent)
      before = representation_memory(agent)

      assert Enum.sort(Enum.map(before, & &1.episode.content)) == [
               "Choose direct designs",
               "Prefer explicit APIs"
             ]

      assert %{
               outcome:
                 {:production_failed,
                  %{reason: {:related_memory_search, :memory_unavailable}}}
             } = reflect!(agent, &output_for/1)

      assert representation_memory(agent) == before
    end
  end

  describe "when the packaged generalisation Reflection synthesises an evolved generalisation > while its output satisfies the declared structured types" do
    test "then its model-produced values are preserved without comparison to related memory" do
      put_stored_generalisation_response([
        %{"content" => "A stored but unrelated generalisation", "level" => 8}
      ])

      produced = %{
        "content" => "Use the narrowest sufficient boundary",
        "level" => 73,
        "evolves_from" => [
          %{"content" => "A model-selected historical snapshot", "level" => 41}
        ]
      }

      assert %{outcome: :delivered, artefact: artefact} =
               reflect!(start_agent(), &direct_generalisation_output(&1, produced))

      assert artefact.payload == %{"generalisations" => [produced]}
    end
  end

  describe "when the packaged generalisation Reflection synthesises an evolved generalisation > while the evolved generalisation replaces a prior generalisation" do
    test "then the replaced generalisation remains searchable as historical lineage" do
      use_real_memory()
      agent = start_agent()

      prior =
        Gralkor.Artefact.new("prior-generalisation", %{
          "generalisations" => [
            %{"content" => "Use one API everywhere", "level" => 1, "evolves_from" => []}
          ]
        })

      assert :ok = put_prior_generalisation("operator-one", prior)

      assert %{outcome: :delivered, artefact: replacement} =
               reflect!(agent, &replacement_output_for/1)

      assert [
               %{
                 "evolves_from" => [
                   %{"content" => "Use one API everywhere", "level" => 1}
                 ]
               }
             ] = replacement.payload["generalisations"]

      assert {:ok, results} =
               Client.search(agent, %Gralkor.Search{
                 operator_id: "operator-one",
                 query: "generalisation",
                 destinations: ["global"],
                 result_type: :artefacts
               })

      assert Enum.sort(Enum.map(results, & &1.artefact.id)) ==
               Enum.sort(["prior-generalisation", replacement.id])

      assert Enum.find(results, &(&1.artefact.id == "prior-generalisation")).artefact == prior
    end
  end

  describe "when the packaged generalisation Reflection completes" do
    test "then its artefact payload contains an array of generalisations" do
      assert %{outcome: :delivered, artefact: artefact} = reflect!(start_agent(), &output_for/1)

      assert is_list(artefact.payload["generalisations"])
    end

    test "and each returned generalisation contains exactly `content`, `level`, and `evolves_from`" do
      assert %{outcome: :delivered, artefact: artefact} = reflect!(start_agent(), &output_for/1)

      assert [stored] = artefact.payload["generalisations"]
      assert MapSet.new(Map.keys(stored)) == MapSet.new(["content", "level", "evolves_from"])
    end

    test "and the structured evolution is normalized directly into the artefact without a redundant synthesis inference" do
      put_stored_generalisation_response(influencing_generalisations())
      parent = self()

      assert %{outcome: :delivered, artefact: artefact} =
               reflect!(start_agent(), fn request ->
                 send(parent, {:inference_step, request.step.label})
                 higher_level_output_for(request)
               end)

      assert [
               %{
                 "content" => "Prefer the smallest explicit interface",
                 "level" => 5,
                 "evolves_from" => snapshots
               }
             ] = artefact.payload["generalisations"]

      assert snapshots == influencing_generalisations()
      assert_receive {:inference_step, "inspect-world"}
      assert_receive {:inference_step, "evolve-generalisations"}
      refute_receive {:inference_step, "synthesise-artefact"}
    end

    test "and later evolution leaves every earlier returned lineage snapshot unchanged" do
      use_real_memory()
      agent = start_agent()

      influencing =
        Gralkor.Artefact.new("influencing-generalisations", %{
          "generalisations" => Enum.map(influencing_generalisations(), &Map.put(&1, "evolves_from", []))
        })

      assert :ok = put_prior_generalisation("operator-one", influencing)

      assert %{outcome: :delivered, artefact: earlier} =
               reflect!(agent, &higher_level_output_for/1, ingestion("earlier-ingestion"))

      assert [%{"evolves_from" => earlier_snapshots}] = earlier.payload["generalisations"]
      assert earlier_snapshots == influencing_generalisations()

      parent = self()

      assert %{outcome: :delivered, artefact: later} =
               reflect!(
                 agent,
                 fn request ->
                   send(parent, {:later_stored_information, request.stored_information})
                   all_prior_output_for(request)
                 end,
                 ingestion("later-ingestion")
               )

      assert_receive {:later_stored_information, later_stored_information}

      assert %{"content" => "Prefer the smallest explicit interface", "level" => 5} in prior_generalisation_snapshots(
               later_stored_information
             )

      refute later.id == earlier.id

      assert {:ok, results} =
               Client.search(agent, %Gralkor.Search{
                 operator_id: "operator-one",
                 query: "generalisation",
                 destinations: ["global"],
                 result_type: :artefacts,
                 artefact_id: earlier.id
               })

      assert [%{artefact: stored_earlier}] = results
      assert stored_earlier == earlier
      assert [%{"evolves_from" => stored_snapshots}] = stored_earlier.payload["generalisations"]
      assert stored_snapshots == influencing_generalisations()
    end
  end

  defp start_agent do
    id = "generalisation-#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Jido.AgentServer, agent: GeneralisationConsumerAgent, id: id, register_global: false},
        id: {:generalisation_agent, id}
      )
    )
  end

  defp reflect!(agent, inference, invocation \\ ingestion()) do
    test_pid = self()
    reference = make_ref()
    invocation_id = invocation.id

    assert {:ok, ^invocation_id} =
             Client.reflect(
               agent,
               "generalisations",
               invocation,
               &send(test_pid, {reference, &1}),
               inference: inference
             )

    assert_receive {^reference, %{invocation_id: ^invocation_id} = result}, 5_000
    result
  end

  defp ingestion(id \\ "ingestion-one") do
    %{
      id: id,
      operator_id: "operator-one",
      representations: [
        %{
          id: "representation-one",
          lens: "observations",
          content: "Prefer explicit APIs",
          result: :ok
        },
        %{
          id: "representation-two",
          lens: "decisions",
          content: "Choose direct designs",
          result: :ok
        }
      ]
    }
  end

  defp ingest_representations!(agent) do
    for representation <- ingestion().representations do
      assert :ok =
               Client.ingest(agent, %Gralkor.Ingest{
                 id: representation.id,
                 operator_id: "operator-one",
                 lens: representation.lens,
                 source_kind: :document,
                 content: representation.content,
                 source_description: representation.lens
               })
    end
  end

  defp representation_memory(agent) do
    assert {:ok, results} =
             Client.search(agent, %Gralkor.Search{
               operator_id: "operator-one",
               query: "",
               destinations: ["observations-memory", "decisions-memory"],
               result_type: :episodes
             })

    results
  end

  defp output_for(request),
    do: evolved_output(request, "Prefer direct APIs", 1, [])

  defp higher_level_output_for(request) do
    evolved_output(
      request,
      "Prefer the smallest explicit interface",
      5,
      selected_influences(request.stored_information)
    )
  end

  defp all_prior_output_for(request) do
    evolved_output(
      request,
      "Apply the smallest explicit interface at each boundary",
      6,
      prior_generalisation_snapshots(request.stored_information)
    )
  end

  defp replacement_output_for(request) do
    evolved_output(
      request,
      "Use one explicit API for each distinct boundary",
      2,
      prior_generalisation_snapshots(request.stored_information)
    )
  end

  defp evolved_output(%{step: %{label: "inspect-world"}}, _content, _level, _snapshots) do
    {:ok,
     %{
       output: %{
         "inspection" => "Current and related observations qualify the prior generalisations."
       }
     }}
  end

  defp evolved_output(
         %{step: %{label: "evolve-generalisations"}},
         content,
         level,
         snapshots
       ) do
    {:ok,
     %{
       output: %{
         "generalisations" => [
           %{
             "content" => content,
             "level" => level,
             "evolves_from" => snapshots
           }
         ]
       }
     }}
  end

  defp direct_generalisation_output(%{step: %{label: "inspect-world"}}, _produced),
    do: output_for(%{step: %{label: "inspect-world"}})

  defp direct_generalisation_output(%{step: %{label: "evolve-generalisations"}}, produced),
    do: {:ok, %{output: %{"generalisations" => [produced]}}}

  defp influencing_generalisations do
    [
      %{"content" => "Prefer explicit APIs", "level" => 1},
      %{"content" => "Keep public interfaces small", "level" => 4}
    ]
  end

  defp put_stored_generalisation_response(generalisations) do
    stored = Enum.map(generalisations, &Map.put(&1, "evolves_from", []))

    Application.put_env(:jido_gralkor, :generalisation_search_responses, %{
      "global" =>
        {:ok,
         [
           %{
             artefact: %{
               id: "stored-generalisation-artefact",
               payload: %{"generalisations" => stored}
             },
             reflection: "generalisations"
           }
         ]}
    })
  end

  defp selected_influences(stored_information) do
    selected_contents = MapSet.new(Enum.map(influencing_generalisations(), & &1["content"]))

    stored_information
    |> prior_generalisation_snapshots()
    |> Enum.filter(&MapSet.member?(selected_contents, &1["content"]))
    |> Enum.map(&Map.take(&1, ["content", "level"]))
  end

  defp prior_generalisation_snapshots(stored_information) do
    stored_information
    |> Enum.flat_map(fn
      %{
        destination: "global",
        episode: %{artefact: %{payload: %{"generalisations" => generalisations}}}
      } ->
        generalisations

      _ ->
        []
    end)
    |> Enum.map(&Map.take(&1, ["content", "level"]))
  end

  defp step_directions(label) do
    parent = self()

    assert %{outcome: :delivered} =
             reflect!(start_agent(), fn request ->
               if request.step.label == label do
                 send(parent, {:step_directions, label, request.directions})
               end

               output_for(request)
             end)

    assert_receive {:step_directions, ^label, directions}
    directions
  end

  defp stored_information_from_real_memory do
    use_real_memory()
    agent = start_agent()

    for {lens, content} <- [
          {"observations", "A related observation"},
          {"decisions", "A related decision"}
        ] do
      assert :ok =
               Client.ingest(agent, %Gralkor.Ingest{
                 id: "seed-#{lens}",
                 operator_id: "operator-one",
                 lens: lens,
                 source_kind: :document,
                 content: content,
                 source_description: lens
               })
    end

    stored_generalisation =
      Gralkor.Artefact.new("generalisation-artefact", %{
        "generalisations" => [
          %{
            "content" => "Prefer small public APIs",
            "level" => 1,
            "evolves_from" => []
          }
        ]
      })

    assert :ok = put_prior_generalisation("operator-one", stored_generalisation)

    parent = self()

    assert %{outcome: :delivered} =
             reflect!(agent, fn request ->
               if request.step.label == "inspect-world" do
                 send(parent, {:stored_information, request.stored_information})
               end

               output_for(request)
             end)

    assert_receive {:stored_information, stored_information}
    {stored_generalisation, stored_information}
  end

  defp use_real_memory do
    start_supervised!(Gralkor.Lens.Storage.InMemory)
    start_supervised!(Gralkor.Destination.Storage.InMemory)

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.InMemory
    )

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)
  end

  defp decode_episode(%{artefact: artefact}),
    do: %{"id" => artefact.id, "payload" => artefact.payload}

  defp put_prior_generalisation(operator_id, artefact) do
    Gralkor.Destination.Storage.put_artefact(
      %{
        kind: :destination,
        destination: %Gralkor.Destination{name: "global"},
        ontology: Gralkor.DefaultOntology
      },
      "generalisations",
      operator_id,
      artefact
    )
  end

  defp normalized_whitespace(value), do: String.replace(value, ~r/\s+/, " ")

  defp restore_env({key, nil}), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env({key, value}), do: Application.put_env(:jido_gralkor, key, value)
end
