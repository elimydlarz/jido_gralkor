defmodule Gralkor.GeneralisationReflectionFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Reflection.Registry
  alias Gralkor.Reflection.Runner

  defmodule Ingestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(_, _), do: :ok
  end

  defmodule SearchStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, operator_id, query, result_type, max_results, opts) do
      test_pid = Application.fetch_env!(:jido_gralkor, :generalisation_test_pid)

      send(test_pid, {
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
  end

  setup do
    keys = [
      :destinations,
      :destination_storage,
      :generalisation_search_responses,
      :generalisation_test_pid,
      :lens_storage,
      :lenses,
      :reflection_storage,
      :reflections
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "observations-memory"],
      [name: "decisions-memory"],
      [name: "unrepresented-memory"]
    ])

    Application.put_env(:jido_gralkor, :destination_storage, SearchStorage)
    Application.put_env(:jido_gralkor, :generalisation_search_responses, %{})
    Application.put_env(:jido_gralkor, :generalisation_test_pid, self())

    Application.put_env(:jido_gralkor, :lenses, [
      [name: "observations", destination: "observations-memory", ingestion: Ingestion],
      [name: "decisions", destination: "decisions-memory", ingestion: Ingestion]
    ])

    Application.delete_env(:jido_gralkor, :reflections)

    on_exit(fn -> Enum.each(previous, &restore_env/1) end)
  end

  describe "when the packaged generalisation Reflection inspects a completed ingestion" do
    test "then one default related-memory episode search completes before generalisation inference begins" do
      parent = self()

      assert {:ok, _artefact} =
               Runner.run(generalisation(), ingestion(),
                 inference: fn request ->
                   if request.step.label == "inspect-world" do
                     send(parent, {:generalisation_inference, request.step.label})
                   end

                   output_for(request)
                 end
               )

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
      assert {:ok, _artefact} =
               Runner.run(generalisation(), ingestion(), inference: &output_for/1)

      assert_receive {:related_memory_search, _, _, query, :episodes, _, _}
      assert query =~ "Prefer explicit APIs"
      assert query =~ "Choose direct designs"
    end

    test "and the same search reads every accessible registered Destination" do
      assert {:ok, _artefact} =
               Runner.run(generalisation(), ingestion(), inference: &output_for/1)

      searches =
        for _ <- 1..5 do
          assert_receive {:related_memory_search, destination, _, _, :episodes, _, _}
          destination
        end

      assert MapSet.new(searches) ==
               MapSet.new([
                 "operator",
                 "global",
                 "observations-memory",
                 "decisions-memory",
                 "unrepresented-memory"
               ])

      refute_receive {:related_memory_search, _, _, _, _, _, _}
    end

    test "and every related observation identifies its originating Lens" do
      {_stored_generalisation, stored_information} = stored_information_from_real_memory()

      assert Enum.any?(stored_information, fn
               %{
                 destination: "observations-memory",
                 episode: %{content: "A related observation", lens: "observations"}
               } ->
                 true

               _ ->
                 false
             end)
    end

    test "and every related generalisation identifies its declaring Reflection" do
      {stored_generalisation, stored_information} = stored_information_from_real_memory()

      assert Enum.any?(stored_information, fn
               %{destination: "global", episode: episode} ->
                 decode_episode(episode) == %{
                   "id" => "generalisation-artefact",
                   "reflection" => "generalisations",
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

      assert {:ok, _artefact} =
               Runner.run(generalisation(), ingestion(),
                 inference: fn request ->
                   send(
                     parent,
                     {:inference_inputs, request.representations, request.stored_information}
                   )

                   output_for(request)
                 end
               )

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

      call = fn _action, params, _context ->
        send(self(), {:default_inference_prompt, params.prompt})
        {:ok, %{text: Jason.encode!(%{"generalisations" => []})}}
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
      directions = first_step_directions()

      assert directions =~ "Revisit current and related observations together with prior generalisations"
    end

    test "and inference is directed to carry forward, combine, broaden, narrow, split, replace, or otherwise revise generalisations as observations warrant" do
      directions = first_step_directions()

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
  end

  describe "when the packaged generalisation Reflection's default related-memory search returns no stored information" do
    test "then generalisation inference still inspects every current representation" do
      parent = self()

      assert {:ok, _artefact} =
               Runner.run(generalisation(), ingestion(),
                 inference: fn request ->
                   send(
                     parent,
                     {:empty_search_inference, request.representations,
                      request.stored_information}
                   )

                   output_for(request)
                 end
               )

      assert_receive {:empty_search_inference, representations, []}
      assert Enum.map(representations, & &1.id) == ["representation-one", "representation-two"]
    end
  end

  describe "if the packaged generalisation Reflection's default related-memory search fails" do
    test "then the Reflection fails before generalisation inference begins and identifies the search failure" do
      Application.put_env(:jido_gralkor, :generalisation_search_responses, %{
        "global" => {:error, :memory_unavailable}
      })

      assert {:error,
              %{
                reflection: "generalisations",
                reason: {:related_memory_search, :memory_unavailable}
              }} =
               Runner.run(generalisation(), ingestion(),
                 inference: fn _ -> send(self(), :inference) end
               )

      refute_receive :inference
    end

    test "and the completed ingestion remains unchanged" do
      Application.put_env(:jido_gralkor, :generalisation_search_responses, %{
        "global" => {:error, :memory_unavailable}
      })

      completed_ingestion = ingestion()

      assert {:error, _} =
               Runner.run(generalisation(), completed_ingestion, inference: &output_for/1)

      assert completed_ingestion == ingestion()
    end
  end

  describe "when the packaged generalisation Reflection synthesises an evolved generalisation > while no returned prior generalisation influences the evolved generalisation" do
    setup do
      put_stored_generalisation_response([
        %{"content" => "Prefer abstractions everywhere", "level" => 8}
      ])

      :ok
    end

    test "then the evolved generalisation has evolution-depth level one" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &output_for/1)

      assert [%{"level" => 1}] = artefact.payload["generalisations"]
    end

    test "and the evolved generalisation's `evolves_from` is empty" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &output_for/1)

      assert [%{"evolves_from" => []}] = artefact.payload["generalisations"]
    end
  end

  describe "when the packaged generalisation Reflection synthesises an evolved generalisation > while one or more returned prior generalisations influence the evolved generalisation" do
    setup do
      put_stored_generalisation_response(
        influencing_generalisations() ++
          [%{"content" => "Prefer abstractions everywhere", "level" => 8}]
      )

      :ok
    end

    test "then the evolved generalisation's evolution-depth level is one greater than the highest influencing level" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &higher_level_output_for/1)

      assert [%{"level" => 5}] = artefact.payload["generalisations"]
    end

    test "and `evolves_from` records the content and level of every influencing prior generalisation" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(),
                 inference: &ancestry_preserving_output_for/1
               )

      assert [%{"evolves_from" => snapshots}] = artefact.payload["generalisations"]
      assert snapshots == influencing_generalisations()
    end

    test "but `evolves_from` records no returned generalisation that did not influence the evolution" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &higher_level_output_for/1)

      assert [%{"evolves_from" => snapshots}] = artefact.payload["generalisations"]
      refute Enum.any?(snapshots, &(&1["content"] == "Prefer abstractions everywhere"))
    end
  end

  describe "when the packaged generalisation Reflection synthesises an evolved generalisation > while the evolved generalisation replaces a prior generalisation" do
    test "then the replaced generalisation remains searchable as historical lineage" do
      use_real_memory()

      prior =
        Gralkor.Reflection.Artefact.new(
          "prior-generalisation",
          "generalisations",
          %{
            "generalisations" => [
              %{"content" => "Use one API everywhere", "level" => 1, "evolves_from" => []}
            ]
          }
        )

      assert :ok = Gralkor.Reflection.Store.put(generalisation(), "operator-one", prior)

      assert {:ok, replacement} =
               Runner.run(generalisation(), ingestion(),
                 inference: &replacement_output_for/1,
                 artefact_id: "replacement-generalisation"
               )

      assert :ok =
               Gralkor.Reflection.Store.put(generalisation(), "operator-one", replacement)

      assert {:ok, results} =
               Gralkor.Client.search(%Gralkor.Search{
                 operator_id: "operator-one",
                 query: "generalisation",
                 destinations: ["global"],
                 result_type: :artefacts
               })

      assert Enum.any?(results, &match?(%{artefact: %{id: "prior-generalisation"}}, &1))
      assert Enum.any?(results, &match?(%{artefact: %{id: "replacement-generalisation"}}, &1))
    end
  end

  describe "when the packaged generalisation Reflection completes" do
    test "then its artefact payload contains an array of generalisations" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &output_for/1)

      assert is_list(artefact.payload["generalisations"])
    end

    test "and each stored generalisation contains exactly `content`, `level`, and `evolves_from`" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &output_for/1)

      assert [stored] = artefact.payload["generalisations"]
      assert MapSet.new(Map.keys(stored)) == MapSet.new(["content", "level", "evolves_from"])
    end

    test "and each stored `evolves_from` snapshot contains exactly the content and level returned by related-memory search" do
      put_stored_generalisation_response(influencing_generalisations())

      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &higher_level_output_for/1)

      assert [%{"evolves_from" => snapshots}] = artefact.payload["generalisations"]
      assert snapshots == influencing_generalisations()

      assert Enum.all?(snapshots, fn item ->
               MapSet.new(Map.keys(item)) == MapSet.new(["content", "level"])
             end)
    end

    test "and later evolution leaves every earlier stored lineage snapshot unchanged" do
      put_stored_generalisation_response(influencing_generalisations())

      assert {:ok, earlier} =
               Runner.run(generalisation(), ingestion(), inference: &higher_level_output_for/1)

      earlier_payload = earlier.payload
      [%{"content" => earlier_content, "level" => earlier_level}] =
        earlier.payload["generalisations"]

      put_stored_generalisation_response([
        %{"content" => earlier_content, "level" => earlier_level}
      ])

      assert {:ok, _later} =
               Runner.run(generalisation(), ingestion(), inference: &all_prior_output_for/1)

      assert earlier.payload == earlier_payload
      assert [%{"evolves_from" => snapshots}] = earlier.payload["generalisations"]
      assert snapshots == influencing_generalisations()
    end
  end

  defp generalisation do
    Registry.configured!()
    |> Enum.find(&(&1.name == "generalisations"))
  end

  defp ingestion do
    %{
      id: "ingestion-one",
      operator_id: "operator-one",
      intended_lenses: ["observations", "decisions"],
      completed_lenses: ["observations", "decisions"],
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

  defp output_for(request),
    do: evolved_output(request, "Prefer direct APIs", [])

  defp higher_level_output_for(request) do
    evolved_output(
      request,
      "Prefer the smallest explicit interface",
      selected_influences(request.stored_information)
    )
  end

  defp all_prior_output_for(request) do
    evolved_output(
      request,
      "Apply the smallest explicit interface at each boundary",
      prior_generalisation_snapshots(request.stored_information)
    )
  end

  defp replacement_output_for(request) do
    evolved_output(
      request,
      "Use one explicit API for each distinct boundary",
      prior_generalisation_snapshots(request.stored_information)
    )
  end

  defp evolved_output(%{step: %{label: "inspect-world"}}, _content, _snapshots) do
    {:ok,
     %{
       output: %{
         "inspection" =>
           "Current and related observations qualify the prior generalisations."
       }
     }}
  end

  defp evolved_output(
         %{step: %{label: "evolve-generalisations"}},
         content,
         snapshots
       ) do
    {:ok,
     %{
       output: %{
         "evolutions" => [
           %{
             "content" => content,
             "evolves_from" => snapshots,
             "reasoning" => "The observations warrant this current generalisation."
           }
         ]
       }
     }}
  end

  defp evolved_output(%{step: %{label: "synthesise-artefact"}}, content, snapshots) do
    {:ok,
     %{
       output: %{
         "generalisations" => [
           %{"content" => content, "level" => 99, "evolves_from" => snapshots}
         ]
       }
     }}
  end

  defp ancestry_preserving_output_for(request) do
    if request.step.label == "synthesise-artefact" do
      assert request.directions =~ "Preserve each evolution's exact"
      assert request.directions =~ "`evolves_from` content and level snapshots"
    end

    higher_level_output_for(request)
  end

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
             content:
               Jason.encode!(%{
                 reflection: "generalisations",
                 payload: %{generalisations: stored}
               }),
             source_description: "reflection:generalisations"
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
      %{destination: "global", episode: %{content: content}} ->
        stored_generalisations(content)

      %{destination: "global", episode: content} when is_binary(content) ->
        stored_generalisations(content)

      _ ->
        []
    end)
    |> Enum.map(&Map.take(&1, ["content", "level"]))
  end

  defp stored_generalisations(content) do
    case Jason.decode(content) do
      {:ok, %{"payload" => %{"generalisations" => generalisations}}}
      when is_list(generalisations) ->
        generalisations

      _ ->
        []
    end
  end

  defp first_step_directions do
    parent = self()

    assert {:ok, _artefact} =
             Runner.run(generalisation(), ingestion(),
               inference: fn request ->
                 if request.step.label == "inspect-world" do
                   send(parent, {:first_step_directions, request.directions})
                 end

                 output_for(request)
               end
             )

    assert_receive {:first_step_directions, directions}
    directions
  end

  defp stored_information_from_real_memory do
    use_real_memory()

    observation_store = %Gralkor.Lens.Store{
      operator_id: "operator-one",
      lens: Gralkor.Client.lens!("observations")
    }

    assert :ok =
             Gralkor.Lens.Store.add(
               observation_store,
               "A related observation",
               "observations"
             )

    stored_generalisation =
      Gralkor.Reflection.Artefact.new(
        "generalisation-artefact",
        "generalisations",
        %{
          "generalisations" => [
            %{
              "content" => "Prefer small public APIs",
              "level" => 1,
              "evolves_from" => []
            }
          ]
        }
      )

    assert :ok =
             Gralkor.Reflection.Store.put(
               generalisation(),
               "operator-one",
               stored_generalisation
             )

    parent = self()

    assert {:ok, _artefact} =
             Runner.run(generalisation(), ingestion(),
               inference: fn request ->
                 if request.step.label == "inspect-world" do
                   send(parent, {:stored_information, request.stored_information})
                 end

                 output_for(request)
               end
             )

    assert_receive {:stored_information, stored_information}
    {stored_generalisation, stored_information}
  end

  defp use_real_memory do
    start_supervised!(Gralkor.Lens.Storage.InMemory)
    start_supervised!(Gralkor.Reflection.Storage.InMemory)

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.InMemory
    )

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

    Application.put_env(
      :jido_gralkor,
      :reflection_storage,
      Gralkor.Reflection.Storage.InMemory
    )
  end

  defp decode_episode(%{content: content}), do: Jason.decode!(content)
  defp decode_episode(content) when is_binary(content), do: Jason.decode!(content)

  defp restore_env({key, nil}), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env({key, value}), do: Application.put_env(:jido_gralkor, key, value)
end
