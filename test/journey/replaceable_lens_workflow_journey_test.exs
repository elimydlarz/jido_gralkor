defmodule Gralkor.ReplaceableLensWorkflowJourneyTest do
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
    data_dir =
      Path.join(System.tmp_dir!(), "gralkor_replace_#{System.unique_integer([:positive])}")

    File.mkdir_p!(data_dir)

    previous_client = Application.get_env(:jido_gralkor, :client)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    Application.put_env(:jido_gralkor, :client, Native)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.Graphiti)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "systems",
        scope: :operator,
        write: :replace_graph,
        graph_format: :property_graph
      ]
    ])

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
      restore_env(:client, previous_client)
      restore_env(:lenses, previous_lenses)
      restore_env(:lens_storage, previous_storage)
      File.rm_rf!(data_dir)
    end)

    :ok
  end

  describe "when an application writes a complete graph through a replaceable Lens" do
    test "then Lens search returns the supplied graph" do
      assert :ok = Client.replace(replacement("old", "Payments settles through Ledger."))

      assert {:ok, results} = search("settlement ledger")
      assert Enum.any?(results, &String.contains?(&1.fact, "Payments settles through Ledger."))
    end
  end

  defp replacement(suffix, fact) do
    %Replace{
      operator_id: "operator-one",
      lens: "systems",
      graph: %Graph{
        format: :property_graph,
        data: %{
          nodes: [
            entity("payments-#{suffix}", "Payments"),
            entity("ledger-#{suffix}", "Ledger")
          ],
          relationships: [
            %{
              from: "payments-#{suffix}",
              to: "ledger-#{suffix}",
              type: "RELATES_TO",
              properties: %{
                uuid: "settlement-#{suffix}",
                group_id: "systems",
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

  defp entity(id, name) do
    %{
      id: id,
      labels: ["Entity"],
      properties: %{
        uuid: id,
        group_id: "systems",
        name: name,
        summary: name,
        created_at: "2026-08-08T00:00:00Z"
      }
    }
  end

  defp search(query) do
    Client.search(%Search{
      operator_id: "operator-one",
      query: query,
      lenses: ["systems"],
      max_results: 10
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
