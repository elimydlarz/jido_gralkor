defmodule Gralkor.ReplaceableLensWorkflowJourneyTest do
  @moduledoc """
  Production-like replaceable-Lens lifecycle using the embedded Graphiti/FalkorDB runtime.

  Reifies the `replaceable-lens-workflow` tree.
  """

  use ExUnit.Case, async: false

  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.Graph
  alias Gralkor.GraphitiPool
  alias Gralkor.Replace
  alias Gralkor.Search

  @moduletag :journey
  @moduletag timeout: 300_000

  setup_all do
    previous_client = Application.get_env(:jido_gralkor, :client)
    Application.put_env(:jido_gralkor, :client, Native)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "gralkor_replace_journey_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)
    {:ok, _python} = start_supervised(Gralkor.Python)

    {:ok, _pool} =
      start_supervised(
        {GraphitiPool,
         [
           falkordb_spec: {:embedded, data_dir},
           llm_model: Gralkor.Config.llm_model(),
           embedder_model: Gralkor.Config.embedder_model(),
           interpret_fn: Native.interpret_callback(),
           warmup: false
         ]}
      )

    on_exit(fn ->
      restore_application_env(:client, previous_client)
      File.rm_rf!(data_dir)
    end)

    :ok
  end

  setup do
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.Graphiti)

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "systems", address: "operator/systems"]
    ])

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "systems",
        destination: "systems",
        write: :replace_graph,
        graph_format: :property_graph
      ]
    ])

    on_exit(fn ->
      restore_application_env(:lenses, previous_lenses)
      restore_application_env(:destinations, previous_destinations)
      restore_application_env(:lens_storage, previous_storage)
    end)

    %{operator_id: "replace_journey_#{System.unique_integer([:positive])}"}
  end

  describe "when an application writes a complete graph through a replaceable Lens" do
    test "then searching the Lens's Destination returns the supplied graph", %{
      operator_id: operator_id
    } do
      assert :ok =
               Client.replace(replacement(operator_id, "old", "Payments settles through Ledger."))

      assert {:ok, results} = replacement_search(operator_id, "settlement ledger")
      assert Enum.any?(results, &String.contains?(&1.fact, "Payments settles through Ledger."))
    end

    test "when the application later replaces it with another complete graph then Lens search no longer returns the previous graph",
         %{operator_id: operator_id} do
      replace_twice(operator_id)
      assert {:ok, results} = replacement_search(operator_id, "settlement ledger")
      refute Enum.any?(results, &String.contains?(&1.fact, "Payments settles through Ledger."))
    end

    test "when the application later replaces it with another complete graph and Lens search returns the current graph",
         %{operator_id: operator_id} do
      replace_twice(operator_id)
      assert {:ok, results} = replacement_search(operator_id, "settlement clearing")
      assert Enum.any?(results, &String.contains?(&1.fact, "Payments settles through Clearing."))
    end
  end

  defp replace_twice(operator_id) do
    assert :ok =
             Client.replace(replacement(operator_id, "old", "Payments settles through Ledger."))

    assert {:ok, previous} = replacement_search(operator_id, "settlement ledger")
    assert Enum.any?(previous, &String.contains?(&1.fact, "Payments settles through Ledger."))

    assert :ok =
             Client.replace(replacement(operator_id, "new", "Payments settles through Clearing."))
  end

  defp replacement(operator_id, suffix, fact) do
    %Replace{
      operator_id: operator_id,
      lens: "systems",
      graph: %Graph{
        format: :property_graph,
        data: %{
          nodes: [
            replacement_entity(operator_id, "payments-#{suffix}", "Payments"),
            replacement_entity(operator_id, "ledger-#{suffix}", "Ledger")
          ],
          relationships: [
            %{
              from: "payments-#{suffix}",
              to: "ledger-#{suffix}",
              type: "RELATES_TO",
              properties: %{
                uuid: "#{operator_id}-settlement-#{suffix}",
                group_id: operator_id,
                name: "SETTLES_THROUGH",
                fact: fact,
                episodes: [],
                created_at: "2026-08-08T00:00:00Z"
              }
            }
          ]
        }
      }
    }
  end

  defp replacement_entity(operator_id, id, name) do
    %{
      id: id,
      labels: ["Entity"],
      properties: %{
        uuid: "#{operator_id}-#{id}",
        group_id: operator_id,
        name: name,
        summary: name,
        created_at: "2026-08-08T00:00:00Z"
      }
    }
  end

  defp replacement_search(operator_id, query) do
    Client.search(%Search{
      operator_id: operator_id,
      query: query,
      destinations: ["systems"],
      max_results: 10
    })
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_application_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
