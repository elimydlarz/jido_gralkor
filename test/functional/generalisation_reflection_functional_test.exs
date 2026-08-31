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
      :lenses,
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
                   send(parent, {:generalisation_inference, request.step.label})
                   output_for(request)
                 end
               )

      assert_receive {:related_memory_search, _, _, _, :episodes, _, _}
      assert_receive {:generalisation_inference, _}
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
      stored_generalisation =
        Jason.encode!(%{
          id: "generalisation-artefact",
          reflection: "generalisations",
          payload: %{
            generalisations: [
              %{content: "Prefer small public APIs", level: 1, generalises_over: []}
            ]
          }
        })

      Application.put_env(:jido_gralkor, :generalisation_search_responses, %{
        "global" =>
          {:ok,
           [%{content: stored_generalisation, source_description: "reflection:generalisations"}]},
        "observations-memory" =>
          {:ok, [%{content: "A related observation", source_description: "observations"}]}
      })

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
               %{destination: "global", episode: %{content: ^stored_generalisation}} -> true
               _ -> false
             end)

      assert Enum.any?(stored_information, fn
               %{destination: "observations-memory", episode: %{content: "A related observation"}} ->
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
        %{id: "representation-one", evidence_id: "evidence-one", lens: "observations", content: "Prefer explicit APIs", result: :ok},
        %{id: "representation-two", evidence_id: "evidence-one", lens: "decisions", content: "Choose direct designs", result: :ok}
      ]
    }
  end

  defp output_for(%{step: %{label: "inspect-evidence"}}) do
    {:ok,
     %{
       output: %{
         "candidates" => [
           %{
             "statement" => "Prefer direct APIs",
             "evidence_ids" => ["evidence-one"],
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
             "statement" => "Prefer direct APIs",
             "evidence_ids" => ["evidence-one"],
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
           %{"statement" => "Prefer direct APIs", "evidence_ids" => ["evidence-one"]}
         ]
       }
     }}
  end

  defp restore_env({key, nil}), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env({key, value}), do: Application.put_env(:jido_gralkor, key, value)
end
