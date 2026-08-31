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
