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
      [name: "decisions-memory"]
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

  describe "when the packaged generalisation Reflection processes completed lensed representations" do
    test "then one related-memory episode search completes before generalisation inference begins" do
      parent = self()

      assert {:ok, _artefact} =
               Runner.run(generalisation(), ingestion(),
                 inference: fn request ->
                   if request.step.label == "inspect-related-information" do
                     send(parent, {:generalisation_inference, request.step.label})
                   end

                   output_for(request)
                 end
               )

      events =
        for _ <- 1..5 do
          receive do
            {:related_memory_search, _, _, _, :episodes, _, _} = search -> search
            {:generalisation_inference, _} = inference -> inference
          end
        end

      assert Enum.all?(Enum.take(events, 4), &match?({:related_memory_search, _, _, _, _, _, _}, &1))
      assert List.last(events) == {:generalisation_inference, "inspect-related-information"}
    end

    test "and the search query contains the content of every completed representation" do
      assert {:ok, _artefact} =
               Runner.run(generalisation(), ingestion(), inference: &output_for/1)

      assert_receive {:related_memory_search, _, _, query, :episodes, _, _}
      assert query =~ "Prefer explicit APIs"
      assert query =~ "Choose direct designs"
    end

    test "and the same search reads the `operator` Destination, the `global` Destination, and every Destination referenced by the represented Lenses" do
      assert {:ok, _artefact} =
               Runner.run(generalisation(), ingestion(), inference: &output_for/1)

      searches =
        for _ <- 1..4 do
          assert_receive {:related_memory_search, destination, _, _, :episodes, _, _}
          destination
        end

      assert MapSet.new(searches) ==
               MapSet.new(["operator", "global", "observations-memory", "decisions-memory"])

      refute_receive {:related_memory_search, _, _, _, _, _, _}
    end

    test "and stored generalisation artefacts returned from `global` are included alongside other related episodes" do
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
                "generalises_over" => []
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
                   send(parent, {:stored_information, request.stored_information})
                   output_for(request)
                 end
               )

      assert_receive {:stored_information, stored_information}

      assert Enum.any?(stored_information, fn
               %{destination: "global", episode: encoded} when is_binary(encoded) ->
                 Jason.decode!(encoded) == %{
                   "id" => "generalisation-artefact",
                   "reflection" => "generalisations",
                   "payload" => stored_generalisation.payload
                 }

               _ -> false
             end)

      assert Enum.any?(stored_information, fn
               %{destination: "observations-memory", episode: "A related observation"} ->
                 true

               _ ->
                 false
             end)
    end

    test "and inference receives every current representation separately from the returned stored information" do
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
            "Array<{ content: string; level: integer; generalises_over: Array<{ content: string; level: integer }> }>"
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
  end

  describe "when the packaged generalisation Reflection's related-memory search returns no stored information" do
    test "then generalisation inference still processes every current representation" do
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

  describe "if the packaged generalisation Reflection's related-memory search fails" do
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

  describe "when the packaged generalisation Reflection synthesises a generalisation > while no returned generalisation influences the new generalisation" do
    setup do
      put_stored_generalisation_response([
        %{"content" => "Prefer abstractions everywhere", "level" => 8}
      ])

      :ok
    end

    test "then the new generalisation has level one" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &output_for/1)

      assert [%{"level" => 1}] = artefact.payload["generalisations"]
    end

    test "and the new generalisation records no preceding generalisations" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &output_for/1)

      assert [%{"generalises_over" => []}] = artefact.payload["generalisations"]
    end
  end

  describe "when the packaged generalisation Reflection synthesises a generalisation > while one or more returned generalisations influence the new generalisation" do
    setup do
      put_stored_generalisation_response(
        influencing_generalisations() ++
          [%{"content" => "Prefer abstractions everywhere", "level" => 8}]
      )

      :ok
    end

    test "then the new generalisation's level is one greater than the highest influencing level" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &higher_level_output_for/1)

      assert [%{"level" => 5}] = artefact.payload["generalisations"]
    end

    test "and the new generalisation records the content and level of every influencing generalisation" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(),
                 inference: fn request ->
                   if request.step.label == "synthesise-artefact" do
                     assert request.directions =~
                              "Preserve each selected assessment's exact `generalises_over` content and level entries"
                   end

                   higher_level_output_for(request)
                 end
               )

      assert [%{"generalises_over" => preceding}] = artefact.payload["generalisations"]
      assert preceding == influencing_generalisations()
    end

    test "but the new generalisation records no returned generalisation that did not influence it" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &higher_level_output_for/1)

      assert [%{"generalises_over" => preceding}] = artefact.payload["generalisations"]
      refute Enum.any?(preceding, &(&1["content"] == "Prefer abstractions everywhere"))
    end
  end

  describe "when the packaged generalisation Reflection completes" do
    test "then its artefact payload contains an array of generalisations" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &output_for/1)

      assert is_list(artefact.payload["generalisations"])
    end

    test "and each stored generalisation contains exactly its content, level, and preceding generalisations" do
      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &output_for/1)

      assert [stored] = artefact.payload["generalisations"]
      assert MapSet.new(Map.keys(stored)) == MapSet.new(["content", "level", "generalises_over"])
    end

    test "and each stored preceding generalisation contains exactly the content and level returned by the related-memory search" do
      put_stored_generalisation_response(influencing_generalisations())

      assert {:ok, artefact} =
               Runner.run(generalisation(), ingestion(), inference: &higher_level_output_for/1)

      assert [%{"generalises_over" => preceding}] = artefact.payload["generalisations"]
      assert preceding == influencing_generalisations()

      assert Enum.all?(preceding, fn item ->
               MapSet.new(Map.keys(item)) == MapSet.new(["content", "level"])
             end)
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

  defp output_for(%{step: %{label: "inspect-related-information"}}) do
    {:ok,
     %{
       output: %{
         "candidates" => [
           %{
             "content" => "Prefer direct APIs",
             "generalises_over" => [],
             "rationale" => "Both representations support it"
           }
         ]
       }
     }}
  end

  defp output_for(%{step: %{label: "evaluate-durability"}}) do
    {:ok,
     %{
       output: %{
         "assessments" => [
           %{
             "content" => "Prefer direct APIs",
             "generalises_over" => [],
             "durable" => true,
             "reasoning" => "It applies repeatedly"
           }
         ]
       }
     }}
  end

  defp output_for(%{step: %{label: "synthesise-artefact"}}) do
    {:ok,
     %{
       output: %{
         "generalisations" => [
           %{"content" => "Prefer direct APIs", "level" => 99, "generalises_over" => []}
         ]
       }
     }}
  end

  defp higher_level_output_for(%{step: %{label: "inspect-related-information"}} = request) do
    {:ok,
     %{
       output: %{
         "candidates" => [
           %{
             "content" => "Prefer the smallest explicit interface",
             "generalises_over" => selected_influences(request.stored_information),
             "rationale" => "It generalises both earlier interface lessons"
           }
         ]
       }
     }}
  end

  defp higher_level_output_for(%{step: %{label: "evaluate-durability"}} = request) do
    {:ok,
     %{
       output: %{
         "assessments" => [
           %{
             "content" => "Prefer the smallest explicit interface",
             "generalises_over" => selected_influences(request.stored_information),
             "durable" => true,
             "reasoning" => "It remains useful across interface designs"
           }
         ]
       }
     }}
  end

  defp higher_level_output_for(%{step: %{label: "synthesise-artefact"}} = request) do
    {:ok,
     %{
       output: %{
         "generalisations" => [
           %{
             "content" => "Prefer the smallest explicit interface",
             "level" => 99,
             "generalises_over" => selected_influences(request.stored_information)
           }
         ]
       }
     }}
  end

  defp influencing_generalisations do
    [
      %{"content" => "Prefer explicit APIs", "level" => 1},
      %{"content" => "Keep public interfaces small", "level" => 4}
    ]
  end

  defp put_stored_generalisation_response(generalisations) do
    stored = Enum.map(generalisations, &Map.put(&1, "generalises_over", []))

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
    |> Enum.flat_map(fn
      %{destination: "global", episode: %{content: content}} ->
        stored_generalisations(content)

      %{destination: "global", episode: content} when is_binary(content) ->
        stored_generalisations(content)

      _ ->
        []
    end)
    |> Enum.filter(&MapSet.member?(selected_contents, &1["content"]))
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

  defp restore_env({key, nil}), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env({key, value}), do: Application.put_env(:jido_gralkor, key, value)
end
