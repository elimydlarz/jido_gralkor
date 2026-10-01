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
    def search(store, query, max_results) do
      send(Process.whereis(:lens_graph_replacement_functional), {
        :searched,
        store,
        query,
        max_results
      })

      case store.lens.name do
        "systems" -> {:ok, ["replacement-owned fact"]}
        _other -> {:ok, []}
      end
    end

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
    def replace_graph(_store, _graph), do: {:error, :import_failed}
  end

  defmodule DestinationSearchStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, operator_id, query, :facts, max_results, _opts) do
      send(Process.whereis(:lens_graph_replacement_functional), {
        :searched_destination,
        destination,
        operator_id,
        query,
        max_results
      })

      {:ok, ["replacement-owned fact"]}
    end
  end

  setup do
    Process.register(self(), :lens_graph_replacement_functional)

    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)
    previous_destination_storage = Application.get_env(:jido_gralkor, :destination_storage)

    start_supervised!(InMemory)

    Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)
    Application.put_env(:jido_gralkor, :destination_storage, DestinationSearchStorage)
    Application.put_env(:jido_gralkor, :destinations, destinations())

    Application.put_env(:jido_gralkor, :lenses, [replaceable_lens("systems", :personal)])

    on_exit(fn ->
      restore_env(:lenses, previous_lenses)
      restore_env(:destinations, previous_destinations)
      restore_env(:lens_storage, previous_storage)
      restore_env(:destination_storage, previous_destination_storage)
    end)

    :ok
  end

  describe "when a caller replaces the complete graph through a replaceable Lens" do
    test "then the Lens's Destination identifies the graph used by existing Lens operations" do
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
                        lens: %Gralkor.Lens.Replaceable{
                          name: "systems",
                          destination: %Gralkor.Destination{name: "personal"}
                        }
                      }, ^graph}

      Application.put_env(:jido_gralkor, :lenses, [replaceable_lens("systems", :global)])

      assert :ok = Client.replace(request(graph))

      assert_receive {:replaced,
                      %Gralkor.Lens.Store{
                        lens: %Gralkor.Lens.Replaceable{
                          name: "systems",
                          destination: %Gralkor.Destination{name: "global"}
                        }
                      }, ^graph}
    end

    test "and every node and relationship previously written by that Lens at the resolved destination is removed" do
      use_in_memory(:global)

      assert :ok = Client.replace(request(connected_graph("old")))
      assert :ok = Client.replace(request(graph("current")))

      assert %{nodes: [%{id: "current"}], relationships: []} =
               InMemory.graph(group(:global, "systems"))
    end

    test "and every supplied node and relationship is inserted at the resolved destination with every non-reserved graph value unchanged" do
      use_in_memory(:personal)
      supplied = connected_graph("payments")

      assert :ok = Client.replace(request(supplied))

      assert %{nodes: [source, target], relationships: [relationship]} =
               InMemory.graph(group(:personal, "systems"))

      assert Map.drop(source.properties, [:_gralkor_lens]) == %{name: "payments"}
      assert source.labels == ["System"]
      assert target.id == "payments-target"
      assert Map.drop(relationship.properties, [:_gralkor_lens]) == %{protocol: "events"}
      assert relationship.type == "DEPENDS_ON"
    end

    test "and every inserted node and relationship carries the reserved Lens ownership field set to the selected Lens name" do
      use_in_memory(:personal)
      assert :ok = Client.replace(request(connected_graph("payments")))

      stored = InMemory.graph(group(:personal, "systems"))

      assert Enum.all?(stored.nodes, &(&1.properties._gralkor_lens == "systems"))
      assert Enum.all?(stored.relationships, &(&1.properties._gralkor_lens == "systems"))
    end

    test "and nodes and relationships owned by another Lens at the resolved destination remain unchanged" do
      use_in_memory(:global, [
        replaceable_lens("systems", :global),
        replaceable_lens("catalogue", :global)
      ])

      assert :ok = Client.replace(request(connected_graph("catalogue"), "catalogue"))
      catalogue = InMemory.graph(group(:global, "systems"))

      assert :ok = Client.replace(request(connected_graph("systems")))

      assert InMemory.graph(group(:global, "systems")) == %{
               nodes: [
                 %{
                   id: "catalogue",
                   labels: ["System"],
                   properties: %{name: "catalogue", _gralkor_lens: "catalogue"}
                 },
                 %{
                   id: "catalogue-target",
                   labels: ["System"],
                   properties: %{name: "target", _gralkor_lens: "catalogue"}
                 },
                 %{
                   id: "systems",
                   labels: ["System"],
                   properties: %{name: "systems", _gralkor_lens: "systems"}
                 },
                 %{
                   id: "systems-target",
                   labels: ["System"],
                   properties: %{name: "target", _gralkor_lens: "systems"}
                 }
               ],
               relationships: [
                 %{
                   from: "catalogue",
                   to: "catalogue-target",
                   type: "DEPENDS_ON",
                   properties: %{protocol: "events", _gralkor_lens: "catalogue"}
                 },
                 %{
                   from: "systems",
                   to: "systems-target",
                   type: "DEPENDS_ON",
                   properties: %{protocol: "events", _gralkor_lens: "systems"}
                 }
               ]
             }

      assert Enum.take(InMemory.graph(group(:global, "systems")).nodes, 2) == catalogue.nodes

      assert Enum.take(InMemory.graph(group(:global, "systems")).relationships, 1) ==
               catalogue.relationships
    end

    test "and artefacts written through Destination outputs at the resolved destination remain unchanged" do
      use_in_memory(:global)
      start_supervised!(Gralkor.Destination.Storage.InMemory)

      Application.put_env(
        :jido_gralkor,
        :destination_storage,
        Gralkor.Destination.Storage.InMemory
      )

      reflection = %Gralkor.Reflection{
        name: "review",
        outputs: [
          %{
            kind: :destination,
            destination: Gralkor.Destination.Registry.fetch!("global"),
            ontology: Gralkor.DefaultOntology
          }
        ],
        chain_of_thought: %Gralkor.Reflection.ChainOfThought{steps: []}
      }

      artefact = %Gralkor.Artefact{
        id: "review-one",
        payload: %{"lesson" => "keep this"}
      }

      assert :ok =
               Gralkor.Destination.Storage.put_artefact(
                 Enum.find(reflection.outputs, &(&1.kind == :destination)),
                 reflection.name,
                 "operator-one",
                 artefact,
                 storage: Gralkor.Destination.Storage.InMemory
               )

      assert :ok = Client.replace(request(graph("systems")))

      assert {:ok, [%{destination: "global", artefact: ^artefact}]} =
               Client.search(%Gralkor.Search{
                 operator_id: "operator-two",
                 query: "keep",
                 destinations: ["global"],
                 result_type: :artefacts
               })
    end

    test "and nodes and relationships without the reserved Lens ownership field at the resolved destination remain unchanged" do
      use_in_memory(:global)

      unowned = %{
        nodes: [%{id: "manual", labels: ["External"], properties: %{}}],
        relationships: []
      }

      :sys.replace_state(
        InMemory,
        &Map.put(&1, {:graph, group(:global, "systems")}, unowned)
      )

      assert :ok = Client.replace(request(graph("systems")))

      assert Enum.map(InMemory.graph(group(:global, "systems")).nodes, & &1.id) == [
               "manual",
               "systems"
             ]
    end

    test "and the caller observes whether replacement succeeded or failed" do
      use_in_memory(:personal)
      assert :ok = Client.replace(request(graph("systems")))

      Application.put_env(:jido_gralkor, :lens_storage, FailingStorage)
      assert {:error, :import_failed} = Client.replace(request(graph("systems")))
    end
  end

  describe "when a caller supplies a complete replacement graph" do
    test "then every supplied node carries a unique identifier, labels, and properties" do
      use_in_memory(:personal)
      assert :ok = Client.replace(request(graph("systems")))

      complete_node = %{id: "node", labels: ["System"], properties: %{}}

      for {reason, node} <- [
            {"invalid node", Map.delete(complete_node, :id)},
            {"invalid node", %{complete_node | id: " "}},
            {"invalid node", Map.delete(complete_node, :labels)},
            {"invalid node", %{complete_node | labels: [" "]}},
            {"invalid node", Map.delete(complete_node, :properties)},
            {"invalid node", %{complete_node | properties: []}}
          ] do
        assert_raise ArgumentError, ~r/invalid graph data: #{reason}/, fn ->
          Client.replace(request(%Graph{nodes: [node], relationships: []}))
        end
      end

      assert_raise ArgumentError, ~r/invalid graph data: duplicate node identifier "node"/, fn ->
        Client.replace(request(%Graph{nodes: [complete_node, complete_node], relationships: []}))
      end

      assert %{nodes: [%{id: "systems"}]} = InMemory.graph(group(:personal, "systems"))
    end

    test "and every supplied relationship carries source and destination node identifiers, a type, and properties" do
      use_in_memory(:personal)
      assert :ok = Client.replace(request(connected_graph("systems")))

      %Graph{nodes: nodes, relationships: [complete_relationship]} = connected_graph("candidate")

      for relationship <- [
            Map.delete(complete_relationship, :from),
            Map.delete(complete_relationship, :to),
            Map.delete(complete_relationship, :type),
            %{complete_relationship | type: " "},
            Map.delete(complete_relationship, :properties),
            %{complete_relationship | properties: []}
          ] do
        assert_raise ArgumentError, ~r/invalid graph data: invalid relationship/, fn ->
          Client.replace(request(%Graph{nodes: nodes, relationships: [relationship]}))
        end
      end

      assert %{nodes: [%{id: "systems"}, %{id: "systems-target"}], relationships: [_]} =
               InMemory.graph(group(:personal, "systems"))
    end
  end

  describe "if the supplied graph is malformed or names a missing relationship endpoint" do
    test "then replacement fails before graph content is removed or inserted" do
      use_in_memory(:personal)
      assert :ok = Client.replace(request(graph("existing")))

      for data <- malformed_graph_data() do
        assert_raise ArgumentError, ~r/invalid graph data/, fn ->
          Client.replace(
            request(%Graph{
              nodes: Map.get(data, :nodes),
              relationships: Map.get(data, :relationships)
            })
          )
        end
      end

      assert %{nodes: [%{id: "existing"}]} =
               InMemory.graph(group(:personal, "systems"))
    end

    test "and the error identifies the invalid graph data" do
      assert_raise ArgumentError,
                   ~r/invalid graph data: expected a Gralkor.Graph; got %\{nodes: \[\], relationships: \[\]\}/,
                   fn -> Client.replace(request(%{nodes: [], relationships: []})) end

      assert_raise ArgumentError, ~r/invalid graph data.*missing/, fn ->
        Client.replace(
          request(%Graph{
            nodes: [%{id: "source", labels: [], properties: %{}}],
            relationships: [
              %{from: "source", to: "missing", type: "LINKS", properties: %{}}
            ]
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
      assert InMemory.graph(group(:global, "systems")) == %{nodes: [], relationships: []}
    end

    test "and no replacement node or relationship is inserted" do
      use_in_memory(:global)
      assert :ok = Client.replace(request(empty_graph()))
      assert InMemory.graph(group(:global, "systems")) == %{nodes: [], relationships: []}
    end
  end

  describe "when a Lens graph is replaced more than once" do
    test "then only the most recently supplied complete graph remains owned by that Lens at the resolved destination" do
      use_in_memory(:global)

      for id <- ["first", "second", "current"] do
        assert :ok = Client.replace(request(graph(id)))
      end

      assert %{nodes: [%{id: "current"}]} = InMemory.graph(group(:global, "systems"))
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

  describe "if the supplied complete graph cannot be imported" do
    test "then the import failure is returned to the caller" do
      Application.put_env(:jido_gralkor, :lens_storage, FailingStorage)
      assert {:error, :import_failed} = Client.replace(request(graph("systems")))
    end

    test "and graph content already removed by the replacement is not restored" do
      falkordb = use_graphiti_boundary()
      assert :ok = Client.replace(request(connected_graph("existing")))

      assert %{"nodes" => [_manual, _existing, _target], "relationships" => [_]} =
               falkordb_graph(falkordb)

      Pythonx.eval("falkordb.fail_creates = True", %{"falkordb" => falkordb})
      Pythonx.eval("falkordb.queries = []", %{"falkordb" => falkordb})

      assert {:error, {:python, _reason}} = Client.replace(request(graph("systems")))

      assert falkordb_graph(falkordb) == %{
               "nodes" => [%{"labels" => ["External"], "properties" => %{"id" => "manual"}}],
               "relationships" => []
             }

      assert [delete_relationships, delete_nodes, failed_create] = falkordb_queries(falkordb)
      assert delete_relationships =~ "DELETE relationship"
      assert delete_nodes =~ "DELETE node"
      assert failed_create =~ "CREATE (node"
    end
  end

  describe "when a caller searches the Destination used by a replaceable Lens" do
    test "then Destination search resolves and searches that Destination's graph" do
      assert {:ok, [%{destination: "personal", fact: "replacement-owned fact"}]} =
               Client.search(%Gralkor.Search{
                 operator_id: "operator-one",
                 destinations: ["personal"],
                 query: "How does settlement work?",
                 result_type: :facts
               })

      assert_receive {:searched_destination, %Gralkor.Destination{name: "personal"},
                      "operator-one", "How does settlement work?", 20}
    end
  end

  defp use_graphiti_boundary do
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.Graphiti)

    {boundary, _} =
      Pythonx.eval(
        """
        def _text(value):
            return value.decode('utf-8') if isinstance(value, (bytes, bytearray)) else value

        class _FalkorDB:
            def __init__(self):
                self.nodes = [{'labels': ['External'], 'properties': {'id': 'manual'}}]
                self.relationships = []
                self.queries = []
                self.fail_creates = False

            async def execute_query(self, query, **params):
                query = _text(query)
                self.queries.append(query)
                lens = _text(params.get('lens'))
                if query.startswith('MATCH ()-[relationship]->()'):
                    self.relationships = [
                        item for item in self.relationships
                        if item['properties'].get('_gralkor_lens') != lens
                    ]
                elif query.startswith('MATCH (node)'):
                    self.nodes = [
                        item for item in self.nodes
                        if item['properties'].get('_gralkor_lens') != lens
                    ]
                elif self.fail_creates:
                    raise RuntimeError('import failed after deletion')
                elif query.startswith('CREATE (node'):
                    labels = query.split('(node', 1)[1].split(')', 1)[0]
                    self.nodes.append({
                        'labels': [label.strip('`') for label in labels.split(':') if label],
                        'properties': params['properties'],
                    })
                else:
                    self.relationships.append({
                        'from': _text(params['source_id']),
                        'to': _text(params['destination_id']),
                        'properties': params['properties'],
                    })
                return [], None, None

        class _Graphiti:
            def __init__(self, driver):
                self.driver = driver

        falkordb = _FalkorDB()
        graphiti = _Graphiti(falkordb)
        (falkordb, graphiti)
        """,
        %{}
      )

    {falkordb, _} = Pythonx.eval("boundary[0]", %{"boundary" => boundary})
    {graphiti, _} = Pythonx.eval("boundary[1]", %{"boundary" => boundary})

    start_supervised!(
      {Gralkor.GraphitiPool,
       name: Gralkor.GraphitiPool,
       table: :gralkor_graphiti_instances,
       falkordb_spec: {:embedded, "/tmp/never_used"},
       construct_falkor_db: fn _spec -> :stub_falkor_db end,
       construct_shared_clients: fn _llm, _embedder ->
         %{llm_client: nil, embedder: nil, cross_encoder: nil}
       end,
       construct_instance: fn _database, _shared, _group_id -> graphiti end,
       initialise_instance: fn _instance -> :ok end,
       warmup: false,
       install_loop_fn: &Gralkor.Python.install_async_runtime/0}
    )

    falkordb
  end

  defp falkordb_graph(falkordb) do
    {graph, _} =
      Pythonx.eval(
        "{'nodes': falkordb.nodes, 'relationships': falkordb.relationships}",
        %{"falkordb" => falkordb}
      )

    Pythonx.decode(graph)
  end

  defp falkordb_queries(falkordb) do
    {queries, _} = Pythonx.eval("falkordb.queries", %{"falkordb" => falkordb})
    Pythonx.decode(queries)
  end

  defp use_in_memory(scope, lenses \\ nil) do
    Application.put_env(:jido_gralkor, :lens_storage, InMemory)
    Application.put_env(:jido_gralkor, :lenses, lenses || [replaceable_lens("systems", scope)])
  end

  defp request(graph, lens \\ "systems") do
    %Replace{operator_id: "operator-one", lens: lens, graph: graph}
  end

  defp replaceable_lens(name, scope) do
    [
      name: name,
      destination: Atom.to_string(scope),
      write: :replace_graph
    ]
  end

  defp appending_lens(name) do
    [
      name: name,
      destination: "personal",
      ontology: MemoryOntology,
      ingestion: AppendingIngestion
    ]
  end

  defp destinations, do: []

  defp group(scope, _name) do
    destination = Gralkor.Destination.Registry.fetch!(Atom.to_string(scope))
    Gralkor.Destination.graph_id(destination, "operator-one")
  end

  defp graph(id) do
    %Graph{
      nodes: [%{id: id, labels: ["System"], properties: %{name: id}}],
      relationships: []
    }
  end

  defp connected_graph(id) do
    %Graph{
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
  end

  defp empty_graph do
    %Graph{nodes: [], relationships: []}
  end

  defp malformed_graph_data do
    [
      %{},
      %{nodes: :invalid, relationships: []},
      %{
        nodes: [
          %{id: "duplicate", labels: [], properties: %{}},
          %{id: "duplicate", labels: [], properties: %{}}
        ],
        relationships: []
      },
      %{
        nodes: [%{id: "source", labels: [], properties: %{}}],
        relationships: [%{from: "source", to: "missing", type: "LINKS", properties: %{}}]
      }
    ]
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
