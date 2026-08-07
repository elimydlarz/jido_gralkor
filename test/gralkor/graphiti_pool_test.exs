defmodule Gralkor.GraphitiPoolTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.GraphitiPool
  alias Gralkor.GraphitiPoolTest.StrictOntologyForGraphitiTest

  def start_pool(opts) do
    table = :"pool_table_#{System.unique_integer([:positive])}"

    defaults = [
      name: nil,
      table: table,
      falkordb_spec: {:embedded, "/tmp/never_used"},
      construct_falkor_db: fn _spec -> :stub_falkor_db end,
      construct_shared_clients: fn _llm, _embedder ->
        %{llm_client: nil, embedder: nil, cross_encoder: nil}
      end,
      construct_instance: fn _db, _shared, group_id -> {:stub_graphiti, group_id} end,
      initialise_instance: fn _instance -> :ok end,
      warmup: false,
      install_loop_fn: fn -> :ok end
    ]

    {:ok, pid} = GraphitiPool.start_link(Keyword.merge(defaults, opts))
    %{pid: pid, table: table}
  end

  defp start_embedded_pool(data_dir, opts \\ []) do
    defaults = [
      name: nil,
      falkordb_spec: {:embedded, data_dir},
      warmup: false,
      construct_falkor_db: fn _spec -> :stub_falkor_db end,
      construct_shared_clients: fn _llm, _embedder ->
        %{llm_client: nil, embedder: nil, cross_encoder: nil}
      end,
      initialise_instance: fn _instance -> :ok end
    ]

    GraphitiPool.start_link(Keyword.merge(defaults, opts))
  end

  describe "if adding an episode raises inside the graph library" do
    test "then an error carrying only the raised exception's class and message is returned" do
      err = %Pythonx.Error{
        type: nil,
        value: nil,
        traceback: nil,
        lines: [
          "Traceback (most recent call last):\n",
          "  File \"/app/graphiti_core/graphiti.py\", line 412, in add_episode\n    await self.driver.execute_query(query, embedding=[0.123, 0.456, 0.789, 0.012])\n",
          "  File \"/app/redis/asyncio/connection.py\", line 88, in connect\n    raise ConnectionError(msg)\n",
          "redis.exceptions.ConnectionError: Error 104 connecting to falkor.cloud:6379. Connection reset by peer.\n"
        ]
      }

      reason = GraphitiPool.summarise_python_error(err)

      assert reason ==
               "redis.exceptions.ConnectionError: Error 104 connecting to falkor.cloud:6379. Connection reset by peer."

      refute reason =~ "Traceback"
      refute reason =~ "embedding="
      refute reason =~ "\n"
    end

    test "and the logged diagnostic is a single concise line, so neither the full traceback nor an embedding vector is written to the log" do
      err = %Pythonx.Error{
        type: nil,
        value: nil,
        traceback: nil,
        lines: [
          "Traceback (most recent call last):\n",
          "  File \"x.py\", line 1, in <module>\n",
          "ValueError: bad thing happened\n"
        ]
      }

      reason = GraphitiPool.summarise_python_error(err)
      assert {:error, {:python, ^reason}} = {:error, {:python, reason}}
      assert reason == "ValueError: bad thing happened"
    end
  end

  describe "if adding an episode raises inside the graph library > if the raised exception carries no detail" do
    test "then the returned reason falls back to a message stating that a Python exception was raised with no detail available" do
      err = %Pythonx.Error{type: nil, value: nil, traceback: nil, lines: []}

      reason = GraphitiPool.summarise_python_error(err)
      assert reason == "Python exception raised (no detail available)"
    end
  end

  describe "when the graph library needs inference" do
    test "then its own provider client issues the call" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              async def add_episode(self, **kwargs):
                  raise RuntimeError("graph library exploded")

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:error, {:python, reason}} =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil)

      assert reason =~ "RuntimeError"
      assert reason =~ "graph library exploded"
      refute reason =~ "Traceback"
      refute reason =~ "\n"

      GenServer.stop(pid)
    end
  end

  describe "when an episode is added > while an episode identifier is supplied" do
    test "then that identifier is forwarded to the graph library, so re-adding under it updates the episode by re-extraction" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              def __init__(self):
                  self.recorded_kwargs = None

              async def add_episode(self, **kwargs):
                  self.recorded_kwargs = kwargs

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil,
                 uuid: "existing-episode-uuid"
               )

      {uuid, _} = Pythonx.eval("g.recorded_kwargs['uuid']", %{"g" => g})
      assert Pythonx.decode(uuid) == "existing-episode-uuid"

      GenServer.stop(pid)
    end
  end

  describe "when an episode is added" do
    test "then its name combines the current millisecond timestamp with a positive monotonic unique integer, so concurrent writes remain distinguishable without claiming an episode UUID" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              def __init__(self):
                  self.names = []

              async def add_episode(self, **kwargs):
                  self.names.append(kwargs['name'])

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert :ok = GraphitiPool.add_episode(pid, "g1", "first", "manual", nil)
      assert :ok = GraphitiPool.add_episode(pid, "g1", "second", "manual", nil)

      {names, _} = Pythonx.eval("g.names", %{"g" => g})
      assert [first, second] = Pythonx.decode(names)
      assert first =~ ~r/^manual-add-\d+-\d+$/
      assert second =~ ~r/^manual-add-\d+-\d+$/
      refute first == second

      GenServer.stop(pid)
    end
  end

  describe "when an episode is added > while no ontology is supplied" do
    test "then the graph library receives no entity types, edge types, edge type map, or excluded entity types" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              def __init__(self):
                  self.recorded_kwargs = None

              async def add_episode(self, **kwargs):
                  self.recorded_kwargs = kwargs

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert :ok = GraphitiPool.add_episode(pid, "g1", "content", "source", nil)

      {keys, _} = Pythonx.eval("sorted(g.recorded_kwargs.keys())", %{"g" => g})

      assert Pythonx.decode(keys) == [
               "episode_body",
               "group_id",
               "name",
               "reference_time",
               "source",
               "source_description"
             ]

      GenServer.stop(pid)
    end
  end

  defmodule OntologyForwardingTest do
    use ExUnit.Case, async: false

    alias Gralkor.GraphitiPool

    describe "when an episode is added > while an ontology module is supplied" do
      @describetag :integration

      defmodule OntologyForwardingOntology do
        use Gralkor.Ontology, entities: :strict, relationships: :scoped

        entity Widget do
          field(:label, :string, required: true)
        end

        entity Gadget do
          field(:kind, :string, required: true)
        end

        from Widget do
          linked_to Gadget do
            field(:since, :string)
          end
        end
      end

      test "and the translated entity types, edge types, edge type map, and excluded entity types are forwarded to the graph library" do
        {g, _} =
          Pythonx.eval(
            """
            class _FakeGraphiti:
                def __init__(self):
                    self.recorded_kwargs = None

                async def add_episode(self, **kwargs):
                    self.recorded_kwargs = kwargs

            _FakeGraphiti()
            """,
            %{}
          )

        %{pid: pid} =
          Gralkor.GraphitiPoolTest.start_pool(
            construct_instance: fn _db, _shared, _group_id -> g end,
            warmup: false,
            install_loop_fn: &Gralkor.Python.install_async_runtime/0
          )

        assert :ok =
                 GraphitiPool.add_episode(
                   pid,
                   "g1",
                   "content",
                   "source",
                   OntologyForwardingOntology
                 )

        {inspection, _} =
          Pythonx.eval(
            """
            kwargs = g.recorded_kwargs
            {
                "keys": sorted(kwargs.keys()),
                "entity_type_keys": sorted(kwargs["entity_types"].keys()),
                "entity_type_names": sorted(cls.__name__ for cls in kwargs["entity_types"].values()),
                "edge_type_keys": sorted(kwargs["edge_types"].keys()),
                "edge_type_names": sorted(cls.__name__ for cls in kwargs["edge_types"].values()),
                "edge_type_map": sorted(
                    [str(k[0]), str(k[1]), sorted(v)] for k, v in kwargs["edge_type_map"].items()
                ),
                "excluded_entity_types": kwargs["excluded_entity_types"],
            }
            """,
            %{"g" => g}
          )

        inspection = Pythonx.decode(inspection)

        assert inspection["keys"] == [
                 "edge_type_map",
                 "edge_types",
                 "entity_types",
                 "episode_body",
                 "excluded_entity_types",
                 "group_id",
                 "name",
                 "reference_time",
                 "source",
                 "source_description"
               ]

        assert inspection["entity_type_keys"] == ["Gadget", "Widget"]
        assert inspection["entity_type_names"] == ["Gadget", "Widget"]
        assert inspection["edge_type_keys"] == ["LINKED_TO"]
        assert inspection["edge_type_names"] == ["LINKED_TO"]
        assert inspection["edge_type_map"] == [["Widget", "Gadget", ["LINKED_TO"]]]
        assert inspection["excluded_entity_types"] == ["Entity"]

        GenServer.stop(pid)
      end
    end
  end

  describe "when an episode is removed" do
    test "then the graph library deletes that episode along with the nodes and edges it orphans" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def remove_episode(self, uuid):
                  self.recorded['uuid'] = uuid

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert :ok = GraphitiPool.remove_episode(pid, "g1", "episode-uuid-123")

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      rec = Pythonx.decode(rec)
      assert rec["uuid"] == "episode-uuid-123"

      GenServer.stop(pid)
    end
  end

  describe "if removing an episode raises inside the graph library" do
    test "then an error carrying only the raised exception's class and message is returned" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              async def remove_episode(self, uuid):
                  raise RuntimeError("episode vanished")

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:error, {:python, reason}} =
               GraphitiPool.remove_episode(pid, "g1", "episode-uuid-123")

      assert reason =~ "RuntimeError"
      assert reason =~ "episode vanished"
      refute reason =~ "Traceback"
      refute reason =~ "\n"

      GenServer.stop(pid)
    end

    test "and the logged diagnostic is a single concise line rather than a full traceback" do
      err = %Pythonx.Error{
        type: nil,
        value: nil,
        traceback: nil,
        lines: [
          "Traceback (most recent call last):\n",
          "  File \"/app/graphiti_core/graphiti.py\", line 600, in remove_episode\n    await self.driver.execute_query(delete_query)\n",
          "RuntimeError: episode not found\n"
        ]
      }

      reason = GraphitiPool.summarise_python_error(err)

      assert reason == "RuntimeError: episode not found"
      refute reason =~ "Traceback"
      refute reason =~ "\n"
    end
  end

  describe "when a complete property graph replaces content owned by a Lens in a group" do
    test "then every relationship carrying that Lens's reserved ownership field is removed before owned nodes are removed" do
      {g, _} = replacement_graphiti()

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert :ok =
               GraphitiPool.replace_graph(
                 pid,
                 "g1",
                 "systems",
                 :property_graph,
                 %{nodes: [], relationships: []}
               )

      {recorded, _} = Pythonx.eval("g.driver.recorded", %{"g" => g})

      assert [
               %{"query" => relationship_delete, "params" => %{"lens" => "systems"}},
               %{"query" => node_delete, "params" => %{"lens" => "systems"}}
             ] = Pythonx.decode(recorded)

      assert relationship_delete =~ "MATCH ()-[relationship]-()"
      assert relationship_delete =~ "relationship._gralkor_lens = $lens"
      assert node_delete =~ "MATCH (node)"
      assert node_delete =~ "node._gralkor_lens = $lens"

      GenServer.stop(pid)
    end

    test "and each supplied node is inserted with its identifier, labels, properties, and reserved Lens ownership field" do
      {g, _} = replacement_graphiti()

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert :ok =
               GraphitiPool.replace_graph(
                 pid,
                 "g1",
                 "systems",
                 :property_graph,
                 %{
                   nodes: [
                     %{
                       id: "payments",
                       labels: ["System", "Critical"],
                       properties: %{name: "Payments", priority: 1}
                     }
                   ],
                   relationships: []
                 }
               )

      {recorded, _} = Pythonx.eval("g.driver.recorded", %{"g" => g})
      [_, _, node_insert] = Pythonx.decode(recorded)

      assert node_insert["query"] =~ "CREATE (node:`System`:`Critical`)"

      assert node_insert["params"] == %{
               "properties" => %{
                 "id" => "payments",
                 "name" => "Payments",
                 "priority" => 1,
                 "_gralkor_lens" => "systems"
               }
             }

      GenServer.stop(pid)
    end
  end

  describe "when a fact search is run for a group" do
    test "then the graph library's edge search is invoked with the requested result count" do
      # A Pythonx-built fake graphiti whose search coroutine records its kwargs on the
      # instance, so they survive across Pythonx.eval scopes. The pool's construct_instance
      # returns it so GraphitiPool.search drives it.
      {g, _} =
        Pythonx.eval(
          """
          import asyncio

          class _Edge:
              def __init__(self, fact):
                  self.fact = fact
                  self.created_at = None
                  self.valid_at = None
                  self.invalid_at = None
                  self.expired_at = None

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def search(self, query, num_results=10):
                  self.recorded['query'] = query
                  self.recorded['num_results'] = num_results
                  return [_Edge("X is a thing")]

          _FakeGraphiti()
          """,
          %{}
        )

      construct_instance = fn _db, _shared, _group_id -> g end

      %{pid: pid} =
        start_pool(
          construct_instance: construct_instance,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:ok, [%{fact: "X is a thing"}]} =
               GraphitiPool.search(pid, "g1", "how do I deploy a service", 5)

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      rec = Pythonx.decode(rec)
      assert rec["query"] == "how do I deploy a service"
      assert rec["num_results"] == 5

      GenServer.stop(pid)
    end

    test "and each returned edge is rendered as a fact carrying its text and its created, valid, invalid, and expired timestamps" do
      {g, _} =
        Pythonx.eval(
          """
          import asyncio
          from datetime import datetime, timezone

          class _Edge:
              def __init__(self, fact):
                  self.fact = fact
                  self.created_at = datetime(2024, 1, 1, tzinfo=timezone.utc)
                  self.valid_at = datetime(2024, 1, 2, tzinfo=timezone.utc)
                  self.invalid_at = datetime(2024, 1, 3, tzinfo=timezone.utc)
                  self.expired_at = datetime(2024, 1, 4, tzinfo=timezone.utc)

          class _FakeGraphiti:
              async def search(self, query, num_results=10):
                  return [_Edge("timestamps flow through")]

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:ok, [fact]} = GraphitiPool.search(pid, "g1", "q", 5)

      assert fact.fact == "timestamps flow through"
      assert fact.created_at == "2024-01-01 00:00:00+00:00"
      assert fact.valid_at == "2024-01-02 00:00:00+00:00"
      assert fact.invalid_at == "2024-01-03 00:00:00+00:00"
      assert fact.expired_at == "2024-01-04 00:00:00+00:00"

      GenServer.stop(pid)
    end

    test "and a standalone custom-entity node cannot be returned, because edge search matches edges by their endpoints" do
      assert {:ok, [%{fact: "X is a thing"} = fact]} = fact_search_result()
      refute Map.has_key?(fact, :name)
    end
  end

  describe "if running a fact search raises inside the graph library" do
    test "then an error carrying the raised exception is returned" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              async def search(self, query, num_results=10):
                  raise RuntimeError("boom")

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:error, {:python, message}} = GraphitiPool.search(pid, "g1", "q", 5)
      assert message =~ "boom"

      GenServer.stop(pid)
    end
  end

  describe "when an index and constraint rebuild is requested for the whole graph" do
    test "then every group the pool holds an instance for is rebuilt, each group being its own database" do
      {instance, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              def __init__(self):
                  self.initialisation_count = 0

              async def build_indices_and_constraints(self):
                  self.initialisation_count += 1

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group -> instance end,
          initialise_instance: fn _instance -> :ok end,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      GraphitiPool.for(pid, "operator_one")
      GraphitiPool.for(pid, "operator_two")

      assert {:ok, %{status: "built"}} = GraphitiPool.build_indices(pid)

      {count, _} = Pythonx.eval("g.initialisation_count", %{"g" => instance})
      assert Pythonx.decode(count) == 2

      GenServer.stop(pid)
    end

    test "and a group whose instance has never been created is left alone, its indices being built the moment it is" do
      construction_count = :counters.new(1, [])

      {instance, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              async def build_indices_and_constraints(self):
                  pass

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group ->
            :counters.add(construction_count, 1, 1)
            instance
          end,
          initialise_instance: &GraphitiPool.initialise_instance/1,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert ^instance = GraphitiPool.for(pid, "created")
      assert {:ok, %{status: "built"}} = GraphitiPool.build_indices(pid)
      assert :counters.get(construction_count, 1) == 1
    end
  end

  describe "when an episode search is run for a group" do
    test "then the graph library is asked for episodes only, with the requested result count" do
      {g, _} =
        Pythonx.eval(
          """
          import asyncio

          class _Episode:
              def __init__(self, content, source_description):
                  self.content = content
                  self.source_description = source_description

          class _Results:
              def __init__(self, episodes):
                  self.episodes = episodes
                  self.nodes = []
                  self.edges = []

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def search_(self, query, config=None, group_ids=None, search_filter=None):
                  self.recorded['query'] = query
                  self.recorded['group_ids'] = list(group_ids) if group_ids else []
                  self.recorded['limit'] = config.limit if config is not None else None
                  self.recorded['episode_methods'] = (
                      [m.value for m in config.episode_config.search_methods]
                      if config is not None and config.episode_config is not None
                      else None
                  )
                  self.recorded['edge_config'] = config.edge_config is not None
                  self.recorded['node_config'] = config.node_config is not None
                  return _Results([
                      _Episode("GEN|v1|{}\\nEli consistently prefers dark mode", "generalisation"),
                  ])

          _FakeGraphiti()
          """,
          %{}
        )

      construct_instance = fn _db, _shared, _group_id -> g end

      %{pid: pid} =
        start_pool(
          construct_instance: construct_instance,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:ok, [episode]} =
               GraphitiPool.search_episodes(pid, "group-with-hyphens", "dark mode", 5)

      assert episode.content == "GEN|v1|{}\nEli consistently prefers dark mode"
      assert episode.source_description == "generalisation"

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      rec = Pythonx.decode(rec)
      assert rec["query"] == "dark mode"
      assert rec["group_ids"] == ["group_with_hyphens"]
      assert rec["limit"] == 5
      assert rec["episode_methods"] == ["bm25"]
      refute rec["edge_config"]
      refute rec["node_config"]

      GenServer.stop(pid)
    end

    test "and it is restricted to the sanitised group id the episodes were written under" do
      {_episode, recorded} = episode_search_result()
      assert recorded["group_ids"] == ["group_with_hyphens"]
    end

    test "and each returned episode is rendered with the body that was written and its source description" do
      {episode, _recorded} = episode_search_result()
      assert episode.content == "GEN|v1|{}\nEli consistently prefers dark mode"
      assert episode.source_description == "generalisation"
    end

    test "and nothing an extractor derived from the episode is involved, so an episode no entity was extracted from is still returned" do
      {episode, _recorded} = episode_search_result()
      assert episode.content =~ "Eli consistently prefers dark mode"
    end
  end

  describe "if running an episode search raises inside the graph library" do
    test "then an error carrying the raised exception is returned" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              async def search_(self, query, config=None, group_ids=None, search_filter=None):
                  raise RuntimeError("boom")

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:error, {:python, message}} = GraphitiPool.search_episodes(pid, "g1", "q", 5)
      assert message =~ "boom"

      GenServer.stop(pid)
    end
  end

  describe "when a node search is run for a group" do
    test "then it is restricted to the sanitised group id the episodes were written under, so a group id carrying hyphens still matches" do
      {_node, recorded} = node_search_result()
      assert recorded["group_ids"] == ["group_with_hyphens"]
    end
  end

  describe "when a node search is run for a group > while node labels are supplied" do
    test "then the graph library's node search is invoked with the requested result count and a filter carrying those labels" do
      {g, _} =
        Pythonx.eval(
          """
          import asyncio

          class _Node:
              def __init__(self, name, summary, attributes):
                  self.name = name
                  self.summary = summary
                  self.attributes = attributes

          class _Results:
              def __init__(self, nodes):
                  self.nodes = nodes

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def search_(self, query, config=None, group_ids=None, search_filter=None):
                  self.recorded['query'] = query
                  self.recorded['group_ids'] = list(group_ids) if group_ids else []
                  self.recorded['limit'] = config.limit if config is not None else None
                  self.recorded['node_labels'] = (
                      list(search_filter.node_labels)
                      if search_filter is not None and search_filter.node_labels
                      else None
                  )
                  return _Results([
                      _Node("resource contention", "rescheduled the vacuum job to 04:00",
                            {"lesson": "reschedule overlapping jobs", "success": True}),
                  ])

          _FakeGraphiti()
          """,
          %{}
        )

      construct_instance = fn _db, _shared, _group_id -> g end

      %{pid: pid} =
        start_pool(
          construct_instance: construct_instance,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:ok, [node]} =
               GraphitiPool.search_nodes(
                 pid,
                 "group-with-hyphens",
                 "how do I resolve a scheduling conflict",
                 5,
                 node_labels: ["Learning"]
               )

      assert node.name == "resource contention"
      assert node.summary == "rescheduled the vacuum job to 04:00"
      assert node.attributes["lesson"] == "reschedule overlapping jobs"

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      rec = Pythonx.decode(rec)
      assert rec["query"] == "how do I resolve a scheduling conflict"
      assert rec["limit"] == 5
      assert rec["node_labels"] == ["Learning"]
      assert rec["group_ids"] == ["group_with_hyphens"]

      GenServer.stop(pid)
    end

    test "and each returned node is rendered with its name, summary, and attributes, ordered by relevance" do
      {node, _recorded} = node_search_result()
      assert node.name == "resource contention"
      assert node.summary == "rescheduled the vacuum job to 04:00"
      assert node.attributes["lesson"] == "reschedule overlapping jobs"
    end
  end

  describe "when a node search is run for a group > while no node labels are supplied" do
    test "then the graph library's node search is invoked with every node eligible" do
      {g, _} =
        Pythonx.eval(
          """
          class _Results:
              def __init__(self):
                  self.nodes = []

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def search_(self, query, config=None, group_ids=None, search_filter=None):
                  self.recorded['node_labels'] = (
                      list(search_filter.node_labels)
                      if search_filter is not None and search_filter.node_labels
                      else None
                  )
                  return _Results()

          _FakeGraphiti()
          """,
          %{}
        )

      construct_instance = fn _db, _shared, _group_id -> g end

      %{pid: pid} =
        start_pool(
          construct_instance: construct_instance,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:ok, []} = GraphitiPool.search_nodes(pid, "g1", "q", 5)

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      assert (rec |> Pythonx.decode())["node_labels"] == nil

      GenServer.stop(pid)
    end
  end

  describe "if running a node search raises inside the graph library" do
    test "then an error carrying the raised exception is returned" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              async def search_(self, query, config=None, group_ids=None, search_filter=None):
                  raise RuntimeError("boom")

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:error, {:python, message}} = GraphitiPool.search_nodes(pid, "g1", "q", 5)
      assert message =~ "boom"

      GenServer.stop(pid)
    end
  end

  describe "when a graph instance is requested for a group" do
    test "then the instance is looked up from a cache shared across callers" do
      counter = :counters.new(1, [])
      test_pid = self()

      construct_instance = fn _db, _shared, group ->
        :counters.add(counter, 1, 1)
        send(test_pid, {:constructed, group})
        {:stub_graphiti, group}
      end

      %{pid: pid, table: table} = start_pool(construct_instance: construct_instance)

      a1 = GraphitiPool.for(pid, "with-hyphens")
      assert_receive {:constructed, "with_hyphens"}
      assert :counters.get(counter, 1) == 1
      assert a1 == {:stub_graphiti, "with_hyphens"}

      assert [{"with_hyphens", {:stub_graphiti, "with_hyphens"}}] =
               :ets.lookup(table, "with_hyphens")

      a2 = GraphitiPool.for(pid, "with-hyphens")
      assert a2 == a1
      assert :counters.get(counter, 1) == 1

      b = GraphitiPool.for(pid, "another")
      assert_receive {:constructed, "another"}
      assert :counters.get(counter, 1) == 2
      refute b == a1

      assert Enum.sort(Enum.map(:ets.tab2list(table), fn {k, _} -> k end)) ==
               ["another", "with_hyphens"]
    end
  end

  describe "when a graph instance is requested for a group > while no instance is cached for that group > while construction takes longer than the default call timeout" do
    @tag timeout: 30_000
    test "then construction still runs to completion" do
      slow_construct = fn _db, _shared, group ->
        Process.sleep(5_500)
        {:stub_graphiti, group}
      end

      %{pid: pid} = start_pool(construct_instance: slow_construct)

      assert {:stub_graphiti, "slowgroup"} = GraphitiPool.for(pid, "slowgroup")
    end
  end

  describe "when a graph instance is requested for a group > while no instance is cached for that group" do
    test "then the instance is constructed, cached, and held for the pool's lifetime" do
      construction_count = :counters.new(1, [])

      %{pid: pid, table: table} =
        start_pool(
          construct_instance: fn _db, _shared, group ->
            :counters.add(construction_count, 1, 1)
            {:instance, group}
          end
        )

      assert {:instance, "operator_one"} = GraphitiPool.for(pid, "operator-one")
      assert [{"operator_one", {:instance, "operator_one"}}] = :ets.lookup(table, "operator_one")
      assert {:instance, "operator_one"} = GraphitiPool.for(pid, "operator-one")
      assert :counters.get(construction_count, 1) == 1
    end

    test "and index and constraint building is invoked before the instance is cached and returned" do
      {instance, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              def __init__(self):
                  self.initialisation_count = 0

              async def build_indices_and_constraints(self):
                  self.initialisation_count += 1

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid, table: table} =
        start_pool(
          construct_instance: fn _db, _shared, _group -> instance end,
          initialise_instance: &GraphitiPool.initialise_instance/1,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert ^instance = GraphitiPool.for(pid, "indexed")
      assert [{"indexed", ^instance}] = :ets.lookup(table, "indexed")

      {count, _} = Pythonx.eval("g.initialisation_count", %{"g" => instance})
      assert Pythonx.decode(count) == 1

      assert ^instance = GraphitiPool.for(pid, "indexed")
      {count, _} = Pythonx.eval("g.initialisation_count", %{"g" => instance})
      assert Pythonx.decode(count) == 1
    end
  end

  describe "when a graph instance is requested for a group > while no instance is cached for that group > if index and constraint building fails" do
    test "then the failure is non-fatal" do
      {instance, _} =
        Pythonx.eval(
          """
          class _FailingGraphiti:
              async def build_indices_and_constraints(self):
                  raise RuntimeError("index setup unavailable")

          _FailingGraphiti()
          """,
          %{}
        )

      log =
        capture_log(fn ->
          %{pid: pid, table: table} =
            start_pool(
              construct_instance: fn _db, _shared, _group -> instance end,
              initialise_instance: &GraphitiPool.initialise_instance/1,
              install_loop_fn: &Gralkor.Python.install_async_runtime/0
            )

          assert ^instance = GraphitiPool.for(pid, "best-effort")
          assert [{"best_effort", ^instance}] = :ets.lookup(table, "best_effort")
          assert ^instance = GraphitiPool.for(pid, "best-effort")
        end)

      assert log =~ "build_indices_and_constraints failed (non-fatal)"
      assert log =~ "RuntimeError: index setup unavailable"
    end

    test "and the instance is still cached and returned" do
      %{pid: pid, table: table} =
        start_pool(
          construct_instance: fn _db, _shared, group -> {:instance, group} end,
          initialise_instance: fn _instance -> raise "index setup unavailable" end
        )

      capture_log(fn ->
        assert {:instance, "best_effort"} = GraphitiPool.for(pid, "best-effort")
      end)

      assert [{"best_effort", {:instance, "best_effort"}}] =
               :ets.lookup(table, "best_effort")
    end
  end

  describe "when a graph instance is requested for a group > while instances are already cached for their groups" do
    test "then concurrent callers read those instances in parallel without passing through the pool process" do
      construct_instance = fn _db, _shared, group ->
        Process.sleep(100)
        {:stub_graphiti, group}
      end

      %{pid: pid} = start_pool(construct_instance: construct_instance)

      {us, results} =
        :timer.tc(fn ->
          1..4
          |> Task.async_stream(
            fn i -> GraphitiPool.for(pid, "g#{i}") end,
            max_concurrency: 4,
            ordered: false
          )
          |> Enum.map(fn {:ok, r} -> r end)
        end)

      ms = div(us, 1000)
      assert length(results) == 4

      {us_cached, _} =
        :timer.tc(fn ->
          1..100
          |> Task.async_stream(
            fn i -> GraphitiPool.for(pid, "g#{rem(i, 4) + 1}") end,
            max_concurrency: 100
          )
          |> Stream.run()
        end)

      assert div(us_cached, 1000) < 50,
             "100 concurrent cached reads should be near-instant (no GenServer hop), got #{div(us_cached, 1000)}ms (initial creation took #{ms}ms)"
    end
  end

  describe "when the pool starts > while a remote connection is configured" do
    test "then the remote database is constructed once and held for the pool's lifetime" do
      falkor_db_count = :counters.new(1, [])
      instance_count = :counters.new(1, [])

      construct_falkor_db = fn {:remote, _} ->
        :counters.add(falkor_db_count, 1, 1)
        {:stub_falkor_db, :counters.get(falkor_db_count, 1)}
      end

      construct_instance = fn db, _shared, group ->
        :counters.add(instance_count, 1, 1)
        {:stub_graphiti, group, db, :counters.get(instance_count, 1)}
      end

      %{pid: pid, table: table} =
        start_pool(
          falkordb_spec: {:remote, host: "h", port: 1, username: "u", password: "p", ssl: false},
          construct_falkor_db: construct_falkor_db,
          construct_instance: construct_instance,
          warmup: false
        )

      assert :counters.get(falkor_db_count, 1) == 1,
             "remote AsyncFalkorDB is constructed exactly once, at init"

      a = GraphitiPool.for(pid, "with-hyphens")
      assert :counters.get(instance_count, 1) == 1
      assert match?({:stub_graphiti, "with_hyphens", {:stub_falkor_db, 1}, _}, a)

      assert [{"with_hyphens", ^a}] = :ets.lookup(table, "with_hyphens")

      b = GraphitiPool.for(pid, "with-hyphens")
      assert b == a
      assert :counters.get(instance_count, 1) == 1
      assert :counters.get(falkor_db_count, 1) == 1

      c = GraphitiPool.for(pid, "another")
      assert :counters.get(instance_count, 1) == 2
      refute c == a
      assert :counters.get(falkor_db_count, 1) == 1

      assert Enum.sort(Enum.map(:ets.tab2list(table), fn {k, _} -> k end)) ==
               ["another", "with_hyphens"]
    end
  end

  describe "when the pool starts" do
    test "then the shared asyncio runtime is installed, so the pool can be started on its own" do
      install_count = :counters.new(1, [])

      install_loop_fn = fn ->
        :counters.add(install_count, 1, 1)
        :ok
      end

      %{pid: pid} = start_pool(install_loop_fn: install_loop_fn)
      assert Process.alive?(pid)
      assert :counters.get(install_count, 1) == 1
    end

    test "and the LLM client, the embedder, and the cross-encoder are each constructed once and shared by every graph instance for the pool's lifetime" do
      shared_count = :counters.new(1, [])
      instance_shareds = :ets.new(:shareds, [:public, :duplicate_bag])

      shared = %{llm_client: :the_llm, embedder: :the_embedder, cross_encoder: :the_xenc}

      construct_shared_clients = fn _llm, _embedder ->
        :counters.add(shared_count, 1, 1)
        shared
      end

      construct_instance = fn _db, received_shared, group ->
        :ets.insert(instance_shareds, {group, received_shared})
        {:stub_graphiti, group}
      end

      %{pid: pid} =
        start_pool(
          construct_shared_clients: construct_shared_clients,
          construct_instance: construct_instance
        )

      _ = GraphitiPool.for(pid, "g1")
      _ = GraphitiPool.for(pid, "g2")
      _ = GraphitiPool.for(pid, "g3")

      assert :counters.get(shared_count, 1) == 1

      shareds = instance_shareds |> :ets.tab2list() |> Enum.map(fn {_, s} -> s end)
      assert length(shareds) == 3
      assert Enum.uniq(shareds) == [shared]
    end
  end

  describe "when the pool starts > while both configured model specs name a supported inference provider" do
    test "then client construction proceeds using the configured model ids" do
      test_pid = self()

      supported_pairs = [
        {%{provider: :google, id: "gemini-custom"},
         %{provider: :google, id: "gemini-embedding-custom"}},
        {%{provider: :openai, id: "gpt-4.1-mini"},
         %{provider: :openai, id: "text-embedding-3-small"}}
      ]

      Enum.each(supported_pairs, fn {llm_model, embedder_model} ->
        %{pid: pid} =
          start_pool(
            llm_model: llm_model,
            embedder_model: embedder_model,
            construct_shared_clients: fn received_llm, received_embedder ->
              send(test_pid, {:construct_shared, received_llm, received_embedder})
              %{llm_client: nil, embedder: nil, cross_encoder: nil}
            end
          )

        assert_receive {:construct_shared, ^llm_model, ^embedder_model}
        assert Process.alive?(pid)
      end)
    end

    test "and the LLM client is built for the provider the LLM spec names" do
      spec =
        GraphitiPool.shared_client_spec(
          %{provider: :openai, id: "gpt-4.1-mini"},
          %{provider: :google, id: "gemini-embedding-2-preview"}
        )

      assert spec.llm.provider == :openai
      assert spec.llm.id == "gpt-4.1-mini"
    end

    test "and the embedder is built for the provider the embedder spec names" do
      spec =
        GraphitiPool.shared_client_spec(
          %{provider: :openai, id: "gpt-4.1-mini"},
          %{provider: :google, id: "gemini-embedding-2-preview"}
        )

      assert spec.embedder.provider == :google
      assert spec.embedder.id == "gemini-embedding-2-preview"
    end

    test "and the cross-encoder is built for the provider the LLM spec names" do
      spec =
        GraphitiPool.shared_client_spec(
          %{provider: :openai, id: "gpt-4.1-mini"},
          %{provider: :google, id: "gemini-embedding-2-preview"}
        )

      assert spec.cross_encoder.provider == :openai
    end

    test "and each provider credential is passed explicitly from the BEAM side" do
      previous_openai = System.get_env("OPENAI_API_KEY")
      previous_google = System.get_env("GOOGLE_API_KEY")

      on_exit(fn ->
        restore_env("OPENAI_API_KEY", previous_openai)
        restore_env("GOOGLE_API_KEY", previous_google)
      end)

      System.put_env("OPENAI_API_KEY", "openai-secret")
      System.put_env("GOOGLE_API_KEY", "google-secret")

      assert GraphitiPool.api_key!(:openai) == "openai-secret"
      assert GraphitiPool.api_key!(:google) == "google-secret"
    end
  end

  describe "when the pool starts > while both configured model specs name a supported inference provider > while the two specs name different providers" do
    test "and startup completes" do
      test_pid = self()
      llm_model = %{provider: :openai, id: "gpt-4.1-mini"}
      embedder_model = %{provider: :google, id: "gemini-embedding-2-preview"}

      %{pid: pid} =
        start_pool(
          llm_model: llm_model,
          embedder_model: embedder_model,
          construct_shared_clients: fn received_llm, received_embedder ->
            send(test_pid, {:construct_shared, received_llm, received_embedder})
            %{llm_client: nil, embedder: nil, cross_encoder: nil}
          end
        )

      assert_receive {:construct_shared, ^llm_model, ^embedder_model}
      assert Process.alive?(pid)
    end

    test "then each client is still built for its own role's provider" do
      spec =
        GraphitiPool.shared_client_spec(
          %{provider: :google, id: "gemini-3.1-flash-lite"},
          %{provider: :openai, id: "text-embedding-3-small"}
        )

      assert spec.llm.provider == :google
      assert spec.embedder.provider == :openai
      assert spec.cross_encoder.provider == :google
    end
  end

  describe "when the pool has constructed its database" do
    test "then a warmup search runs once against a throwaway query and group, paying the cold-start cost before any consumer can recall" do
      interpret_count = :counters.new(1, [])

      interpret_fn = fn _text, _budget ->
        :counters.add(interpret_count, 1, 1)
        :ok
      end

      log =
        capture_log(fn ->
          %{pid: pid} = start_pool(interpret_fn: interpret_fn, warmup: true)
          assert Process.alive?(pid)
          GenServer.stop(pid)
        end)

      assert :counters.get(interpret_count, 1) == 1

      assert log =~ "[gralkor] warmup failed (non-fatal) — search",
             "search is invoked once (with stubs it fails the rescued Pythonx eval; the warning line proves the invocation)"
    end

    test "and a single line reporting the search, interpretation, and total warmup durations is logged" do
      log =
        capture_log(fn ->
          %{pid: pid} = start_pool(interpret_fn: fn _, _ -> :ok end, warmup: true)
          GenServer.stop(pid)
        end)

      assert log =~ ~r/\[gralkor\] warmup — search:\d+ interpret:\d+ \d+ms/
    end

    test "and a warmup interpretation runs once against an empty conversation and throwaway facts" do
      test_pid = self()

      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def search(self, query, num_results=10):
                  self.recorded['query'] = query
                  self.recorded['num_results'] = num_results
                  return []

          _FakeGraphiti()
          """,
          %{}
        )

      construct_instance = fn _db, _shared, group_id ->
        send(test_pid, {:construct_instance, group_id})
        g
      end

      interpret_fn = fn text, budget ->
        send(test_pid, {:interpret_fn, text, budget})
        :ok
      end

      log =
        capture_log(fn ->
          %{pid: pid} =
            start_pool(
              construct_instance: construct_instance,
              interpret_fn: interpret_fn,
              warmup: true,
              install_loop_fn: &Gralkor.Python.install_async_runtime/0
            )

          assert Process.alive?(pid)
          GenServer.stop(pid)
        end)

      assert_receive {:construct_instance, "warmup"}
      assert_receive {:interpret_fn, prompt, 2_000}

      assert prompt ==
               Gralkor.Interpret.build_interpretation_context([], "warmup", "- warmup", "warmup")

      assert prompt =~ "Memory facts to interpret:\n- warmup"

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      rec = Pythonx.decode(rec)
      assert rec["query"] == "warmup"
      assert rec["num_results"] == 1

      refute log =~ "warmup failed"
    end
  end

  describe "when the pool has constructed its database > where no warmup interpretation callback is configured" do
    test "then warmup interpretation is skipped with a numeric zero duration" do
      log =
        capture_log(fn ->
          %{pid: pid} = start_pool(successful_warmup_opts())
          GenServer.stop(pid)
        end)

      assert log =~ ~r/\[gralkor\] warmup — search:\d+ interpret:0 \d+ms/
    end

    test "and startup completes" do
      capture_log(fn ->
        %{pid: pid} = start_pool(successful_warmup_opts())
        assert Process.alive?(pid)
        GenServer.stop(pid)
      end)
    end
  end

  describe "when the pool starts > while both configured model specs name a supported inference provider > while the embedder spec names Google" do
    test "then the embedder sends one input per request" do
      spec =
        GraphitiPool.shared_client_spec(
          %{provider: :google, id: "gemini-3.1-flash-lite"},
          %{provider: :google, id: "gemini-embedding-2-preview"}
        )

      assert spec.embedder.batch_size == 1
    end
  end

  describe "if either configured model spec names a provider that is neither OpenAI nor Google" do
    setup do
      previous_trap_exit = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)
      :ok
    end

    test "then startup raises before any inference client is constructed" do
      test_pid = self()

      unsupported_pairs = [
        {%{provider: :anthropic, id: "claude-opus-5"},
         %{provider: :google, id: "gemini-embedding-2-preview"}},
        {%{provider: :google, id: "gemini-3.1-flash-lite"},
         %{provider: :cohere, id: "embed-english-v3.0"}}
      ]

      Enum.each(unsupported_pairs, fn {llm_model, embedder_model} ->
        assert {:error, {%ArgumentError{}, _stacktrace}} =
                 GraphitiPool.start_link(
                   name: nil,
                   table: :"pool_table_#{System.unique_integer([:positive])}",
                   falkordb_spec: {:embedded, "/tmp/never_used"},
                   llm_model: llm_model,
                   embedder_model: embedder_model,
                   construct_shared_clients: fn _, _ ->
                     send(test_pid, :inference_client_construction_started)
                     %{llm_client: nil, embedder: nil, cross_encoder: nil}
                   end,
                   construct_falkor_db: fn _ -> :stub_falkor_db end,
                   construct_instance: fn _, _, group -> {:stub_graphiti, group} end,
                   initialise_instance: fn _ -> :ok end,
                   install_loop_fn: fn -> :ok end,
                   warmup: false
                 )

        refute_received :inference_client_construction_started
      end)
    end

    test "and the failure names both configured model specs" do
      error = unsupported_provider_error()
      assert Exception.message(error) =~ "anthropic"
      assert Exception.message(error) =~ "google"
    end

    test "and the failure names the providers that are supported" do
      message = unsupported_provider_error() |> Exception.message()
      assert message =~ "openai"
      assert message =~ "google"
    end
  end

  describe "if the credential for a provider named by a configured model spec is absent or blank" do
    setup do
      previous_trap_exit = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

      previous = %{
        "GOOGLE_API_KEY" => System.get_env("GOOGLE_API_KEY"),
        "OPENAI_API_KEY" => System.get_env("OPENAI_API_KEY")
      }

      on_exit(fn ->
        Enum.each(previous, fn
          {var, nil} -> System.delete_env(var)
          {var, value} -> System.put_env(var, value)
        end)
      end)

      :ok
    end

    defp start_pool_for_credentials(llm_model, embedder_model, test_pid) do
      GraphitiPool.start_link(
        name: nil,
        table: :"pool_table_#{System.unique_integer([:positive])}",
        falkordb_spec: {:embedded, "/tmp/never_used"},
        llm_model: llm_model,
        embedder_model: embedder_model,
        construct_shared_clients: fn _, _ ->
          send(test_pid, :inference_client_construction_started)
          %{llm_client: nil, embedder: nil, cross_encoder: nil}
        end,
        construct_falkor_db: fn _ -> :stub_falkor_db end,
        construct_instance: fn _, _, group -> {:stub_graphiti, group} end,
        initialise_instance: fn _ -> :ok end,
        install_loop_fn: fn -> :ok end,
        warmup: false
      )
    end

    test "then startup raises before any inference client is constructed" do
      test_pid = self()
      System.put_env("GOOGLE_API_KEY", "present")
      System.delete_env("OPENAI_API_KEY")

      assert {:error, {%ArgumentError{} = llm_error, _}} =
               start_pool_for_credentials(
                 %{provider: :openai, id: "gpt-4.1-mini"},
                 %{provider: :google, id: "gemini-embedding-2-preview"},
                 test_pid
               )

      llm_message = Exception.message(llm_error)
      refute_received :inference_client_construction_started

      assert {:error, {%ArgumentError{} = embedder_error, _}} =
               start_pool_for_credentials(
                 %{provider: :google, id: "gemini-3.1-flash-lite"},
                 %{provider: :openai, id: "text-embedding-3-small"},
                 test_pid
               )

      embedder_message = Exception.message(embedder_error)
      refute_received :inference_client_construction_started
      assert is_binary(llm_message)
      assert is_binary(embedder_message)
    end

    test "and the failure names the absent credential" do
      test_pid = self()

      for blank <- ["", "  \t  "] do
        System.put_env("GOOGLE_API_KEY", blank)

        assert {:error, {%ArgumentError{} = error, _}} =
                 start_pool_for_credentials(
                   %{provider: :google, id: "gemini-3.1-flash-lite"},
                   %{provider: :google, id: "gemini-embedding-2-preview"},
                   test_pid
                 )

        assert Exception.message(error) =~ "GOOGLE_API_KEY"
        refute_received :inference_client_construction_started
      end
    end

    test "and the failure names the role whose spec required it" do
      test_pid = self()
      System.put_env("GOOGLE_API_KEY", "present")
      System.delete_env("OPENAI_API_KEY")

      assert {:error, {%ArgumentError{} = error, _}} =
               start_pool_for_credentials(
                 %{provider: :openai, id: "gpt-4.1-mini"},
                 %{provider: :google, id: "gemini-embedding-2-preview"},
                 test_pid
               )

      assert Exception.message(error) =~ "llm"
    end
  end

  describe "where a provider is named by neither configured model spec" do
    setup do
      previous = System.get_env("OPENAI_API_KEY")

      on_exit(fn ->
        if previous,
          do: System.put_env("OPENAI_API_KEY", previous),
          else: System.delete_env("OPENAI_API_KEY")
      end)

      :ok
    end

    test "then its absent credential does not prevent startup" do
      System.put_env("GOOGLE_API_KEY", "present")
      System.delete_env("OPENAI_API_KEY")

      %{pid: pid} =
        start_pool(
          llm_model: %{provider: :google, id: "gemini-3.1-flash-lite"},
          embedder_model: %{provider: :google, id: "gemini-embedding-2-preview"}
        )

      assert Process.alive?(pid)
    end
  end

  describe "when the pool starts > while both configured model specs name a supported inference provider > where the credential exists only in the BEAM environment" do
    test "then the credential still reaches the provider client" do
      var = "GRALKOR_CREDENTIAL_DELIVERY_PROBE_#{System.unique_integer([:positive])}"
      on_exit(fn -> System.delete_env(var) end)

      System.put_env(var, "set-from-elixir")
      assert System.get_env(var) == "set-from-elixir"

      {seen_by_python, _} =
        Pythonx.eval(
          """
          import os
          os.environ.get(name.decode('utf-8'), '<<ABSENT>>')
          """,
          %{"name" => var}
        )

      assert Pythonx.decode(seen_by_python) == "<<ABSENT>>",
             "os:putenv reached the interpreter's environment; api_key!/1 could then be replaced by letting the Python client read the variable itself"

      System.put_env("OPENAI_API_KEY", "openai-secret")
      assert GraphitiPool.api_key!(:openai) == "openai-secret"
    end
  end

  describe "when the pool terminates" do
    test "then the database it held for its lifetime is closed through the shared asyncio runtime" do
      test_pid = self()

      %{pid: pid} =
        start_pool(
          close_falkor_db: fn database ->
            send(test_pid, {:closed, database})
            :ok
          end
        )

      GenServer.stop(pid)

      assert_receive {:closed, :stub_falkor_db}
    end
  end

  describe "when the pool terminates > while a remote connection is configured" do
    @describetag :integration

    test "then the remote database client is closed before termination completes" do
      previous_key = System.get_env("OPENAI_API_KEY")
      System.put_env("OPENAI_API_KEY", "test-key")

      {original, _} =
        Pythonx.eval(
          """
          import falkordb.asyncio as falkor_asyncio
          original = falkor_asyncio.FalkorDB

          class _CloseProbe:
              def __init__(self, **kwargs):
                  self.closed = False

              async def aclose(self):
                  self.closed = True

          falkor_asyncio.FalkorDB = _CloseProbe
          original
          """,
          %{}
        )

      on_exit(fn ->
        if previous_key,
          do: System.put_env("OPENAI_API_KEY", previous_key),
          else: System.delete_env("OPENAI_API_KEY")

        Pythonx.eval(
          "import falkordb.asyncio as falkor_asyncio; falkor_asyncio.FalkorDB = original",
          %{"original" => original}
        )
      end)

      table = :"remote_close_pool_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        GraphitiPool.start_link(
          name: nil,
          table: table,
          falkordb_spec: {:remote, host: "memory.example", port: 6379},
          construct_shared_clients: fn _llm, _embedder ->
            %{llm_client: nil, embedder: nil, cross_encoder: nil}
          end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      database = :sys.get_state(pid).falkor_db
      GenServer.stop(pid)

      {closed, _} = Pythonx.eval("database.closed", %{"database" => database})
      assert Pythonx.decode(closed)
    end
  end

  describe "when the pool terminates > while an embedded connection is configured" do
    @describetag :integration

    setup do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_close_#{System.unique_integer([:positive])}")

      table = :"close_pool_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        GraphitiPool.start_link(
          name: nil,
          table: table,
          falkordb_spec: {:embedded, data_dir},
          construct_shared_clients: fn _llm, _embedder ->
            %{llm_client: nil, embedder: nil, cross_encoder: nil}
          end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      database = :sys.get_state(pid).falkor_db
      {server_pid, _globals} = Pythonx.eval("database.client.pid", %{"database" => database})
      server_pid = Pythonx.decode(server_pid)

      assert {_, 0} = System.cmd("ps", ["-p", to_string(server_pid), "-o", "pid="])

      GenServer.stop(pid)

      %{database: database, data_dir: data_dir, server_pid: server_pid}
    end

    test "then the owned embedded server exits before termination completes", %{
      server_pid: server_pid
    } do
      assert {_, status} = System.cmd("ps", ["-p", to_string(server_pid), "-o", "pid="])
      assert status != 0
    end

    test "and finalising the async wrapper emits no unawaited-coroutine warning", %{
      database: database,
      data_dir: data_dir
    } do
      {warnings, _globals} =
        Pythonx.eval(
          """
          import warnings
          with warnings.catch_warnings(record=True) as caught:
              warnings.simplefilter('always')
              database.client._cleanup()
          [str(item.message) for item in caught]
          """,
          %{"database" => database}
        )

      refute Enum.any?(Pythonx.decode(warnings), &String.contains?(&1, "was never awaited"))
      File.rm_rf!(data_dir)
    end
  end

  describe "when the pool has constructed its database > if a warmup call raises or returns an error" do
    test "then the failure is logged as non-fatal, naming the stage and the reason" do
      log =
        capture_log(fn ->
          %{pid: pid} = start_pool(interpret_fn: fn _, _ -> :ok end, warmup: true)
          assert Process.alive?(pid), "boot proceeded after warmup failure"
          GenServer.stop(pid)
        end)

      assert log =~ "[gralkor] warmup failed (non-fatal) — search:"
    end

    test "and startup completes anyway" do
      capture_log(fn ->
        %{pid: pid} = start_pool(interpret_fn: fn _, _ -> :ok end, warmup: true)
        assert Process.alive?(pid)
        GenServer.stop(pid)
      end)
    end
  end

  describe "when the pool has constructed its database > if a warmup call raises or returns an error > while warmup interpretation returns an error" do
    test "then the interpretation failure is logged with its returned reason" do
      log =
        capture_log(fn ->
          opts = successful_warmup_opts(interpret_fn: fn _, _ -> {:error, :warmup_boom} end)
          %{pid: pid} = start_pool(opts)
          assert Process.alive?(pid)
          GenServer.stop(pid)
        end)

      assert log =~ "[gralkor] warmup failed (non-fatal) — interpret: :warmup_boom"
    end
  end

  describe "when the pool starts > while an embedded connection is configured" do
    @describetag :integration

    test "then stale embedded resume state is removed before database construction" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)

      stale_tmp =
        Path.join(System.tmp_dir!(), "gralkor_stale_#{System.unique_integer([:positive])}")

      File.mkdir_p!(stale_tmp)
      File.write!(Path.join(stale_tmp, "redis.socket"), "")

      File.write!(
        Path.join(stale_tmp, "redis.pid"),
        Integer.to_string(System.pid() |> String.to_integer())
      )

      File.write!(
        Path.join(data_dir, "gralkor.db.settings"),
        Jason.encode!(%{
          "pidfile" => Path.join(stale_tmp, "redis.pid"),
          "unixsocket" => Path.join(stale_tmp, "redis.socket"),
          "dbdir" => data_dir,
          "dbfilename" => "gralkor.db"
        })
      )

      settings_path = Path.join(data_dir, "gralkor.db.settings")
      test_pid = self()

      construct_falkor_db = fn {:embedded, ^data_dir} ->
        send(test_pid, {:settings_present_at_construction, File.exists?(settings_path)})
        :stub_falkor_db
      end

      {:ok, pid} =
        start_embedded_pool(data_dir, construct_falkor_db: construct_falkor_db)

      assert Process.alive?(pid)
      assert_receive {:settings_present_at_construction, false}

      GenServer.stop(pid)
      File.rm_rf!(data_dir)
      File.rm_rf!(stale_tmp)
    end

    test "and the embedded database is constructed once and held for the pool's lifetime" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)

      construction_count = :counters.new(1, [])
      instance_databases = :ets.new(:instance_databases, [:public, :duplicate_bag])

      construct_falkor_db = fn {:embedded, ^data_dir} ->
        :counters.add(construction_count, 1, 1)
        :embedded_database
      end

      construct_instance = fn database, _shared, group_id ->
        :ets.insert(instance_databases, {group_id, database})
        {:stub_graphiti, group_id}
      end

      {:ok, pid} =
        start_embedded_pool(data_dir,
          construct_falkor_db: construct_falkor_db,
          construct_instance: construct_instance
        )

      assert Process.alive?(pid)
      assert {:stub_graphiti, "one"} = GraphitiPool.for(pid, "one")
      assert {:stub_graphiti, "two"} = GraphitiPool.for(pid, "two")
      assert :counters.get(construction_count, 1) == 1

      assert Enum.sort(:ets.tab2list(instance_databases)) ==
               [{"one", :embedded_database}, {"two", :embedded_database}]

      GenServer.stop(pid)
      File.rm_rf!(data_dir)
    end
  end

  describe "when an episode is added > while an ontology module is supplied" do
    @describetag :integration

    defmodule StrictOntologyForGraphitiTest do
      use Gralkor.Ontology, entities: :strict, relationships: :scoped

      entity User do
        field(:handle, :string, required: true)
      end

      entity Preference do
        field(:description, :string, required: true)
      end

      from User do
        prefers Preference do
          field(:since, :string)
        end
      end
    end

    defmodule OpenOntologyForGraphitiTest do
      use Gralkor.Ontology, entities: :open, relationships: :open

      entity User do
        field(:handle, :string, required: true)
      end

      entity Preference do
        field(:description, :string, required: true)
      end

      from User do
        prefers(Preference)
      end
    end

    test "then that ontology is translated into the graph library's schema representation on first encounter" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)

      {:ok, pid} = start_embedded_pool(data_dir)

      try do
        strict = GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)

        strict_again =
          GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)

        strict_merged =
          GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest, true}, :infinity)

        strict_merged_again =
          GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest, true}, :infinity)

        assert Enum.sort(Map.keys(strict)) ==
                 ["edge_type_map", "edge_types", "entity_types", "excluded_entity_types"]

        assert strict["excluded_entity_types"] == ["Entity"]

        assert strict === strict_again
        assert strict_merged === strict_merged_again
        refute strict === strict_merged
      after
        GenServer.stop(pid)
        File.rm_rf!(data_dir)
      end
    end

    test "and a later add with the same ontology reuses the translated representation rather than rebuilding it" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)
      {:ok, pid} = start_embedded_pool(data_dir)

      try do
        first = GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)
        second = GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)
        assert first === second
      after
        GenServer.stop(pid)
        File.rm_rf!(data_dir)
      end
    end

    test "and the forwarded dictionary carries exactly the keys the ontology selects, omitting the rest" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)
      {:ok, pid} = start_embedded_pool(data_dir)

      try do
        strict = GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)

        assert Enum.sort(Map.keys(strict)) ==
                 ["edge_type_map", "edge_types", "entity_types", "excluded_entity_types"]
      after
        GenServer.stop(pid)
        File.rm_rf!(data_dir)
      end
    end

    test "and the forwarded dictionary uses the graph library's key names outside and the ontology's declared type names inside" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)
      {:ok, pid} = start_embedded_pool(data_dir)

      try do
        strict = GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)
        open = GenServer.call(pid, {:materialise, OpenOntologyForGraphitiTest}, :infinity)

        assert Enum.sort(Map.keys(strict)) ==
                 ["edge_type_map", "edge_types", "entity_types", "excluded_entity_types"]

        assert Enum.sort(Map.keys(open)) == ["edge_types", "entity_types"]

        {type_keys, _} =
          Pythonx.eval(
            "[sorted(entity_types.keys()), sorted(edge_types.keys())]",
            %{"entity_types" => strict["entity_types"], "edge_types" => strict["edge_types"]}
          )

        assert Pythonx.decode(type_keys) == [["Preference", "User"], ["PREFERS"]]
      after
        GenServer.stop(pid)
        File.rm_rf!(data_dir)
      end
    end
  end

  describe "when an episode is added > while the write asks for the built-in Learning entity type" do
    @describetag :integration

    test "then Learning is merged into the effective entity types even without a supplied ontology" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)

      {:ok, pid} = start_embedded_pool(data_dir)

      try do
        merged =
          GenServer.call(
            pid,
            {:materialise, StrictOntologyForGraphitiTest, true},
            :infinity
          )

        {names, _} =
          Pythonx.eval(
            "[cls.__name__ for cls in entity_types.values()]",
            %{"entity_types" => merged["entity_types"]}
          )

        names = names |> Pythonx.decode() |> Enum.sort()

        assert "Learning" in names
        assert "User" in names
        assert "Preference" in names
      after
        GenServer.stop(pid)
        File.rm_rf!(data_dir)
      end
    end

    test "and the merged translation is cached separately from the same ontology's unmerged translation" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)

      {:ok, pid} = start_embedded_pool(data_dir)

      try do
        plain = GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)

        merged =
          GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest, true}, :infinity)

        plain_again =
          GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)

        merged_again =
          GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest, true}, :infinity)

        assert plain === plain_again
        assert merged === merged_again
        refute plain === merged
      after
        GenServer.stop(pid)
        File.rm_rf!(data_dir)
      end
    end
  end

  defp unsupported_provider_error do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, {%ArgumentError{} = error, _stacktrace}} =
               GraphitiPool.start_link(
                 name: nil,
                 table: :"pool_table_#{System.unique_integer([:positive])}",
                 falkordb_spec: {:embedded, "/tmp/never_used"},
                 llm_model: %{provider: :anthropic, id: "claude-opus-5"},
                 embedder_model: %{provider: :google, id: "gemini-embedding-2-preview"},
                 construct_shared_clients: fn _, _ ->
                   %{llm_client: nil, embedder: nil, cross_encoder: nil}
                 end,
                 construct_falkor_db: fn _ -> :stub_falkor_db end,
                 construct_instance: fn _, _, group -> {:stub_graphiti, group} end,
                 initialise_instance: fn _ -> :ok end,
                 install_loop_fn: fn -> :ok end,
                 warmup: false
               )

      error
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp successful_warmup_opts(extra_opts \\ []) do
    {graph, _} =
      Pythonx.eval(
        """
        class _SuccessfulWarmupGraphiti:
            async def search(self, query, num_results=10):
                return []

        _SuccessfulWarmupGraphiti()
        """,
        %{}
      )

    Keyword.merge(
      [
        construct_instance: fn _db, _shared, _group -> graph end,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0,
        warmup: true
      ],
      extra_opts
    )
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp replacement_graphiti do
    Pythonx.eval(
      """
      class _ReplacementDriver:
          def __init__(self):
              self.recorded = []

          async def execute_query(self, query, **params):
              self.recorded.append({"query": query, "params": params})
              return []

      class _ReplacementGraphiti:
          def __init__(self):
              self.driver = _ReplacementDriver()

      _ReplacementGraphiti()
      """,
      %{}
    )
  end

  defp fact_search_result do
    {graph, _} =
      Pythonx.eval(
        """
        class _Edge:
            def __init__(self):
                self.fact = "X is a thing"
                self.created_at = None
                self.valid_at = None
                self.invalid_at = None
                self.expired_at = None

        class _FakeGraphiti:
            async def search(self, query, num_results=10):
                return [_Edge()]

        _FakeGraphiti()
        """,
        %{}
      )

    %{pid: pid} =
      start_pool(
        construct_instance: fn _db, _shared, _group -> graph end,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      )

    result = GraphitiPool.search(pid, "g1", "q", 5)
    GenServer.stop(pid)
    result
  end

  defp episode_search_result do
    {graph, _} =
      Pythonx.eval(
        """
        class _Episode:
            def __init__(self):
                self.content = "GEN|v1|{}\\nEli consistently prefers dark mode"
                self.source_description = "generalisation"

        class _Results:
            def __init__(self):
                self.episodes = [_Episode()]
                self.nodes = []
                self.edges = []

        class _FakeGraphiti:
            def __init__(self):
                self.group_ids = []

            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                self.group_ids = list(group_ids)
                return _Results()

        _FakeGraphiti()
        """,
        %{}
      )

    %{pid: pid} =
      start_pool(
        construct_instance: fn _db, _shared, _group -> graph end,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      )

    assert {:ok, [episode]} =
             GraphitiPool.search_episodes(pid, "group-with-hyphens", "dark mode", 5)

    {group_ids, _} = Pythonx.eval("g.group_ids", %{"g" => graph})
    GenServer.stop(pid)
    {episode, %{"group_ids" => Pythonx.decode(group_ids)}}
  end

  defp node_search_result do
    {graph, _} =
      Pythonx.eval(
        """
        class _Node:
            def __init__(self):
                self.name = "resource contention"
                self.summary = "rescheduled the vacuum job to 04:00"
                self.attributes = {"lesson": "reschedule overlapping jobs"}

        class _Results:
            def __init__(self):
                self.nodes = [_Node()]

        class _FakeGraphiti:
            def __init__(self):
                self.group_ids = []

            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                self.group_ids = list(group_ids)
                return _Results()

        _FakeGraphiti()
        """,
        %{}
      )

    %{pid: pid} =
      start_pool(
        construct_instance: fn _db, _shared, _group -> graph end,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      )

    assert {:ok, [node]} =
             GraphitiPool.search_nodes(pid, "group-with-hyphens", "conflict", 5,
               node_labels: ["Learning"]
             )

    {group_ids, _} = Pythonx.eval("g.group_ids", %{"g" => graph})
    GenServer.stop(pid)
    {node, %{"group_ids" => Pythonx.decode(group_ids)}}
  end
end
