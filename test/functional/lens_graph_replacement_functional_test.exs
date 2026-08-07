defmodule Gralkor.LensGraphReplacementFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Graph
  alias Gralkor.Lens.Storage.InMemory
  alias Gralkor.Replace

  defmodule MemoryOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open
  end

  defmodule AppendingIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(_request, _store), do: :ok
  end

  defmodule RecordingStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(_store, _content, _source_description), do: :ok

    @impl true
    def search(_store, _query, _max_results), do: {:ok, []}

    @impl true
    def replace_graph(store, graph) do
      send(Process.whereis(:lens_graph_replacement_functional), {:replaced, store, graph})
      :ok
    end
  end

  defmodule FailingStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(_store, _content, _source_description), do: :ok

    @impl true
    def search(_store, _query, _max_results), do: {:ok, []}

    @impl true
    def replace_graph(_store, _graph) do
      send(Process.whereis(:lens_graph_replacement_functional), :removed_without_restore)
      {:error, :import_failed}
    end
  end

  setup do
    Process.register(self(), :lens_graph_replacement_functional)

    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    start_supervised!(InMemory)

    Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

    Application.put_env(:jido_gralkor, :lenses, [replaceable_lens("systems", :operator)])

    on_exit(fn ->
      restore_env(:lenses, previous_lenses)
      restore_env(:lens_storage, previous_storage)
    end)

    :ok
  end

  describe "when a caller replaces the complete graph through a replaceable Lens" do
    test "then the Lens scope resolves the same operator-local or shared global destination used by existing Lens operations" do
      graph = empty_graph()

      assert :ok =
               Client.replace(%Replace{
                 operator_id: "operator-one",
                 lens: "systems",
                 graph: graph
               })

      assert_receive {:replaced,
                      %Gralkor.Lens.Store{
                        operator_id: "operator-one",
                        lens: %Gralkor.Lens.Replaceable{name: "systems", scope: :operator}
                      }, ^graph}

      Application.put_env(:jido_gralkor, :lenses, [replaceable_lens("systems", :global)])

      assert :ok = Client.replace(request(graph))

      assert_receive {:replaced,
                      %Gralkor.Lens.Store{
                        lens: %Gralkor.Lens.Replaceable{name: "systems", scope: :global}
                      }, ^graph}
    end

    test "and every node and relationship previously written by that Lens at the resolved destination is removed" do
      use_in_memory(:global)

      assert :ok = Client.replace(request(connected_graph("old")))
      assert :ok = Client.replace(request(graph("current")))

      assert %{nodes: [%{id: "current"}], relationships: []} = InMemory.graph(:global)
    end

    test "and every supplied node and relationship is inserted at the resolved destination with every non-reserved graph value unchanged" do
      use_in_memory(:operator)
      supplied = connected_graph("payments")

      assert :ok = Client.replace(request(supplied))

      assert %{nodes: [source, target], relationships: [relationship]} =
               InMemory.graph({"operator-one", "systems"})

      assert Map.drop(source.properties, [:_gralkor_lens]) == %{name: "payments"}
      assert source.labels == ["System"]
      assert target.id == "payments-target"
      assert Map.drop(relationship.properties, [:_gralkor_lens]) == %{protocol: "events"}
      assert relationship.type == "DEPENDS_ON"
    end

    test "and every inserted node and relationship carries the reserved Lens ownership field set to the selected Lens name" do
      use_in_memory(:operator)
      assert :ok = Client.replace(request(connected_graph("payments")))

      stored = InMemory.graph({"operator-one", "systems"})

      assert Enum.all?(stored.nodes, &(&1.properties._gralkor_lens == "systems"))
      assert Enum.all?(stored.relationships, &(&1.properties._gralkor_lens == "systems"))
    end

    test "and nodes and relationships owned by another Lens at the resolved destination remain unchanged" do
      use_in_memory(:global, [replaceable_lens("systems", :global), replaceable_lens("catalogue", :global)])

      assert :ok = Client.replace(request(graph("catalogue"), "catalogue"))
      assert :ok = Client.replace(request(graph("systems")))

      assert Enum.map(InMemory.graph(:global).nodes, & &1.id) == ["catalogue", "systems"]
    end

    test "and nodes and relationships without the reserved Lens ownership field at the resolved destination remain unchanged" do
      use_in_memory(:global)

      unowned = %{nodes: [%{id: "manual", labels: ["External"], properties: %{}}], relationships: []}
      :sys.replace_state(InMemory, &Map.put(&1, {:graph, :global}, unowned))

      assert :ok = Client.replace(request(graph("systems")))
      assert Enum.map(InMemory.graph(:global).nodes, & &1.id) == ["manual", "systems"]
    end

    test "and the caller observes whether replacement succeeded or failed" do
      use_in_memory(:operator)
      assert :ok = Client.replace(request(graph("systems")))

      Application.put_env(:jido_gralkor, :lens_storage, FailingStorage)
      assert {:error, :import_failed} = Client.replace(request(graph("systems")))
    end
  end

  describe "where the selected Lens uses the `property_graph` format" do
    test "then every supplied node carries a unique identifier, labels, and properties" do
      use_in_memory(:operator)
      assert :ok = Client.replace(request(graph("systems")))
    end

    test "and every supplied relationship carries source and destination node identifiers, a type, and properties" do
      use_in_memory(:operator)
      assert :ok = Client.replace(request(connected_graph("systems")))
    end
  end

  describe "if a `property_graph` payload is malformed or names a missing relationship endpoint" do
    test "then replacement fails before graph content is removed or inserted" do
      use_in_memory(:operator)
      assert :ok = Client.replace(request(graph("existing")))

      for data <- malformed_graph_data() do
        assert_raise ArgumentError, ~r/invalid property_graph data/, fn ->
          Client.replace(request(%Graph{format: :property_graph, data: data}))
        end
      end

      assert %{nodes: [%{id: "existing"}]} = InMemory.graph({"operator-one", "systems"})
    end

    test "and the error identifies the invalid graph data" do
      assert_raise ArgumentError, ~r/invalid property_graph data.*missing/, fn ->
        Client.replace(
          request(%Graph{
            format: :property_graph,
            data: %{
              nodes: [%{id: "source", labels: [], properties: %{}}],
              relationships: [
                %{from: "source", to: "missing", type: "LINKS", properties: %{}}
              ]
            }
          })
        )
      end
    end
  end

  describe "where the supplied complete graph is empty" do
    test "then every node and relationship previously written by that Lens at the resolved destination is removed" do
      use_in_memory(:global)
      assert :ok = Client.replace(request(connected_graph("old")))
      assert :ok = Client.replace(request(empty_graph()))
      assert InMemory.graph(:global) == %{nodes: [], relationships: []}
    end

    test "and no replacement node or relationship is inserted" do
      use_in_memory(:global)
      assert :ok = Client.replace(request(empty_graph()))
      assert InMemory.graph(:global) == %{nodes: [], relationships: []}
    end
  end

  describe "when a Lens graph is replaced more than once" do
    test "then only the most recently supplied complete graph remains owned by that Lens at the resolved destination" do
      use_in_memory(:global)

      for id <- ["first", "second", "current"] do
        assert :ok = Client.replace(request(graph(id)))
      end

      assert %{nodes: [%{id: "current"}]} = InMemory.graph(:global)
    end
  end

  describe "if replacement selects an invalid Lens" do
    test "then replacement fails before graph content is removed or inserted" do
      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        Client.replace(request(graph("systems"), "missing"))
      end

      refute_receive {:replaced, _, _}
    end
  end

  describe "if replacement selects an appending Lens" do
    test "then replacement fails with an error identifying that the Lens accepts only episode ingestion" do
      Application.put_env(:jido_gralkor, :lenses, [appending_lens("systems")])

      assert_raise ArgumentError, ~r/systems.*only episode ingestion/, fn ->
        Client.replace(request(graph("systems")))
      end
    end

    test "and no existing graph content is removed or inserted" do
      Application.put_env(:jido_gralkor, :lenses, [appending_lens("systems")])
      assert_raise ArgumentError, fn -> Client.replace(request(graph("systems"))) end
      refute_receive {:replaced, _, _}
    end
  end

  describe "if the supplied graph format differs from the selected Lens's configured graph format" do
    test "then replacement fails before graph content is removed or inserted" do
      assert_raise ArgumentError, fn ->
        Client.replace(request(%Graph{format: :graphml, data: %{}}))
      end

      refute_receive {:replaced, _, _}
    end

    test "and the error identifies the expected and supplied graph formats" do
      assert_raise ArgumentError, ~r/expected :property_graph.*supplied :graphml/, fn ->
        Client.replace(request(%Graph{format: :graphml, data: %{}}))
      end
    end
  end

  describe "if the supplied complete graph cannot be imported" do
    test "then the import failure is returned to the caller" do
      Application.put_env(:jido_gralkor, :lens_storage, FailingStorage)
      assert {:error, :import_failed} = Client.replace(request(graph("systems")))
    end

    test "and graph content already removed by the replacement is not restored" do
      Application.put_env(:jido_gralkor, :lens_storage, FailingStorage)
      assert {:error, :import_failed} = Client.replace(request(graph("systems")))
      assert_receive :removed_without_restore
    end
  end

  describe "when a caller searches through a replaceable Lens" do
    test "then the existing Lens search resolves and searches that Lens's scoped destination" do
      Application.put_env(:jido_gralkor, :lens_storage, InMemory)

      assert {:ok, []} =
               Client.search(%Gralkor.Search{
                 operator_id: "operator-one",
                 lenses: ["systems"],
                 query: "How does settlement work?"
               })
    end
  end

  defp use_in_memory(scope, lenses \\ nil) do
    Application.put_env(:jido_gralkor, :lens_storage, InMemory)
    Application.put_env(:jido_gralkor, :lenses, lenses || [replaceable_lens("systems", scope)])
  end

  defp request(graph, lens \\ "systems") do
    %Replace{operator_id: "operator-one", lens: lens, graph: graph}
  end

  defp replaceable_lens(name, scope) do
    [name: name, scope: scope, write: :replace_graph, graph_format: :property_graph]
  end

  defp appending_lens(name) do
    [
      name: name,
      ontology: MemoryOntology,
      scope: :operator,
      ingestion: AppendingIngestion
    ]
  end

  defp graph(id) do
    %Graph{
      format: :property_graph,
      data: %{
        nodes: [%{id: id, labels: ["System"], properties: %{name: id}}],
        relationships: []
      }
    }
  end

  defp connected_graph(id) do
    %Graph{
      format: :property_graph,
      data: %{
        nodes: [
          %{id: id, labels: ["System"], properties: %{name: id}},
          %{id: "#{id}-target", labels: ["System"], properties: %{name: "target"}}
        ],
        relationships: [
          %{
            from: id,
            to: "#{id}-target",
            type: "DEPENDS_ON",
            properties: %{protocol: "events"}
          }
        ]
      }
    }
  end

  defp empty_graph do
    %Graph{format: :property_graph, data: %{nodes: [], relationships: []}}
  end

  defp malformed_graph_data do
    [
      %{},
      %{nodes: :invalid, relationships: []},
      %{nodes: [%{id: "duplicate", labels: [], properties: %{}}, %{id: "duplicate", labels: [], properties: %{}}], relationships: []},
      %{nodes: [%{id: "source", labels: [], properties: %{}}], relationships: [%{from: "source", to: "missing", type: "LINKS", properties: %{}}]}
    ]
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
