defmodule Gralkor.GraphitiPoolTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Gralkor.Client
  alias Gralkor.GraphitiPool
  alias Gralkor.GraphitiPoolTest.StrictOntologyForGraphitiTest

  defp physical(logical_group_id), do: Client.sanitize_group_id(logical_group_id)

  def start_pool(opts) do
    opts = pool_opts(opts)
    {:ok, pid} = GraphitiPool.start_link(opts)
    %{pid: pid, table: Keyword.fetch!(opts, :table)}
  end

  defp pool_opts(opts) do
    defaults = [
      name: nil,
      table: :"pool_table_#{System.unique_integer([:positive])}",
      falkordb_spec: {:embedded, "/tmp/never_used"},
      construct_falkor_db: fn _spec -> :stub_falkor_db end,
      construct_shared_clients: fn _spec ->
        %{llm_client: nil, embedder: nil, cross_encoder: nil}
      end,
      construct_instance: fn _db, _shared, group_id -> {:stub_graphiti, group_id} end,
      initialise_instance: fn _instance -> :ok end,
      warmup: false,
      install_loop_fn: fn -> :ok end
    ]

    Keyword.merge(defaults, opts)
  end

  @index_listing "CALL db.indexes() YIELD label, types, stopwords RETURN label, types, stopwords"

  @search_filter_targets """
  import graphiti_core.search.search as search_module
  import graphiti_core.search.search_utils as search_utils
  import graphiti_core.utils.maintenance.node_operations as node_operations
  import graphiti_core.driver.falkordb.operations.search_ops as falkor_search_ops
  import graphiti_core.edges as edges_module
  targets = [
      (search_utils, 'node_search_filter_query_constructor'),
      (search_utils, 'edge_search_filter_query_constructor'),
      (falkor_search_ops, 'node_search_filter_query_constructor'),
      (falkor_search_ops, 'edge_search_filter_query_constructor'),
      (search_module, 'episode_fulltext_search'),
      (search_module, 'edge_similarity_search'),
      (search_module, 'node_similarity_search'),
      (node_operations, 'node_similarity_search'),
      (search_utils, 'get_entity_edge_return_query'),
      (search_utils, 'get_entity_node_return_query'),
      (edges_module.EntityEdge, 'get_by_uuids'),
      (edges_module.EntityEdge, 'load_fact_embedding'),
      (edges_module.Edge, 'delete_by_uuids'),
  ]

  def qualified(owner, name):
      prefix = owner.__name__ if isinstance(owner, type(search_utils)) else owner.__module__ + '.' + owner.__qualname__
      return prefix + '.' + name

  def current(owner, name):
      return vars(owner).get(name) if isinstance(owner, type) else getattr(owner, name, None)
  """

  defp wrapped_search_functions do
    {functions, _} =
      Pythonx.eval(
        @search_filter_targets <>
          """
          [
              [
                  qualified(module, name),
                  id(current(module, name)),
                  hasattr(getattr(module, name, None), '_gralkor_original'),
              ]
              for module, name in targets
          ]
          """,
        %{}
      )

    Pythonx.decode(functions)
  end

  defp identifier_wraps do
    Enum.filter(wrapped_search_functions(), fn [name, _id, _wrapped?] ->
      String.starts_with?(name, "graphiti_core.edges.")
    end)
  end

  defp graph_client_query do
    {wrapped, _} =
      Pythonx.eval(
        """
        import graphiti_core.search.search_utils as search_utils
        from falkordb.asyncio.graph import AsyncGraph
        {
            'id': id(AsyncGraph.query),
            'wrapped': hasattr(AsyncGraph.query, '_gralkor_original'),
            'read_timeout': getattr(search_utils, '_gralkor_read_timeout', None) is not None,
        }
        """,
        %{}
      )

    Pythonx.decode(wrapped)
  end

  # Puts graphiti's own functions back, as before any pool started, and
  # restores whatever was installed when the test exits.
  defp unwrap_search_filters do
    {saved, _} =
      Pythonx.eval(
        @search_filter_targets <>
          """
          from falkordb.asyncio.graph import AsyncGraph
          saved = (
              [(module, name, current(module, name)) for module, name in targets + [(AsyncGraph, 'query')]],
              getattr(search_utils, '_gralkor_search_filters', None),
              getattr(search_utils, '_gralkor_search_filter_originals', None),
              getattr(search_utils, '_gralkor_read_timeout', None),
          )
          for module, name, function in (saved[2] or []):
              setattr(module, name, function)
          search_utils._gralkor_search_filters = None
          saved
          """,
        %{}
      )

    on_exit(fn ->
      Pythonx.eval(
        @search_filter_targets <>
          """
          functions, installed, originals, read_timeout = saved
          for module, name, function in functions:
              setattr(module, name, function)
          search_utils._gralkor_search_filters = installed
          search_utils._gralkor_search_filter_originals = originals
          search_utils._gralkor_read_timeout = read_timeout
          None
          """,
        %{"saved" => saved}
      )
    end)

    saved
  end

  defp pinned_graphiti_core_version do
    [_, version] =
      Regex.run(
        ~r/"graphiti-core(?:\[[^\]]*\])?==([^"]+)"/,
        File.read!("priv/python/pyproject.toml")
      )

    version
  end

  # Runs graphiti's filter constructors, as wrapped by a started pool, for the
  # supplied filter keyword arguments; also runs graphiti's own unwrapped
  # constructors from `search_filters` for comparison.
  defp filter_queries(filter_kwargs, filter_class \\ "SearchFilters") do
    %{pid: pid} = start_pool([])

    {queries, _} =
      Pythonx.eval(
        @search_filter_targets <>
          """
          import graphiti_core.search.search_filters as search_filters
          from graphiti_core.driver.driver import GraphProvider
          def text(value):
              return value.decode('utf-8') if isinstance(value, (bytes, bytearray)) else value
          kwargs = {
              text(key): text(value) if isinstance(value, (bytes, bytearray)) else [text(item) for item in value]
              for key, value in filter_kwargs.items()
          }
          cls = (
              search_utils._gralkor_search_filters
              if text(filter_class) == 'WriterSearchFilters'
              else search_filters.SearchFilters
          )
          filters = cls(**kwargs)
          def run(constructor):
              queries, params = constructor(filters, GraphProvider.FALKORDB)
              return {'queries': list(queries), 'params': {key: value for key, value in params.items()}}
          {
              'node': run(search_utils.node_search_filter_query_constructor),
              'edge': run(search_utils.edge_search_filter_query_constructor),
              'falkor_node': run(falkor_search_ops.node_search_filter_query_constructor),
              'falkor_edge': run(falkor_search_ops.edge_search_filter_query_constructor),
              'own_node': run(search_filters.node_search_filter_query_constructor),
              'own_edge': run(search_filters.edge_search_filter_query_constructor),
          }
          """,
        %{"filter_kwargs" => filter_kwargs, "filter_class" => filter_class}
      )

    GenServer.stop(pid)
    Pythonx.decode(queries)
  end

  # Drives the episode full-text search a started pool installed, and
  # graphiti's own, against a driver that records the Cypher it is sent.
  defp episode_fulltext_queries(filter_kwargs) do
    %{pid: pid} = start_pool(install_loop_fn: &Gralkor.Python.install_async_runtime/0)

    {recorded, _} =
      Pythonx.eval(
        @search_filter_targets <>
          """
          import asyncio
          from graphiti_core.driver.driver import GraphProvider
          from graphiti_core.search.search_filters import SearchFilters

          class _RecordingDriver:
              provider = GraphProvider.FALKORDB
              search_interface = None

              def __init__(self):
                  self.recorded = []

              def build_fulltext_query(self, query, group_ids=None, max_query_length=128):
                  return query

              async def execute_query(self, cypher, **params):
                  self.recorded.append({'cypher': cypher, **params})
                  return ([], None, None)

          def text(value):
              return value.decode('utf-8') if isinstance(value, (bytes, bytearray)) else value
          filters = (
              SearchFilters()
              if filter_kwargs is None
              else search_utils._gralkor_search_filters(**{
                  text(key): text(value) if isinstance(value, (bytes, bytearray)) else [text(writer) for writer in value]
                  for key, value in filter_kwargs.items()
              })
          )
          wrapped = _RecordingDriver()
          own = _RecordingDriver()
          asyncio._gralkor_run(search_module.episode_fulltext_search(wrapped, 'amber notes', filters, None, 5))
          asyncio._gralkor_run(search_utils.episode_fulltext_search(own, 'amber notes', SearchFilters(), None, 5))
          {'wrapped': wrapped.recorded, 'own': own.recorded}
          """,
        %{"filter_kwargs" => filter_kwargs}
      )

    GenServer.stop(pid)
    Pythonx.decode(recorded)
  end

  defp start_raising_graph_pool(add_message \\ "graph library exploded") do
    {g, _} =
      Pythonx.eval(
        """
        class _FakeGraphiti:
            def __init__(self, add_message):
                self.add_message = add_message

            async def _write(self, message, embedding):
                raise RuntimeError(message)

            async def add_episode(self, **kwargs):
                await self._write(self.add_message, embedding=[0.123, 0.456, 0.789])

            async def remove_episode(self, uuid):
                await self._write("episode vanished", embedding=[0.123, 0.456, 0.789])

        _FakeGraphiti(add_message.decode('utf-8'))
        """,
        %{"add_message" => add_message}
      )

    start_pool(
      construct_instance: fn _db, _shared, _group_id -> g end,
      install_loop_fn: &Gralkor.Python.install_async_runtime/0
    )
  end

  defp start_provider_failing_graph_pool(kind) do
    {g, _} =
      Pythonx.eval(
        """
        import httpx
        import openai
        from google.genai.errors import ClientError
        from graphiti_core.llm_client.errors import RateLimitError

        class _FakeGraphiti:
            def __init__(self, kind):
                self.kind = kind

            async def add_episode(self, **kwargs):
                if self.kind == "rate_limit":
                    try:
                        raise openai.RateLimitError(
                            "Error code: 429 - rate limit reached",
                            response=httpx.Response(
                                429,
                                request=httpx.Request("POST", "https://api.openai.com/v1/chat/completions"),
                            ),
                            body=None,
                        )
                    except openai.RateLimitError as error:
                        raise RateLimitError from error
                try:
                    raise ClientError(
                        400,
                        {"error": {"code": 400, "message": "API key not valid", "status": "INVALID_ARGUMENT"}},
                    )
                except ClientError as error:
                    raise Exception from error

        _FakeGraphiti(kind.decode('utf-8'))
        """,
        %{"kind" => kind}
      )

    start_pool(
      construct_instance: fn _db, _shared, _group_id -> g end,
      install_loop_fn: &Gralkor.Python.install_async_runtime/0
    )
  end

  defp capture_failure_diagnostics(operation) do
    parent = self()

    log =
      capture_log(fn ->
        send(parent, {:captured_stderr, capture_io(:stderr, operation)})
      end)

    assert_received {:captured_stderr, stderr}
    String.split(stderr <> log, "\n", trim: true)
  end

  defp failing_warmup_opts do
    {g, _} =
      Pythonx.eval(
        """
        class _FakeGraphiti:
            async def search(self, query, num_results=10, search_filter=None):
                raise RuntimeError("warmup search exploded")

        _FakeGraphiti()
        """,
        %{}
      )

    [
      construct_instance: fn _db, _shared, _group_id -> g end,
      warmup: true,
      install_loop_fn: &Gralkor.Python.install_async_runtime/0
    ]
  end

  defp start_embedded_pool(data_dir, opts \\ []) do
    defaults = [
      name: nil,
      falkordb_spec: {:embedded, data_dir},
      warmup: false,
      construct_falkor_db: fn _spec -> :stub_falkor_db end,
      construct_shared_clients: fn _spec ->
        %{llm_client: nil, embedder: nil, cross_encoder: nil}
      end,
      initialise_instance: fn _instance -> :ok end
    ]

    GraphitiPool.start_link(Keyword.merge(defaults, opts))
  end

  defp await_python_value(graph, attribute, expected, attempts \\ 500)

  defp await_python_value(_graph, attribute, expected, 0) do
    flunk("expected Python graph attribute #{attribute} to become #{inspect(expected)}")
  end

  defp await_python_value(graph, attribute, expected, attempts) do
    {value, _} =
      Pythonx.eval(
        "getattr(graph, attribute.decode('utf-8') if isinstance(attribute, bytes) else attribute)",
        %{"graph" => graph, "attribute" => attribute}
      )

    if Pythonx.decode(value) == expected do
      :ok
    else
      Process.sleep(10)
      await_python_value(graph, attribute, expected, attempts - 1)
    end
  end

  defp await_episode_waiting(pid, expected, attempts \\ 500)

  defp await_episode_waiting(_pid, _expected, 0), do: flunk("expected episode write to be queued")

  defp await_episode_waiting(pid, expected, attempts) do
    state = :sys.get_state(pid)
    waiting = state.episode_write_admission.waiting |> :queue.len()

    if waiting == expected do
      :ok
    else
      Process.sleep(10)
      await_episode_waiting(pid, expected, attempts - 1)
    end
  end

  describe "if adding an episode raises inside the graph library" do
    test "then the logged diagnostic is a single concise line, so neither the full traceback nor an embedding vector is written to the log" do
      %{pid: pid} = start_raising_graph_pool()

      diagnostics =
        capture_failure_diagnostics(fn ->
          GraphitiPool.add_episode(pid, "g1", "content", "source", nil)
        end)

      assert diagnostics == ["[gralkor] add_episode failed: RuntimeError: graph library exploded"]

      GenServer.stop(pid)

      %{pid: multiline_pid} =
        start_raising_graph_pool("graph library exploded\nembedding=[0.123, 0.456, 0.789]")

      multiline_diagnostics =
        capture_failure_diagnostics(fn ->
          GraphitiPool.add_episode(multiline_pid, "g1", "content", "source", nil)
        end)

      assert multiline_diagnostics == [
               "[gralkor] add_episode failed: RuntimeError: graph library exploded"
             ]

      GenServer.stop(multiline_pid)
    end
  end

  describe "if adding an episode raises inside the graph library > while the exception is an inference provider's rate limit" do
    test "then an upstream rate-limit failure carrying the exception's class and message is returned" do
      %{pid: pid} = start_provider_failing_graph_pool("rate_limit")

      capture_io(:stderr, fn ->
        assert {:error,
                {:upstream_llm,
                 {:rate_limited, "RateLimitError: Rate limit exceeded. Please try again later."}}} =
                 GraphitiPool.add_episode(pid, "g1", "content", "source", nil)
      end)

      GenServer.stop(pid)
    end
  end

  describe "if adding an episode raises inside the graph library > while the exception is any other inference provider failure" do
    test "then an upstream provider failure carrying the exception's class and message is returned" do
      %{pid: pid} = start_provider_failing_graph_pool("provider")

      capture_io(:stderr, fn ->
        assert {:error, {:upstream_llm, {:provider, detail}}} =
                 GraphitiPool.add_episode(pid, "g1", "content", "source", nil)

        assert detail =~ "ClientError"
        assert detail =~ "API key not valid"
      end)

      GenServer.stop(pid)
    end
  end

  describe "if adding an episode raises inside the graph library > while the exception is not an inference provider failure" do
    test "then an error carrying only the raised exception's class and message is returned" do
      %{pid: pid} = start_raising_graph_pool()

      capture_io(:stderr, fn ->
        assert {:error, {:python, "RuntimeError: graph library exploded"}} =
                 GraphitiPool.add_episode(pid, "g1", "content", "source", nil)
      end)

      GenServer.stop(pid)
    end
  end

  describe "if adding an episode raises inside the graph library > while the exception is not an inference provider failure > if the raised exception carries no detail" do
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

  describe "when an episode is added > while an episode identifier is supplied > when that identifier does not exist" do
    test "then one episode is created under that identifier through the normal extraction path" do
      {g, _} =
        Pythonx.eval(
          """
          from graphiti_core.errors import NodeNotFoundError

          class _GraphOperations:
              async def episodic_node_get_by_uuid(self, cls, driver, uuid):
                  if uuid not in driver.episodes:
                      raise NodeNotFoundError(uuid)
                  return driver.episodes[uuid]

              async def episodic_node_save(self, episode, driver):
                  driver.episodes[episode.uuid] = episode

          class _Driver:
              def __init__(self):
                  self.graph_operations_interface = _GraphOperations()
                  self.episodes = {}

          class _FakeGraphiti:
              def __init__(self):
                  self.driver = _Driver()
                  self.extractions = 0

              async def add_episode(self, **kwargs):
                  from graphiti_core.nodes import EpisodicNode
                  self.extractions += 1
                  episode = await EpisodicNode.get_by_uuid(self.driver, kwargs['uuid'])
                  await episode.save(self.driver)

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
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "episode-uuid")

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "episode-uuid")

      assert {:error, {:episode_conflict, "episode-uuid"}} =
               GraphitiPool.add_episode(pid, "g1", "changed", "source", nil, uuid: "episode-uuid")

      {proof, _} =
        Pythonx.eval(
          "[len(g.driver.episodes), g.extractions, g.driver.episodes['episode-uuid'].content]",
          %{"g" => g}
        )

      assert Pythonx.decode(proof) == [1, 1, "content"]

      assert {:ok,
              %{
                "uuid" => "episode-uuid",
                "content" => "content",
                "source" => "text",
                "source_description" => "source",
                "extraction_complete" => true
              }} = GraphitiPool.get_episode(pid, "g1", "episode-uuid")

      assert {:error, :not_found} = GraphitiPool.get_episode(pid, "g1", "missing-uuid")

      GenServer.stop(pid)
    end

    test "and durable extraction completion is recorded after the normal path succeeds" do
      {pid, _g} = start_episode_identity_pool()

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "episode-uuid")

      assert {:ok, %{"extraction_complete" => true}} =
               GraphitiPool.get_episode(pid, "g1", "episode-uuid")

      GenServer.stop(pid)
    end
  end

  describe "when an episode is added > while an episode identifier is supplied > when that identifier exists with equal immutable episode content > while durable extraction completion is absent" do
    test "then the normal extraction path runs again" do
      {g, _} =
        Pythonx.eval(
          """
          from graphiti_core.errors import NodeNotFoundError

          class _GraphOperations:
              async def episodic_node_get_by_uuid(self, cls, driver, uuid):
                  if uuid not in driver.episodes:
                      raise NodeNotFoundError(uuid)
                  return driver.episodes[uuid]

              async def episodic_node_save(self, episode, driver):
                  driver.episodes[episode.uuid] = episode

          class _Driver:
              def __init__(self):
                  self.graph_operations_interface = _GraphOperations()
                  self.episodes = {}

          class _FakeGraphiti:
              def __init__(self):
                  self.driver = _Driver()
                  self.extractions = 0
                  self.completed_effects = 0

              async def add_episode(self, **kwargs):
                  from graphiti_core.nodes import EpisodicNode
                  self.extractions += 1
                  episode = await EpisodicNode.get_by_uuid(self.driver, kwargs['uuid'])
                  await episode.save(self.driver)
                  if self.extractions == 1:
                      raise RuntimeError('response failed after episode save')
                  self.completed_effects += 1

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

      assert {:error, {:python, "RuntimeError: response failed after episode save"}} =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "partial-uuid")

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil,
                 uuid: "partial-uuid",
                 source_kind: :structured_record
               )

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "partial-uuid")

      {proof, _} =
        Pythonx.eval(
          "[len(g.driver.episodes), g.extractions, g.completed_effects, 'partial-uuid' in g.driver._gralkor_completed_episode_uuids, g.driver.episodes['partial-uuid'].source.value]",
          %{"g" => g}
        )

      assert Pythonx.decode(proof) == [1, 2, 1, true, "text"]

      GenServer.stop(pid)
    end

    test "and durable extraction completion is recorded after it succeeds" do
      {pid, g} = start_episode_identity_pool()

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "episode-uuid")

      {_, _} =
        Pythonx.eval(
          "g.driver._gralkor_completed_episode_uuids.discard('episode-uuid')",
          %{"g" => g}
        )

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil,
                 uuid: "episode-uuid",
                 source_kind: :structured_record
               )

      assert {:ok, %{"extraction_complete" => true, "source" => "text"}} =
               GraphitiPool.get_episode(pid, "g1", "episode-uuid")

      GenServer.stop(pid)
    end
  end

  describe "when an episode is added > while an episode identifier is supplied > when that identifier exists with equal immutable episode content > while durable extraction completion is recorded" do
    test "then the add succeeds without invoking extraction again" do
      {pid, g} = start_episode_identity_pool()

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "episode-uuid")

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "episode-uuid")

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil,
                 uuid: "episode-uuid",
                 source_kind: :structured_record
               )

      {count, _} = Pythonx.eval("g.extractions", %{"g" => g})
      assert Pythonx.decode(count) == 1

      assert {:ok, %{"source" => "text"}} = GraphitiPool.get_episode(pid, "g1", "episode-uuid")
      GenServer.stop(pid)
    end
  end

  describe "when an episode is added > while an episode identifier is supplied > when that identifier exists with conflicting immutable episode content" do
    test "then the add returns an episode conflict and leaves the original unchanged" do
      {pid, _g} = start_episode_identity_pool()

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "episode-uuid")

      assert {:error, {:episode_conflict, "episode-uuid"}} =
               GraphitiPool.add_episode(pid, "g1", "changed", "source", nil, uuid: "episode-uuid")

      assert {:ok, %{"content" => "content"}} =
               GraphitiPool.get_episode(pid, "g1", "episode-uuid")

      GenServer.stop(pid)
    end
  end

  describe "when an episode is added > while an episode identifier is supplied" do
    test "then concurrent writes carrying the same identifier are serialised even when other remote writes remain concurrent" do
      {g, _} =
        Pythonx.eval(
          """
          import asyncio
          from graphiti_core.errors import NodeNotFoundError

          class _GraphOperations:
              async def episodic_node_get_by_uuid(self, cls, driver, uuid):
                  if uuid not in driver.episodes:
                      raise NodeNotFoundError(uuid)
                  return driver.episodes[uuid]

              async def episodic_node_save(self, episode, driver):
                  driver.episodes[episode.uuid] = episode

          class _Driver:
              def __init__(self):
                  self.graph_operations_interface = _GraphOperations()
                  self.episodes = {}

          class _FakeGraphiti:
              def __init__(self):
                  self.driver = _Driver()
                  self.extractions = {}
                  self.active = 0
                  self.max_active = 0
                  self.active_by_uuid = {}
                  self.max_active_by_uuid = {}

              async def add_episode(self, **kwargs):
                  from graphiti_core.nodes import EpisodicNode
                  uid = kwargs['uuid']
                  self.extractions[uid] = self.extractions.get(uid, 0) + 1
                  self.active += 1
                  self.max_active = max(self.max_active, self.active)
                  self.active_by_uuid[uid] = self.active_by_uuid.get(uid, 0) + 1
                  self.max_active_by_uuid[uid] = max(
                      self.max_active_by_uuid.get(uid, 0), self.active_by_uuid[uid]
                  )
                  for _ in range(200):
                      if self.active >= 2:
                          break
                      await asyncio.sleep(0.01)
                  await asyncio.sleep(0.1)
                  episode = await EpisodicNode.get_by_uuid(self.driver, uid)
                  await episode.save(self.driver)
                  self.active_by_uuid[uid] -= 1
                  self.active -= 1

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          falkordb_spec: {:remote, host: "h", port: 1},
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      writes =
        Enum.map(["shared-uuid", "shared-uuid", "other-uuid"], fn uuid ->
          Task.async(fn ->
            GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: uuid)
          end)
        end)

      assert [:ok, :ok, :ok] = Task.await_many(writes)

      {proof, _} =
        Pythonx.eval(
          "[len(g.driver.episodes), g.extractions, g.max_active_by_uuid, g.max_active]",
          %{"g" => g}
        )

      assert Pythonx.decode(proof) == [
               2,
               %{"shared-uuid" => 1, "other-uuid" => 1},
               %{"shared-uuid" => 1, "other-uuid" => 1},
               2
             ]

      GenServer.stop(pid)
      assert_independent_pool_admission()
    end

    test "and writers are recorded only after durable extraction completion is recorded under the current claim" do
      %{pid: pid, g: g} = start_writer_recording_pool()

      plan_extraction(g, ["kept-entity"], [])

      assert :ok =
               GraphitiPool.add_episode(pid, "writers", "kept", "notes", nil,
                 lens: "alpha",
                 uuid: "kept-episode"
               )

      assert {:ok, %{"extraction_complete" => true}} =
               GraphitiPool.get_episode(pid, "writers", "kept-episode")

      plan_extraction(g, ["stolen-entity"], [], steal_claim: true)

      capture_io(:stderr, fn ->
        assert {:error, {:python, message}} =
                 GraphitiPool.add_episode(pid, "writers", "stolen", "notes", nil,
                   lens: "alpha",
                   uuid: "stolen-episode"
                 )

        assert message =~ "episode claim lost before completion"
      end)

      assert {:ok, %{"extraction_complete" => false}} =
               GraphitiPool.get_episode(pid, "writers", "stolen-episode")

      assert recorded_writers(
               g,
               "MATCH (e:Episodic) RETURN e.uuid AS key, e._gralkor_writers AS writers"
             ) ==
               %{"kept-episode" => ["lens:alpha"], "stolen-episode" => nil}

      assert recorded_writers(
               g,
               "MATCH (n:Entity) RETURN n.uuid AS key, n._gralkor_writers AS writers"
             ) ==
               %{"kept-entity" => ["lens:alpha"], "stolen-entity" => nil}
    end
  end

  defp assert_independent_pool_admission do
    {graphs, _} =
      Pythonx.eval(
        """
        import asyncio
        from graphiti_core.errors import NodeNotFoundError

        class _GraphOperations:
            async def episodic_node_get_by_uuid(self, cls, driver, uuid):
                if uuid not in driver.episodes:
                    raise NodeNotFoundError(uuid)
                return driver.episodes[uuid]

            async def episodic_node_save(self, episode, driver):
                driver.episodes[episode.uuid] = episode
                if episode.uuid in driver.steal_after_save:
                    claim = driver.claims[episode.uuid]
                    claim['owner'] = 'replacement-after-save'
                    claim['generation'] += 1

        class _Driver:
            def __init__(self):
                self.graph_operations_interface = _GraphOperations()
                self.episodes = {}
                self.claims = {}
                self.completed = set()
                self.lock = asyncio.Lock()
                self.server_time_ms = 1_000_000
                self.steal_after_save = set()
                self.reject_renewals = set()
                self.query_calls = []
                self.stolen_extraction_started = asyncio.Event()
                self.continue_stolen_extraction = asyncio.Event()

            async def execute_query(self, query, **params):
                async with self.lock:
                    self.query_calls.append({'query': query, 'params': dict(params)})
                    if 'MERGE (c:_GralkorEpisodeClaim' in query:
                        claim = self.claims.setdefault(params['uuid'], {
                            'group_id': params['group_id'],
                            'content': params['content'],
                            'source': params['source'],
                            'source_description': params['source_description'],
                            'owner': params['owner'],
                            'generation': 1,
                            'lease_until_ms': self.server_time_ms + params['lease_ms'],
                        })
                        return [dict(claim)], None, None
                    if 'WHERE c.owner IS NULL' in query:
                        claim = self.claims[params['uuid']]
                        self.server_time_ms += 1
                        if (
                            claim['owner'] is None
                            or claim['owner'] == params['owner']
                            or claim['lease_until_ms'] <= self.server_time_ms
                        ):
                            claim['owner'] = params['owner']
                            claim['generation'] += 1
                            claim['lease_until_ms'] = self.server_time_ms + params['lease_ms']
                            return [{
                                'owner': params['owner'],
                                'generation': claim['generation'],
                            }], None, None
                        return [], None, None
                    if 'SET c.owner = NULL' in query:
                        claim = self.claims[params['uuid']]
                        if (
                            claim['owner'] == params['owner']
                            and claim['generation'] == params['generation']
                        ):
                            claim['owner'] = None
                            claim['lease_until_ms'] = 0
                        return [{'uuid': params['uuid']}], None, None
                    if 'SET c.lease_until_ms' in query:
                        claim = self.claims[params['uuid']]
                        if params['uuid'] in self.reject_renewals:
                            return [], None, None
                        if (
                            claim['owner'] == params['owner']
                            and claim['generation'] == params['generation']
                        ):
                            claim['lease_until_ms'] = self.server_time_ms + params['lease_ms']
                            return [{'generation': claim['generation']}], None, None
                        return [], None, None
                    if '_gralkor_extraction_complete = true' in query:
                        claim = self.claims[params['uuid']]
                        if (
                            claim['owner'] == params['owner']
                            and claim['generation'] == params['generation']
                            and params['uuid'] in self.episodes
                        ):
                            self.completed.add(params['uuid'])
                            return [{'uuid': params['uuid']}], None, None
                        return [], None, None
                    if 'coalesce(e._gralkor_extraction_complete' in query:
                        return [
                            {'complete': params['uuid'] in self.completed}
                        ], None, None
                    if 'gralkor_claim_fence_check' in query:
                        claim = self.claims[params['claim_uuid']]
                        if (
                            claim['owner'] == params['owner']
                            and claim['generation'] == params['generation']
                        ):
                            return [{'generation': claim['generation']}], None, None
                        return [], None, None
                    return [], None, None

        class _FakeGraphiti:
            def __init__(self, driver):
                self.driver = driver
                self.extractions = 0

            async def add_episode(self, **kwargs):
                from graphiti_core.nodes import EpisodicNode
                self.extractions += 1
                if kwargs['uuid'] == 'stolen-claim' and not self.driver.stolen_extraction_started.is_set():
                    self.driver.stolen_extraction_started.set()
                    await self.driver.continue_stolen_extraction.wait()
                else:
                    await asyncio.sleep(0.05)
                episode = await EpisodicNode.get_by_uuid(self.driver, kwargs['uuid'])
                await episode.save(self.driver)

        driver = _Driver()
        [_FakeGraphiti(driver), _FakeGraphiti(driver)]
        """,
        %{}
      )

    {first_graph, _} = Pythonx.eval("graphs[0]", %{"graphs" => graphs})
    {second_graph, _} = Pythonx.eval("graphs[1]", %{"graphs" => graphs})

    %{pid: first_pool} =
      start_pool(
        construct_instance: fn _db, _shared, _group_id -> first_graph end,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      )

    %{pid: second_pool} =
      start_pool(
        construct_instance: fn _db, _shared, _group_id -> second_graph end,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      )

    equal_writes = [
      Task.async(fn ->
        GraphitiPool.add_episode(first_pool, "g1", "same", "source", nil, uuid: "shared-equal")
      end),
      Task.async(fn ->
        GraphitiPool.add_episode(second_pool, "g1", "same", "source", nil, uuid: "shared-equal")
      end)
    ]

    assert [:ok, :ok] = Task.await_many(equal_writes)

    conflicting_writes = [
      Task.async(fn ->
        GraphitiPool.add_episode(first_pool, "g1", "first", "source", nil,
          uuid: "shared-conflict"
        )
      end),
      Task.async(fn ->
        GraphitiPool.add_episode(second_pool, "g1", "second", "source", nil,
          uuid: "shared-conflict"
        )
      end)
    ]

    outcomes = Task.await_many(conflicting_writes)
    assert Enum.count(outcomes, &(&1 == :ok)) == 1

    assert Enum.count(
             outcomes,
             &(&1 == {:error, {:episode_conflict, "shared-conflict"}})
           ) == 1

    {proof, _} =
      Pythonx.eval(
        "[sum(g.extractions for g in graphs), len(graphs[0].driver.episodes)]",
        %{"graphs" => graphs}
      )

    assert Pythonx.decode(proof) == [2, 2]

    stale_write =
      Task.async(fn ->
        GraphitiPool.add_episode(first_pool, "g1", "same", "source", nil, uuid: "stolen-claim")
      end)

    assert eventually(fn ->
             {present, _} =
               Pythonx.eval("graphs[0].driver.stolen_extraction_started.is_set()", %{
                 "graphs" => graphs
               })

             Pythonx.decode(present)
           end)

    Pythonx.eval(
      """
      import asyncio
      claim = graphs[0].driver.claims['stolen-claim']
      claim['owner'] = 'replacement-owner'
      claim['generation'] += 1
      asyncio._gralkor_loop.call_soon_threadsafe(graphs[0].driver.continue_stolen_extraction.set)
      """,
      %{"graphs" => graphs}
    )

    assert {:error, {:python, stale_error}} = Task.await(stale_write)
    assert stale_error =~ "episode claim lost"

    {stale_proof, _} =
      Pythonx.eval(
        "['stolen-claim' in graphs[0].driver.episodes, 'stolen-claim' in graphs[0].driver.completed]",
        %{"graphs" => graphs}
      )

    assert Pythonx.decode(stale_proof) == [false, false]

    Pythonx.eval(
      """
      claim = graphs[0].driver.claims['stolen-claim']
      claim['owner'] = None
      claim['lease_until_ms'] = 0
      """,
      %{"graphs" => graphs}
    )

    assert :ok =
             GraphitiPool.add_episode(second_pool, "g1", "same", "source", nil,
               uuid: "stolen-claim"
             )

    {recovered_proof, _} =
      Pythonx.eval(
        "['stolen-claim' in graphs[0].driver.episodes, 'stolen-claim' in graphs[0].driver.completed, graphs[0].driver.claims['stolen-claim']['generation']]",
        %{"graphs" => graphs}
      )

    assert Pythonx.decode(recovered_proof) == [true, true, 3]

    Pythonx.eval(
      "graphs[0].driver.steal_after_save.add('marker-stolen')",
      %{"graphs" => graphs}
    )

    assert {:error, {:python, marker_error}} =
             GraphitiPool.add_episode(first_pool, "g1", "same", "source", nil,
               uuid: "marker-stolen"
             )

    assert marker_error =~ "episode claim lost before completion"

    {marker_proof, _} =
      Pythonx.eval(
        "['marker-stolen' in graphs[0].driver.episodes, 'marker-stolen' in graphs[0].driver.completed]",
        %{"graphs" => graphs}
      )

    assert Pythonx.decode(marker_proof) == [true, false]

    Pythonx.eval(
      """
      graphs[0].driver.steal_after_save.remove('marker-stolen')
      claim = graphs[0].driver.claims['marker-stolen']
      claim['owner'] = None
      claim['lease_until_ms'] = 0
      """,
      %{"graphs" => graphs}
    )

    assert :ok =
             GraphitiPool.add_episode(second_pool, "g1", "same", "source", nil,
               uuid: "marker-stolen"
             )

    {marker_recovery, _} =
      Pythonx.eval(
        "['marker-stolen' in graphs[0].driver.completed, graphs[0].driver.claims['marker-stolen']['generation']]",
        %{"graphs" => graphs}
      )

    assert Pythonx.decode(marker_recovery) == [true, 3]

    Pythonx.eval(
      """
      template = dict(graphs[0].driver.claims['shared-equal'])
      template['owner'] = 'expired-owner'
      template['generation'] = 7
      template['lease_until_ms'] = graphs[0].driver.server_time_ms - 1
      graphs[0].driver.claims['server-expired'] = template
      """,
      %{"graphs" => graphs}
    )

    assert :ok =
             GraphitiPool.add_episode(first_pool, "g1", "same", "source", nil,
               uuid: "server-expired"
             )

    {clock_proof, _} =
      Pythonx.eval(
        """
        driver = graphs[0].driver
        lease_calls = [
            call for call in driver.query_calls
            if '$lease_ms' in call['query']
        ]
        [
            driver.claims['server-expired']['generation'],
            all('timestamp()' in call['query'] for call in lease_calls),
            all('now_ms' not in call['params'] and 'lease_until_ms' not in call['params'] for call in lease_calls),
        ]
        """,
        %{"graphs" => graphs}
      )

    assert Pythonx.decode(clock_proof) == [8, true, true]

    Pythonx.eval(
      """
      graphs[0]._gralkor_claim_lease_ms = 30
      graphs[0].driver.reject_renewals.add('renewal-lost')
      """,
      %{"graphs" => graphs}
    )

    assert {:error, {:python, renewal_error}} =
             GraphitiPool.add_episode(first_pool, "g1", "same", "source", nil,
               uuid: "renewal-lost"
             )

    assert renewal_error =~ "episode claim renewal lost"

    Pythonx.eval(
      "graphs[0].driver.reject_renewals.remove('renewal-lost')",
      %{"graphs" => graphs}
    )

    assert :ok =
             GraphitiPool.add_episode(second_pool, "g1", "same", "source", nil,
               uuid: "renewal-lost"
             )

    {renewal_proof, _} =
      Pythonx.eval(
        "['renewal-lost' in graphs[0].driver.completed, sum(g.extractions for g in graphs)]",
        %{"graphs" => graphs}
      )

    assert Pythonx.decode(renewal_proof) == [true, 8]
    GenServer.stop(first_pool)
    GenServer.stop(second_pool)
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

    test "and the episode records its one writer: its Lens, the Reflection its source description names, direct, or `unknown`" do
      %{pid: pid, g: g} = start_writer_recording_pool()

      assert :ok =
               GraphitiPool.add_episode(pid, "writers", "lens memory", "notes", nil,
                 lens: "alpha"
               )

      assert :ok =
               GraphitiPool.add_episode(
                 pid,
                 "writers",
                 "reflection memory",
                 "reflection:review",
                 nil
               )

      assert :ok =
               GraphitiPool.add_episode(pid, "writers", "direct memory", "manual", nil,
                 writer: :direct
               )

      assert :ok =
               GraphitiPool.add_episode(pid, "writers", "unattributed memory", "old notes", nil)

      assert recorded_writers(
               g,
               "MATCH (e:Episodic) RETURN e.content AS key, e._gralkor_writers AS writers"
             ) ==
               %{
                 "lens memory" => ["lens:alpha"],
                 "reflection memory" => ["reflection:review"],
                 "direct memory" => ["direct"],
                 "unattributed memory" => ["unknown"]
               }
    end

    test "and every fact and entity the write touched records the writers of every episode it was drawn from or that mentions it, keeping writers recorded earlier" do
      %{pid: pid, g: g} = start_writer_recording_pool()

      plan_extraction(g, ["lesson", "project"], [["learns", "lesson", "project"]])
      assert :ok = GraphitiPool.add_episode(pid, "writers", "first", "notes", nil, lens: "alpha")
      plan_extraction(g, ["lesson"], [["learns", "lesson", "project"]])

      assert :ok =
               GraphitiPool.add_episode(pid, "writers", "second", "manual", nil, writer: :direct)

      plan_extraction(g, ["lesson"], [])
      assert :ok = GraphitiPool.add_episode(pid, "writers", "third", "notes", nil, lens: "alpha")

      assert recorded_writers(
               g,
               "MATCH ()-[e:RELATES_TO]->() RETURN e.uuid AS key, e._gralkor_writers AS writers"
             ) == %{"learns" => ["lens:alpha", "direct"]}

      assert recorded_writers(
               g,
               "MATCH (n:Entity) RETURN n.uuid AS key, n._gralkor_writers AS writers"
             ) ==
               %{"lesson" => ["lens:alpha", "direct"], "project" => ["lens:alpha"]}
    end

    test "and no query the write sends carries a query timeout" do
      %{pid: pid, g: g} = start_writer_recording_pool()
      plan_extraction(g, ["lesson", "project"], [["learns", "lesson", "project"]])
      spy = spy_query_timeouts()

      assert :ok = GraphitiPool.add_episode(pid, "writers", "first", "notes", nil, lens: "alpha")

      timeouts = spied_timeouts(spy)
      assert length(timeouts) >= 3
      assert Enum.uniq(timeouts) == [nil]
    end
  end

  describe "when one episode is requested by exact identifier" do
    test "then the matching episode content and immutable source fields are returned" do
      {pid, _g} = start_episode_identity_pool()

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "episode-uuid")

      assert {:ok,
              %{
                "uuid" => "episode-uuid",
                "content" => "content",
                "source" => "text",
                "source_description" => "source"
              }} = GraphitiPool.get_episode(pid, "g1", "episode-uuid")

      GenServer.stop(pid)
    end

    test "and the result identifies whether durable extraction completion is recorded" do
      {pid, _g} = start_episode_identity_pool()

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "episode-uuid")

      assert {:ok, %{"extraction_complete" => true}} =
               GraphitiPool.get_episode(pid, "g1", "episode-uuid")

      GenServer.stop(pid)
    end
  end

  describe "when one episode is requested by exact identifier > while that identifier is absent" do
    test "then lookup reports not found" do
      {pid, _g} = start_episode_identity_pool()
      assert {:error, :not_found} = GraphitiPool.get_episode(pid, "g1", "missing-uuid")
      GenServer.stop(pid)
    end
  end

  describe "when an episode is added > while an embedded connection is configured > while another episode addition is in progress" do
    test "then the graph library receives the episode only after the in-progress addition finishes" do
      {g, _} =
        Pythonx.eval(
          """
          import asyncio

          class _FakeGraphiti:
              def __init__(self):
                  self.events = []
                  self.active_writes = 0
                  self.first_started = False
                  self.release_first = asyncio.Event()

              async def add_episode(self, **kwargs):
                  body = kwargs['episode_body']
                  self.active_writes += 1
                  self.events.append(f'start:{body}')
                  if body == 'first':
                      self.first_started = True
                      await self.release_first.wait()
                  self.events.append(f'finish:{body}')
                  self.active_writes -= 1

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

      GraphitiPool.for(pid, "g1")

      try do
        first = Task.async(fn -> GraphitiPool.add_episode(pid, "g1", "first", "manual", nil) end)
        await_python_value(g, "first_started", true)

        second =
          Task.async(fn -> GraphitiPool.add_episode(pid, "g1", "second", "manual", nil) end)

        await_episode_waiting(pid, 1)

        Pythonx.eval(
          "import asyncio; asyncio._gralkor_loop.call_soon_threadsafe(g.release_first.set)",
          %{"g" => g}
        )

        assert Task.await(first, 5_000) == :ok
        assert Task.await(second, 5_000) == :ok

        {events, _} = Pythonx.eval("g.events", %{"g" => g})

        assert Pythonx.decode(events) == [
                 "start:first",
                 "finish:first",
                 "start:second",
                 "finish:second"
               ]
      after
        Pythonx.eval(
          "import asyncio; asyncio._gralkor_loop.call_soon_threadsafe(g.release_first.set)",
          %{"g" => g}
        )

        if Process.alive?(pid), do: GenServer.stop(pid)
      end
    end
  end

  describe "when an episode is added > while an embedded connection is configured > while another episode addition is in progress > if the in-progress addition's caller exits" do
    test "then the next waiting addition proceeds" do
      {g, _} =
        Pythonx.eval(
          """
          import asyncio

          class _FakeGraphiti:
              def __init__(self):
                  self.events = []
                  self.first_started = False
                  self.release_first = asyncio.Event()

              async def add_episode(self, **kwargs):
                  body = kwargs['episode_body']
                  self.events.append(f'start:{body}')
                  if body == 'first':
                      self.first_started = True
                      await self.release_first.wait()
                  self.events.append(f'finish:{body}')

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, _group_id -> g end,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      GraphitiPool.for(pid, "g1")

      try do
        first_caller =
          spawn(fn -> GraphitiPool.add_episode(pid, "g1", "first", "manual", nil) end)

        await_python_value(g, "first_started", true)

        second =
          Task.async(fn -> GraphitiPool.add_episode(pid, "g1", "second", "manual", nil) end)

        await_episode_waiting(pid, 1)
        Process.exit(first_caller, :kill)

        assert Task.await(second, 5_000) == :ok

        {events, _} = Pythonx.eval("g.events", %{"g" => g})
        assert Pythonx.decode(events) == ["start:first", "start:second", "finish:second"]
      after
        Pythonx.eval(
          "import asyncio; asyncio._gralkor_loop.call_soon_threadsafe(g.release_first.set)",
          %{"g" => g}
        )

        if Process.alive?(pid), do: GenServer.stop(pid)
      end
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
               "custom_extraction_instructions",
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

  describe "when an episode is added > where a supported source kind is supplied" do
    test "then conversation, document, and structured-record sources reach the graph library as message, text, and JSON episodes respectively" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              def __init__(self):
                  self.sources = []

              async def add_episode(self, **kwargs):
                  self.sources.append(kwargs['source'].value)

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
               GraphitiPool.add_episode(pid, "g1", "conversation", "chat", nil,
                 source_kind: :conversation
               )

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "document", "notes", nil,
                 source_kind: :document
               )

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", ~s({"status":"ok"}), "record", nil,
                 source_kind: :structured_record
               )

      {sources, _} = Pythonx.eval("g.sources", %{"g" => g})
      assert Pythonx.decode(sources) == ["message", "text", "json"]

      GenServer.stop(pid)
    end

    test "and the existing episode extraction is instructed to preserve source attribution and epistemic wording" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              def __init__(self):
                  self.calls = []

              async def add_episode(self, **kwargs):
                  self.calls.append(kwargs)

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
               GraphitiPool.add_episode(pid, "g1", "Eli may prefer tea.", "chat", nil,
                 source_kind: :conversation
               )

      {instructions, _} =
        Pythonx.eval("g.calls[0]['custom_extraction_instructions']", %{"g" => g})

      instructions = Pythonx.decode(instructions)
      assert instructions =~ "source attribution"
      assert instructions =~ "uncertainty"

      GenServer.stop(pid)
    end

    test "and no separate presentation-classification operation is invoked" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              def __init__(self):
                  self.add_count = 0

              async def add_episode(self, **kwargs):
                  self.add_count += 1

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
               GraphitiPool.add_episode(pid, "g1", "Eli may prefer tea.", "chat", nil,
                 source_kind: :conversation
               )

      {add_count, _} = Pythonx.eval("g.add_count", %{"g" => g})
      assert Pythonx.decode(add_count) == 1

      GenServer.stop(pid)
    end
  end

  defmodule OntologyForwardingTest do
    use ExUnit.Case, async: false

    @moduletag :integration

    alias Gralkor.GraphitiPool

    describe "when an episode is added > while an ontology module is supplied" do
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
                 "custom_extraction_instructions",
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
      %{pid: pid} = start_raising_graph_pool()

      diagnostics =
        capture_failure_diagnostics(fn ->
          GraphitiPool.remove_episode(pid, "g1", "episode-uuid-123")
        end)

      assert diagnostics == [
               "[gralkor] remove_episode failed: RuntimeError: episode vanished"
             ]

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
                  self.episodes = []

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def search(self, query, num_results=10, search_filter=None):
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
      assert_fact_timestamps()
    end

    test "and each returned edge identifies its originating episodes by identifier, source kind, and source description" do
      assert_fact_sources()
    end

    test "and each returned edge is rendered with its relationship name and the name and identifier of its source and target entities" do
      {g, _} =
        Pythonx.eval(
          """
          from types import SimpleNamespace

          class _EntityDriver:
              async def execute_query(self, query, **params):
                  names = {"commit-1": "Commit 1", "parse-fn": "parse/1"}
                  return ([{"uuid": uuid, "name": names[uuid]} for uuid in params["uuids"]], None, None)

          class _FakeGraphiti:
              def __init__(self):
                  self.driver = _EntityDriver()

              async def search(self, query, num_results=10, search_filter=None):
                  return [SimpleNamespace(
                      fact="commit-1 changes parse",
                      name="CHANGES",
                      source_node_uuid="commit-1",
                      target_node_uuid="parse-fn",
                      created_at=None,
                      valid_at=None,
                      invalid_at=None,
                      expired_at=None,
                      episodes=[],
                  )]

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

      assert {:ok, [fact]} = GraphitiPool.search(pid, "g1", "parse", 5)
      assert fact.relationship == "CHANGES"
      assert fact.source_node == %{uuid: "commit-1", name: "Commit 1"}
      assert fact.target_node == %{uuid: "parse-fn", name: "parse/1"}

      GenServer.stop(pid)
    end

    test "and a standalone custom-entity node cannot be returned, because edge search matches edges by their endpoints" do
      assert_fact_excludes_standalone_node()
    end

    test "and every query the search sends carries a FalkorDB query timeout below the socket timeout" do
      %{pid: pid} = start_real_searching_pool(%{})
      spy = spy_query_timeouts()

      assert {:ok, [%{fact: "amber owns other", sources: [_]}]} =
               GraphitiPool.search(pid, "searching", "amber", 5)

      timeouts = spied_timeouts(spy)
      assert length(timeouts) >= 3
      assert Enum.uniq(timeouts) == [3_600]
    end
  end

  describe "when a fact search is run for a group > where edge types are supplied" do
    test "then the graph library's edge search is restricted to those ontology relationship types" do
      {g, _} =
        Pythonx.eval(
          """
          import asyncio

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def search(self, query, num_results=10, search_filter=None):
                  self.recorded['edge_types'] = (
                      list(search_filter.edge_types)
                      if search_filter is not None and search_filter.edge_types
                      else None
                  )
                  return []

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

      assert {:ok, []} =
               GraphitiPool.search(pid, "g1", "q", 5, edge_types: ["LEARNS_FROM"])

      {recorded, _} = Pythonx.eval("g.recorded", %{"g" => g})
      assert (recorded |> Pythonx.decode())["edge_types"] == ["LEARNS_FROM"]

      GenServer.stop(pid)
    end
  end

  defp assert_fact_timestamps do
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
                self.episodes = []

        class _FakeGraphiti:
            async def search(self, query, num_results=10, search_filter=None):
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

  defp assert_fact_sources do
    {g, _} =
      Pythonx.eval(
        """
        from graphiti_core.nodes import EpisodeType

        class _Episode:
            def __init__(self, uuid, source, source_description):
                self.uuid = uuid
                self.source = source
                self.source_description = source_description

        class _GraphOperations:
            async def episodic_node_get_by_uuids(self, cls, driver, uuids):
                return [driver.episodes[uuid] for uuid in uuids]

        class _Driver:
            def __init__(self):
                self.graph_operations_interface = _GraphOperations()
                self.episodes = {
                    "episode-1": _Episode(
                        "episode-1",
                        EpisodeType.message,
                        "conversation with Eli",
                    ),
                    "episode-2": _Episode(
                        "episode-2",
                        EpisodeType.text,
                        "project notes",
                    ),
                }

        class _Edge:
            def __init__(self):
                self.fact = "Eli may prefer tea"
                self.created_at = None
                self.valid_at = None
                self.invalid_at = None
                self.expired_at = None
                self.episodes = ["episode-1", "episode-2"]

        class _FakeGraphiti:
            def __init__(self):
                self.driver = _Driver()

            async def search(self, query, num_results=10, search_filter=None):
                return [_Edge()]

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

    assert {:ok,
            [
              %{
                fact: "Eli may prefer tea",
                sources: [
                  %{
                    id: "episode-1",
                    source_kind: "conversation",
                    source_description: "conversation with Eli"
                  },
                  %{
                    id: "episode-2",
                    source_kind: "document",
                    source_description: "project notes"
                  }
                ]
              }
            ]} = GraphitiPool.search(pid, "g1", "tea", 5)

    GenServer.stop(pid)
  end

  defp assert_fact_excludes_standalone_node do
    assert {:ok, [%{fact: "X is a thing"} = fact]} = fact_search_result()
    refute Map.has_key?(fact, :name)
  end

  describe "if running a fact search raises inside the graph library" do
    test "then an error carrying the raised exception is returned" do
      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              async def search(self, query, num_results=10, search_filter=None):
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

  describe "when a graph instance's indexes are built on FalkorDB" do
    setup :start_real_embedded_pool

    test "then its full-text indexes carry no stopword list", %{pid: pid} do
      instance = GraphitiPool.for(pid, "fresh")

      fulltext =
        instance
        |> graph_indexes()
        |> Enum.filter(fn index -> Enum.any?(Map.values(index["types"]), &("FULLTEXT" in &1)) end)

      assert Enum.sort(Enum.map(fulltext, & &1["label"])) ==
               ["Community", "Entity", "Episodic", "RELATES_TO"]

      assert Enum.all?(fulltext, &(&1["stopwords"] == []))
    end

    test "and an exact-match lookup for an indexed value that is a stopword returns its match instead of crashing FalkorDB",
         %{pid: pid} do
      instance = GraphitiPool.for(pid, "fresh")
      graph_query(instance, "CREATE (:Episodic {uuid: 'the'})")

      assert graph_query(
               instance,
               "MATCH (e:Episodic) WHERE e.uuid IN ['the'] RETURN e.uuid AS uuid"
             ) ==
               [%{"uuid" => "the"}]
    end

    test "and the graph has a vector index over fact embeddings and one over entity name embeddings, each comparing by cosine at the dimension the embedder produces",
         %{pid: pid} do
      instance = GraphitiPool.for(pid, "fresh")
      dimension = embedder_dimension(instance)

      assert vector_index_options(instance) == %{
               "RELATES_TO.fact_embedding" => {"cosine", dimension},
               "Entity.name_embedding" => {"cosine", dimension}
             }
    end

    test "and the vector indexes are created after any stopword replacement and after writers are recorded",
         %{pid: pid} do
      sent = rebuilt_queries(pid, "fresh")
      creates = Enum.filter(sent, &(&1 =~ "CREATE VECTOR INDEX"))

      assert [fact, entity] = creates
      assert fact =~ "RELATES_TO"
      assert entity =~ "Entity"

      first_create = Enum.find_index(sent, &(&1 =~ "CREATE VECTOR INDEX"))

      assert Enum.find_index(sent, &(&1 =~ "CREATE FULLTEXT INDEX")) < first_create
      assert Enum.find_index(sent, &(&1 =~ "CREATE INDEX")) < first_create

      last_backfill =
        sent
        |> Enum.with_index()
        |> Enum.filter(fn {cypher, _} -> cypher =~ "_gralkor_writers" end)
        |> List.last()
        |> elem(1)

      assert last_backfill < first_create
    end

    test "and index building returns without waiting for FalkorDB to finish building them", %{
      pid: pid
    } do
      sent = rebuilt_queries(pid, "fresh")

      assert List.last(sent) =~ "CREATE VECTOR INDEX FOR (n:Entity)"
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > while the graph has no vector index over fact or entity embeddings" do
    setup :start_real_embedded_pool

    test "then the missing vector indexes are created", %{pid: pid} do
      instance = GraphitiPool.for(pid, "fresh")

      assert Map.keys(vector_index_options(instance)) |> Enum.sort() ==
               ["Entity.name_embedding", "RELATES_TO.fact_embedding"]
    end

    test "and their creation is logged naming the graph, each index created, and its dimension",
         %{
           pid: pid
         } do
      log = capture_log(fn -> GraphitiPool.for(pid, "fresh") end)

      assert log =~
               "[gralkor] vector indexes created — graph: #{physical("fresh")} " <>
                 "indexes: RELATES_TO.fact_embedding, Entity.name_embedding dimension: 3"
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > while both vector indexes already exist, built or still being built" do
    setup :start_real_embedded_pool

    test "then neither is created again", context do
      assert_no_vector_index_created_again(context)
    end

    test "and nothing is logged about them", %{pid: pid} do
      GraphitiPool.for(pid, "fresh")
      log = capture_log(fn -> assert {:ok, _} = GraphitiPool.build_indices(pid) end)

      refute log =~ "vector indexes created"
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > if an existing vector index compares at another dimension than the embedder produces, or by another similarity than cosine" do
    setup :start_real_embedded_pool

    test "then it is left unchanged", %{pid: pid} do
      instance = mismatched_build(pid)

      assert vector_index_options(instance)["RELATES_TO.fact_embedding"] == {"cosine", 4}
    end

    test "and a vector index the graph lacks is still created", %{pid: pid} do
      instance = mismatched_build(pid)

      assert vector_index_options(instance)["Entity.name_embedding"] == {"cosine", 3}
    end

    test "and index building fails, naming the graph, the index, its dimension and similarity, the embedder's dimension, and how to replace it",
         context do
      assert_index_building_fails_naming_graph_index_dimension_similarity(context)
    end

    test "and index building is not tried again", %{pid: pid} do
      substitute_index_building_retry_sleep()
      instance = GraphitiPool.for(pid, "fresh")
      drop_vector_indexes(instance)

      graph_query(
        instance,
        "CREATE VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding) OPTIONS {dimension: 4, similarityFunction: 'cosine'}"
      )

      recording = fail_queries("fresh", "CREATE VECTOR INDEX", 0, "connection lost")

      assert {:error, {:vector_indexes, _}} = GraphitiPool.build_indices(pid)

      assert vector_index_queries(sent_by(recording)) == [
               "status RELATES_TO",
               "status Entity",
               "create Entity"
             ]

      assert index_building_retry_waits() == []
    end

    test "and any stopword replacement and writer recording done before it are still logged",
         context do
      assert_replacement_and_recording_logged_beside_mismatch(context)
    end

    test "and every other graph's indexes are still built", context do
      assert_other_graphs_built_beside_mismatch(context)
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > if an existing vector index compares at another dimension than the embedder produces, or by another similarity than cosine > if a query for the graph's other vector index fails in the same try" do
    setup [:start_real_embedded_pool, :substitute_index_building_retry_sleep]

    test "then index building is still not tried again", context do
      assert_building_not_tried_again_beside_mismatch_and_failure(context)
    end

    test "and index building fails naming the mismatched index and that failure", context do
      assert_index_building_fails_naming_mismatch_and_failure(context)
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > if any query of index building fails, times out, loses its connection, or is answered that FalkorDB is loading" do
    setup [:start_real_embedded_pool, :substitute_index_building_retry_sleep]

    test "then index building is tried again after a set wait, up to a set number of times",
         context do
      assert_building_tried_again_after_set_wait_up_to_set_number_of_times(context)
    end

    test "and tries that fail at different steps count against the same limit", context do
      assert_tries_failing_at_different_steps_share_limit(context)
    end

    test "and a later try runs the graph library's own index building, the stopword replacement, and the writer recording again",
         context do
      assert_later_try_runs_every_step_again(context)
    end

    test "and the stopword replacement and writer recording that each try did are logged",
         context do
      assert_replacement_and_recording_of_each_try_logged(context)
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > if any query of index building fails, times out, loses its connection, or is answered that FalkorDB is loading > when index building is tried again" do
    setup [:start_real_embedded_pool, :substitute_index_building_retry_sleep]

    test "then the graph library's own index building creates only the indexes the graph lacks",
         context do
      assert_try_creates_only_indexes_graph_lacks(context)
    end

    test "and the stopword replacement replaces only the indexes that still carry a stopword list",
         context do
      assert_try_replaces_only_indexes_still_carrying_stopwords(context)
    end

    test "and the writer recording records writers only on episodes, facts, and entities still without them",
         context do
      assert_try_records_only_writers_still_missing(context)
    end

    test "and the try reads which vector indexes the graph has", context do
      assert_try_reads_which_vector_indexes_graph_has(context)
    end

    test "and the try creates only the vector indexes the graph lacks, so one that a failed try created, or that FalkorDB created for a query its client stopped waiting for, is not created twice",
         context do
      assert_try_creates_only_vector_indexes_graph_lacks(context)
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > if any query of index building fails, times out, loses its connection, or is answered that FalkorDB is loading > when index building is tried again > while a try succeeds" do
    setup [:start_real_embedded_pool, :substitute_index_building_retry_sleep]

    test "then index building is not tried again", context do
      assert_building_not_tried_again_once_try_succeeds(context)
    end

    test "and the success is logged once, naming the graph and which try succeeded", context do
      assert_success_logged_once_naming_graph_and_try(context)
    end

    test "and the vector indexes that the tries created are logged together, naming the graph, each index created, and its dimension",
         context do
      assert_indexes_tries_created_logged_together(context)
    end

    test "and a vector index that FalkorDB created for a query its client stopped waiting for is logged among them",
         context do
      assert_index_created_for_unawaited_query_logged(context)
    end

    test "and index building succeeds", context do
      assert_index_building_succeeds_after_failed_try(context)
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > if any query of index building fails, times out, loses its connection, or is answered that FalkorDB is loading > when index building is tried again > if a try finds a mismatched vector index" do
    setup [:start_real_embedded_pool, :substitute_index_building_retry_sleep]

    test "then no success is logged", context do
      assert_no_success_logged_when_try_finds_mismatch(context)
    end

    test "and index building fails naming the mismatched index", context do
      assert_index_building_fails_naming_mismatch_a_try_found(context)
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > if any query of index building fails, times out, loses its connection, or is answered that FalkorDB is loading > when index building is tried again > if every try fails" do
    setup [:start_real_embedded_pool, :substitute_index_building_retry_sleep]

    test "then index building fails, naming the graph, how many times it was tried, and the last failure",
         context do
      assert_index_building_fails_naming_graph_tries_and_last_failure(context)
    end

    test "and every other graph's indexes are still built", context do
      assert_other_graphs_built_beside_failed_building(context)
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > if index building fails any other way, or its graph operation runs past its deadline" do
    setup [:start_real_embedded_pool, :substitute_index_building_retry_sleep]

    test "then index building is not tried again", context do
      assert_building_not_tried_again_after_another_failure(context)
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > while a label's index already carries a stopword list" do
    setup [:start_real_embedded_pool, :create_stopword_indexes]

    test "then every index on that label is dropped and recreated with the same fields and no stopword list",
         %{pid: pid} do
      instance = GraphitiPool.for(pid, "stopwords")

      episodic = Enum.find(graph_indexes(instance), &(&1["label"] == "Episodic"))

      assert episodic["stopwords"] == []
      assert "RANGE" in episodic["types"]["uuid"]
      assert "RANGE" in episodic["types"]["custom"]
      assert "FULLTEXT" in episodic["types"]["content"]
      assert "FULLTEXT" in episodic["types"]["source"]
      assert Enum.sort(episodic["types"]["group_id"]) == ["FULLTEXT", "RANGE"]
    end

    test "and the replacement is logged naming the label", %{pid: pid} do
      log = capture_log(fn -> GraphitiPool.for(pid, "stopwords") end)

      assert log =~ "[gralkor] full-text indexes rebuilt without stopwords"
      assert log =~ "Episodic"
    end

    test "and an exact-match lookup for a stopword value on that label returns its match",
         %{pid: pid} do
      instance = GraphitiPool.for(pid, "stopwords")

      assert graph_query(
               instance,
               "MATCH (e:Episodic) WHERE e.uuid IN ['the'] RETURN e.uuid AS uuid"
             ) ==
               [%{"uuid" => "the"}]
    end

    test "and both vector indexes are created after the replacement", %{pid: pid} do
      instance = capture_log_result(fn -> GraphitiPool.for(pid, "stopwords") end)

      assert Enum.find(graph_indexes(instance), &(&1["label"] == "Episodic"))["stopwords"] == []

      assert Map.keys(vector_index_options(instance)) |> Enum.sort() ==
               ["Entity.name_embedding", "RELATES_TO.fact_embedding"]
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > while every index already carries no stopword list" do
    setup :start_real_embedded_pool

    test "then no index is replaced", %{pid: pid} do
      GraphitiPool.for(pid, "fresh")

      log = capture_log(fn -> assert {:ok, _} = GraphitiPool.build_indices(pid) end)

      refute log =~ "rebuilt without stopwords"
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > if a label carrying a stopword list also holds an index that is neither range nor full-text" do
    setup [:start_real_embedded_pool, :create_stopword_indexes_beside_a_vector_index]

    test "then that label's indexes are left unchanged", %{pid: pid} do
      capture_log(fn -> GraphitiPool.for(pid, "stopwords") end)

      episodic =
        Enum.find(physical_graph_indexes(pid, "stopwords"), &(&1["label"] == "Episodic"))

      assert episodic["stopwords"] == ["a", "the"]
      assert "VECTOR" in episodic["types"]["embedding"]
    end

    test "and the failure is logged naming the label", %{pid: pid} do
      log = capture_log(fn -> GraphitiPool.for(pid, "stopwords") end)

      assert log =~ "build_indices_and_constraints failed (non-fatal)"
      assert log =~ "Episodic"
    end

    test "and no vector index is created", %{pid: pid} do
      capture_log(fn -> GraphitiPool.for(pid, "stopwords") end)

      indexes = physical_graph_indexes(pid, "stopwords")

      for label <- ["Entity", "RELATES_TO"] do
        index = Enum.find(indexes, %{"types" => %{}}, &(&1["label"] == label))
        refute Enum.any?(Map.values(index["types"]), &("VECTOR" in &1))
      end
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > while the graph holds episodes, facts, or entities without recorded writers" do
    setup [:start_real_embedded_pool, :seed_unrecorded_writer_graph]

    test "then each such episode records the writer its provenance names, or `unknown`", %{
      pid: pid
    } do
      instance = capture_log_result(fn -> GraphitiPool.for(pid, "history") end)

      assert recorded_writers(
               instance,
               "MATCH (e:Episodic) RETURN e.uuid AS key, e._gralkor_writers AS writers"
             ) == %{
               "lens-ep" => ["lens:alpha"],
               "durable-direct-ep" => ["direct"],
               "described-direct-ep" => ["direct"],
               "reflection-ep" => ["reflection:review"],
               "unknown-ep" => ["unknown"]
             }
    end

    test "and each such fact and entity records the writers of its episodes", %{pid: pid} do
      instance = capture_log_result(fn -> GraphitiPool.for(pid, "history") end)

      assert recorded_writers(
               instance,
               "MATCH ()-[e:RELATES_TO]->() RETURN e.uuid AS key, e._gralkor_writers AS writers"
             ) == %{
               "shared-edge" => ["lens:alpha", "direct"],
               "reflection-edge" => ["reflection:review"],
               "orphan-edge" => ["unknown"]
             }

      assert recorded_writers(
               instance,
               "MATCH (n:Entity) RETURN n.uuid AS key, n._gralkor_writers AS writers"
             ) == %{
               "shared-node" => ["lens:alpha", "reflection:review"],
               "direct-node" => ["direct"],
               "orphan-node" => ["unknown"]
             }
    end

    test "and the recording is logged naming the graph and how many episodes, facts, and entities it recorded",
         %{pid: pid} do
      log = capture_log(fn -> GraphitiPool.for(pid, "history") end)

      assert log =~
               "[gralkor] recorded writers for memory written before writers were recorded — " <>
                 "graph: #{physical("history")} episodes: 5 facts: 3 entities: 3"
    end
  end

  describe "when a graph instance's indexes are built on FalkorDB > while every episode, fact, and entity already records its writers" do
    setup [:start_real_embedded_pool, :seed_recorded_writer_graph]

    test "then nothing is recorded", %{pid: pid} do
      instance = capture_log_result(fn -> GraphitiPool.for(pid, "recorded") end)
      capture_log(fn -> assert {:ok, _} = GraphitiPool.build_indices(pid) end)

      assert recorded_writers(
               instance,
               "MATCH (e:Episodic) RETURN e.uuid AS key, e._gralkor_writers AS writers"
             ) == %{"lens-ep" => ["direct"]}

      assert recorded_writers(
               instance,
               "MATCH ()-[e:RELATES_TO]->() RETURN e.uuid AS key, e._gralkor_writers AS writers"
             ) == %{"edge" => ["reflection:review"]}

      assert recorded_writers(
               instance,
               "MATCH (n:Entity) RETURN n.uuid AS key, n._gralkor_writers AS writers"
             ) == %{"node" => ["unknown"]}
    end

    test "and nothing is logged", %{pid: pid} do
      log = capture_log(fn -> GraphitiPool.for(pid, "recorded") end)
      refute log =~ "recorded writers"

      log = capture_log(fn -> assert {:ok, _} = GraphitiPool.build_indices(pid) end)
      refute log =~ "recorded writers"
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

  describe "when community building is requested for a group" do
    test "then the logical group is physically encoded before its graph instance is selected" do
      test_pid = self()
      instance = community_graph()
      physical_group = physical("operator-one")

      %{pid: pid} =
        start_pool(
          construct_instance: fn _db, _shared, group ->
            send(test_pid, {:constructed_for, group})
            instance
          end
        )

      assert {:ok, _counts} = GraphitiPool.build_communities(pid, "operator-one")
      assert_receive {:constructed_for, ^physical_group}
      GenServer.stop(pid)
    end

    test "and the graph library builds communities for that physical group's instance" do
      instance = community_graph()

      %{pid: pid} =
        start_pool(construct_instance: fn _db, _shared, _group -> instance end)

      assert {:ok, %{communities: 2, edges: 3}} =
               GraphitiPool.build_communities(pid, "operator-one")

      {calls, _} = Pythonx.eval("g.calls", %{"g" => instance})
      assert Pythonx.decode(calls) == 1
      GenServer.stop(pid)
    end

    test "and the returned community and edge counts are reported" do
      instance = community_graph()

      %{pid: pid} =
        start_pool(construct_instance: fn _db, _shared, _group -> instance end)

      assert {:ok, %{communities: 2, edges: 3}} =
               GraphitiPool.build_communities(pid, "operator-one")

      GenServer.stop(pid)
    end
  end

  describe "if community building raises inside the graph library" do
    test "then an error carrying the raised exception is returned" do
      {instance, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              async def build_communities(self):
                  raise RuntimeError("community failure")

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid} =
        start_pool(construct_instance: fn _db, _shared, _group -> instance end)

      assert {:error, {:python, message}} =
               GraphitiPool.build_communities(pid, "operator-one")

      assert message =~ "community failure"
      GenServer.stop(pid)
    end
  end

  defp community_graph do
    {instance, _} =
      Pythonx.eval(
        """
        class _FakeGraphiti:
            def __init__(self):
                self.calls = 0

            async def build_communities(self):
                self.calls += 1
                return (["one", "two"], ["a", "b", "c"])

        _FakeGraphiti()
        """,
        %{}
      )

    instance
  end

  describe "when a memory search is run for a group" do
    test "then the graph library is searched once for edges, nodes, and episodes together" do
      {_results, recorded} = memory_search_result()

      assert recorded["calls"] == 1
      assert recorded["edge_config"]
      assert recorded["node_config"]
      assert recorded["episode_config"]
      refute recorded["community_config"]
      assert recorded["query"] == "what changed parse"
    end

    test "and edges and nodes are each ranked by reciprocal rank fusion of full-text and similarity search, and episodes by full-text search" do
      {_results, recorded} = memory_search_result()

      assert recorded["edge_reranker"] == "reciprocal_rank_fusion"
      assert recorded["node_reranker"] == "reciprocal_rank_fusion"
      assert recorded["edge_methods"] == ["bm25", "cosine_similarity"]
      assert recorded["node_methods"] == ["bm25", "cosine_similarity"]
      assert recorded["episode_methods"] == ["bm25"]
    end

    test "and the graph library is asked for as many results of each kind as the largest requested kind limit" do
      {_results, recorded} = memory_search_result(limits: %{facts: 2, nodes: 7, episodes: 1})
      assert recorded["limit"] == 7
    end

    test "and it searches only the database of that group, whatever group id each record stores" do
      {_results, recorded} = memory_search_result()
      assert_received {:memory_search_instance, group_id}
      assert group_id == physical("group-with-hyphens")
      assert recorded["group_ids"] == nil
    end

    test "and each returned edge is rendered as a fact carrying its text, its created, valid, invalid, and expired timestamps, and its originating episodes by identifier, source kind, and source description" do
      {%{facts: [fact | _]}, _recorded} = memory_search_result()

      assert %{
               fact: "commit-1 changes parse",
               created_at: "2024-01-01 00:00:00+00:00",
               valid_at: "2024-01-02 00:00:00+00:00",
               invalid_at: nil,
               expired_at: nil,
               sources: [
                 %{id: "episode-1", source_kind: "document", source_description: "git log"}
               ]
             } = fact
    end

    test "and each returned edge is rendered with its relationship name and the name and identifier of its source and target entities" do
      {%{facts: [fact | _]}, _recorded} = memory_search_result()

      assert fact.relationship == "CHANGES"
      assert fact.source_node == %{uuid: "commit-1", name: "Commit 1"}
      assert fact.target_node == %{uuid: "parse-fn", name: "parse/1"}
    end

    test "and each returned node is rendered with its name, summary, and attributes" do
      {%{nodes: [node | _]}, _recorded} = memory_search_result()
      assert node == %{name: "parse/1", summary: "parses input", attributes: %{"arity" => "1"}}
    end

    test "and each returned episode is rendered with the body that was written, its source description, and its source kind" do
      {%{episodes: [episode | _]}, _recorded} = memory_search_result()

      assert episode == %{
               content: "commit 1 touched parse",
               source_description: "git log",
               source_kind: "document"
             }
    end

    test "and facts, nodes, and episodes are each returned in the graph library's relevance order and cut to their own requested limit" do
      {results, _recorded} = memory_search_result(limits: %{facts: 1, nodes: 2, episodes: 2})

      assert Enum.map(results.facts, & &1.fact) == ["commit-1 changes parse"]
      assert Enum.map(results.nodes, & &1.name) == ["parse/1", "render/2"]

      assert Enum.map(results.episodes, & &1.content) == [
               "commit 1 touched parse",
               "commit 2 touched render"
             ]
    end

    test "and nothing an extractor derived from an episode is needed to return it, so an episode no entity was extracted from is still returned" do
      {results, _recorded} = memory_search_result(edges: false, nodes: false)

      assert results.facts == []
      assert results.nodes == []
      assert [%{content: "commit 1 touched parse"} | _] = results.episodes
    end

    test "and the fact and entity queries bring back no embedding from FalkorDB" do
      %{pid: pid} = start_real_embedded_pool(%{})
      searched = column_search(seed_embedded_graph(pid))

      assert length(searched["raw"]) == 7
      assert searched["lookups"] == 3

      for attributes <- searched["raw"] do
        assert attributes["fact_embedding"] == nil
        assert attributes["name_embedding"] == nil
      end

      assert searched["own_raw"]
             |> Enum.map(&Map.keys/1)
             |> List.flatten()
             |> Enum.any?(&(&1 =~ "_embedding"))
    end

    test "and each fact and entity still carries every other stored property among its attributes" do
      %{pid: pid} = start_real_embedded_pool(%{})
      searched = column_search(seed_embedded_graph(pid))

      assert searched["edges"] ==
               List.duplicate(%{"severity" => "high", "_gralkor_writers" => ["lens:alpha"]}, 3)

      assert searched["nodes"] ==
               List.duplicate(%{"team" => "payments", "_gralkor_writers" => ["lens:alpha"]}, 4)

      assert searched["edges"] == searched["own_edges"]
      assert searched["nodes"] == searched["own_nodes"]
    end

    test "and after the graph library's search, the facts' source episodes, the writers and extraction completion recorded on those and the returned episodes, and the facts' entity names are read by three queries sent together" do
      {results, recorded} = memory_search_result(two_writers: true, reflections: true)

      assert Enum.sort(recorded["follow_ups"]) == ["entity names", "recorded", "source episodes"]
      assert recorded["most_in_flight"] == 3
      assert [%{sources: [_, _]} | _] = results.facts
    end

    test "and every query the search sends carries a FalkorDB query timeout below the socket timeout" do
      %{pid: pid} = start_real_searching_pool(%{})
      spy = spy_query_timeouts()

      assert {:ok, %{facts: [_], nodes: [_ | _], episodes: [_]}} =
               GraphitiPool.search_memory(pid, "searching", "amber", %{
                 facts: 5,
                 nodes: 5,
                 episodes: 5
               })

      timeouts = spied_timeouts(spy)
      assert length(timeouts) >= 6
      assert Enum.uniq(timeouts) == [3_600]
    end
  end

  describe "when a memory search is run for a group > if a query the search sends runs past its FalkorDB query timeout" do
    setup [:start_real_searching_pool, :search_slowly]

    test "then FalkorDB stops running it", %{pid: pid, outcome: outcome} do
      assert {:error, _} = outcome

      info =
        Gralkor.Python.run_coroutine(
          "database.connection.execute_command('GRAPH.INFO')",
          %{"database" => :sys.get_state(pid).falkor_db}
        )
        |> Pythonx.decode()

      assert ["# Running queries", [], "# Waiting queries", [] | _] = info
    end

    test "and the search returns FalkorDB's timeout error", %{outcome: outcome, elapsed: elapsed} do
      assert {:error, {:python, message}} = outcome
      assert message =~ "Query timed out"
      assert elapsed >= 3_600
      assert elapsed < 4_000
    end
  end

  describe "when a memory search is run for a group > if one of the follow-up queries reading source episodes, recorded writers and extraction completion, and entity names fails" do
    test "then the search abandons the other follow-up queries before it returns" do
      for failing <- ["source episodes", "recorded", "entity names"] do
        {{:error, _}, recorded, settled} =
          memory_search_outcome(two_writers: true, failing: failing, settle_ms: 700)

        others = Enum.sort(["source episodes", "recorded", "entity names"] -- [failing])
        assert Enum.sort(recorded["cancelled"]) == others
        assert settled["finished"] == []
      end

      {{:error, _}, recorded, settled} =
        memory_search_outcome(
          two_writers: true,
          failing: "recorded",
          failure: "cancelled",
          settle_ms: 700
        )

      assert Enum.sort(recorded["cancelled"]) == ["entity names", "source episodes"]
      assert settled["finished"] == []
    end

    test "and the search returns that query's error" do
      {outcome, _recorded, _settled} =
        memory_search_outcome(two_writers: true, failing: "entity names")

      assert {:error, {:python, message}} = outcome
      assert message =~ "RuntimeError: entity names failed"
    end

    test "and a follow-up query that times out makes the search return a timeout" do
      {outcome, _recorded, _settled} =
        memory_search_outcome(two_writers: true, failing: "recorded", failure: "timeout")

      assert {:error, :timeout} = outcome
    end
  end

  defp search_slowly(%{pid: pid, instance: instance}) do
    graph_query(instance, "UNWIND range(1, 400) AS i CREATE (:Slow {i: i})")

    Pythonx.eval(
      "g.slow = 'MATCH (a:Slow), (b:Slow), (c:Slow), (d:Slow) RETURN count(*)'\nNone",
      %{"g" => instance}
    )

    started = System.monotonic_time(:millisecond)

    outcome =
      GraphitiPool.search_memory(pid, "searching", "amber", %{facts: 5, nodes: 5, episodes: 5})

    %{outcome: outcome, elapsed: System.monotonic_time(:millisecond) - started}
  end

  # One group's graph holding entities and facts with embeddings and one stored
  # property of their own each.
  defp seed_embedded_graph(pid) do
    instance = GraphitiPool.for(pid, "columns")

    graph_query(instance, """
    CREATE (ep:Episodic {uuid: 'amber-ep', name: 'amber', group_id: 'g', source: 'text', source_description: 'notes', content: 'amber', entity_edges: [], created_at: '2026-06-01T00:00:00+00:00', valid_at: '2026-06-01T00:00:00+00:00', _gralkor_writers: ['lens:alpha']}),
           (a:Entity {uuid: 'a', name: 'amber a', group_id: 'g', summary: 'amber', created_at: '2026-06-01T00:00:00+00:00', team: 'payments', _gralkor_writers: ['lens:alpha']}),
           (b:Entity {uuid: 'b', name: 'amber b', group_id: 'g', summary: 'amber', created_at: '2026-06-01T00:00:00+00:00', team: 'payments', _gralkor_writers: ['lens:alpha']}),
           (a)-[:RELATES_TO {uuid: 'ab', name: 'OWNS', fact: 'amber a owns b', group_id: 'g', episodes: ['amber-ep'], created_at: '2026-06-01T00:00:00+00:00', severity: 'high', _gralkor_writers: ['lens:alpha']}]->(b)
    """)

    graph_query(
      instance,
      "MATCH (n:Entity) SET n.name_embedding = vecf32([1.0, 0.0, 0.0]) WITH count(n) AS done MATCH ()-[e:RELATES_TO]->() SET e.fact_embedding = vecf32([1.0, 0.0, 0.0])"
    )

    instance
  end

  # Runs the graph library's fact and entity searches, as the started pool
  # wraps them, and the same searches with the graph library's own result
  # columns, recording the attributes FalkorDB sent back for every row.
  defp column_search(instance) do
    """
    import copy
    import graphiti_core.search.search as search_module
    import graphiti_core.search.search_utils as search_utils
    from graphiti_core.search.search_filters import SearchFilters
    from graphiti_core.driver.driver import GraphProvider

    driver = g.driver
    since = search_utils._gralkor_search_filters(since='2026-01-01T00:00:00Z')

    lookups = []

    async def searched():
        raw = []
        original = driver.execute_query
        async def recording(cypher, **params):
            result = await original(cypher, **params)
            if 'db.idx.vector' in cypher:
                lookups.append(cypher)
            raw.extend(copy.deepcopy(record['attributes']) for record in result[0] if 'attributes' in record)
            return result
        driver.execute_query = recording
        try:
            edges = (
                await search_utils.edge_fulltext_search(driver, 'amber', SearchFilters(), None, 10)
                + await search_module.edge_similarity_search(driver, [1.0, 0.0, 0.0], None, None, SearchFilters(), None, 1, 0.5)
                + await search_module.edge_similarity_search(driver, [1.0, 0.0, 0.0], None, None, since, None, 1, 0.5)
            )
            nodes = (
                await search_utils.node_fulltext_search(driver, 'amber', SearchFilters(), None, 10)
                + await search_module.node_similarity_search(driver, [1.0, 0.0, 0.0], SearchFilters(), None, 2, 0.5)
            )
        finally:
            del driver.execute_query
        return raw, edges, nodes

    async def own():
        own_raw = []
        records, _, _ = await driver.execute_query(
            'MATCH (n:Entity)-[e:RELATES_TO]->(m:Entity) RETURN '
            + search_utils.get_entity_edge_return_query._gralkor_original(GraphProvider.FALKORDB)
        )
        own_raw.extend(copy.deepcopy(record['attributes']) for record in records)
        own_edges = [search_utils.get_entity_edge_from_record(record, GraphProvider.FALKORDB) for record in records]
        records, _, _ = await driver.execute_query(
            'MATCH (n:Entity) RETURN ' + search_utils.get_entity_node_return_query._gralkor_original(GraphProvider.FALKORDB)
        )
        own_raw.extend(copy.deepcopy(record['attributes']) for record in records)
        own_nodes = [search_utils.get_entity_node_from_record(record, GraphProvider.FALKORDB) for record in records]
        return own_raw, own_edges, own_nodes

    async def run():
        raw, edges, nodes = await searched()
        own_raw, own_edges, own_nodes = await own()
        return {
            'raw': raw,
            'lookups': len(lookups),
            'own_raw': own_raw,
            'edges': [edge.attributes for edge in edges],
            'nodes': [node.attributes for node in nodes],
            'own_edges': [edge.attributes for edge in own_edges] * 3,
            'own_nodes': [node.attributes for node in own_nodes] * 2,
        }

    run()
    """
    |> Gralkor.Python.run_coroutine(%{"g" => instance})
    |> Pythonx.decode()
  end

  describe "when a memory search is run for a group > while node labels are supplied" do
    test "then the single search's filter carries those labels" do
      {_results, recorded} = memory_search_result(opts: [node_labels: ["Function", "Commit"]])
      assert recorded["node_labels"] == ["Function", "Commit"]
    end
  end

  describe "when a memory search is run for a group > while node labels are supplied > while several node labels are supplied" do
    test "then the graph library's node filter admits a node carrying any one of them" do
      queries = filter_queries(%{"node_labels" => ["Function", "Commit"]})

      assert queries["node"]["queries"] == ["(n:Function OR n:Commit)"]
      assert queries["falkor_node"]["queries"] == ["(n:Function OR n:Commit)"]
      assert queries["own_node"]["queries"] == ["n:Function|Commit"]
    end

    test "and its edge filter admits an edge whose source and target each carry any one of them" do
      queries = filter_queries(%{"node_labels" => ["Function", "Commit"]})
      expected = "(n:Function OR n:Commit) AND (m:Function OR m:Commit)"

      assert expected in queries["edge"]["queries"]
      assert expected in queries["falkor_edge"]["queries"]
      assert "n:Function|Commit AND m:Function|Commit" in queries["own_edge"]["queries"]
    end
  end

  describe "when a memory search is run for a group > while edge types are supplied" do
    test "then the single search's filter carries those relationship types" do
      {_results, recorded} = memory_search_result(opts: [edge_types: ["CHANGES"]])
      assert recorded["edge_types"] == ["CHANGES"]
    end
  end

  describe "when a memory search is run for a group > while neither node labels, edge types, included writers, excluded writers, nor an earliest creation time are supplied" do
    test "then the single search's filter leaves every node and edge eligible" do
      {_results, recorded} = memory_search_result()
      assert recorded["filter_class"] == "SearchFilters"
      assert recorded["node_labels"] == nil
      assert recorded["edge_types"] == nil
      assert recorded["edge_uuids"] == nil
      assert recorded["writers"] == nil
      assert recorded["excluded_writers"] == nil
      assert recorded["since"] == nil
    end

    test "and the graph library's own node and episode queries are issued unchanged" do
      for filters <- [%{}, %{"node_labels" => ["Function"]}, %{"edge_types" => ["CHANGES"]}] do
        queries = filter_queries(filters)

        assert queries["node"] == queries["own_node"]
        assert queries["falkor_node"] == queries["own_node"]
        assert queries["edge"] == queries["own_edge"]
        assert queries["falkor_edge"] == queries["own_edge"]
      end

      %{"wrapped" => wrapped, "own" => own} = episode_fulltext_queries(nil)
      assert [_query] = own
      assert wrapped == own
    end
  end

  describe "when a memory search is run for a group > while writers are included" do
    setup [:start_real_embedded_pool, :seed_writer_graph]

    test "then the single search's filter admits only edges produced by an included writer",
         %{instance: instance} do
      {_results, recorded} = memory_search_result(opts: [writers: ["lens:alpha", "direct"]])
      assert recorded["filter_class"] == "WriterSearchFilters"
      assert recorded["writers"] == ["lens:alpha", "direct"]
      assert recorded["edge_uuids"] == nil

      assert writer_search(instance, %{"writers" => ["lens:alpha"]})["edges"] ==
               ["alpha-edge", "shared-edge"]

      assert writer_search(instance, %{"writers" => ["lens:*"]})["edges"] ==
               ["alpha-edge", "beta-edge", "shared-edge"]
    end

    test "and the single search's filter admits only nodes produced by an included writer",
         %{instance: instance} do
      assert writer_search(instance, %{"writers" => ["lens:alpha"]})["nodes"] ==
               ["alpha-node", "shared-node"]

      assert writer_search(instance, %{"writers" => ["direct", "lens:beta"]})["nodes"] ==
               ["beta-node", "direct-node", "shared-node"]
    end

    test "and the single search's filter admits only episodes written by an included writer",
         %{instance: instance} do
      assert writer_search(instance, %{"writers" => ["lens:alpha"]})["episodes"] == ["alpha-ep"]

      assert writer_search(instance, %{"writers" => ["reflection:*", "direct"]})["episodes"] ==
               ["direct-ep", "review-ep"]
    end

    test "and each admission is decided from the writers recorded on the edge, node, or episode itself, without a list of record identifiers",
         %{instance: instance} do
      queries =
        filter_queries(%{"writers" => ["lens:alpha", "reflection:*"]}, "WriterSearchFilters")

      for {kind, variable} <- [
            {"node", "n"},
            {"falkor_node", "n"},
            {"edge", "e"},
            {"falkor_edge", "e"}
          ] do
        assert Enum.any?(queries[kind]["queries"], &(&1 =~ "#{variable}._gralkor_writers"))

        assert queries[kind]["params"] == %{
                 "gralkor_writers" => ["lens:alpha"],
                 "gralkor_writers_prefixes" => ["reflection:"]
               }
      end

      %{"wrapped" => [query]} = episode_fulltext_queries(%{"writers" => ["lens:alpha"]})
      assert query["cypher"] =~ "e._gralkor_writers"
      assert query["gralkor_writers"] == ["lens:alpha"]
      refute Enum.any?(Map.keys(query), &(&1 =~ "uuid"))

      graph_query(
        instance,
        "MATCH (n:Entity {uuid: 'beta-node'}) SET n._gralkor_writers = ['lens:alpha']"
      )

      assert writer_search(instance, %{"writers" => ["lens:alpha"]})["nodes"] ==
               ["alpha-node", "beta-node", "shared-node"]
    end

    test "and every admission is applied inside its query, before its limit", %{
      instance: instance
    } do
      found = writer_search(instance, %{"writers" => ["lens:alpha"]}, 1)

      assert [edge] = found["edges"]
      assert edge in ["alpha-edge", "shared-edge"]
      assert [node] = found["nodes"]
      assert node in ["alpha-node", "shared-node"]
      assert found["episodes"] == ["alpha-ep"]

      %{"wrapped" => [query]} = episode_fulltext_queries(%{"writers" => ["lens:alpha"]})
      assert {admission_at, _} = :binary.match(query["cypher"], "e._gralkor_writers")
      assert {limit_at, _} = :binary.match(query["cypher"], "LIMIT $limit")
      assert admission_at < limit_at
      assert query["cypher"] =~ "db.idx.fulltext.queryNodes"
      assert query["limit"] == 5
    end

    test "and each rendered fact's sources include only episodes written by an included writer" do
      {%{facts: [fact | _]}, _recorded} =
        memory_search_result(two_writers: true, opts: [writers: ["lens:alpha"]])

      assert [%{id: "lens-episode", source_description: "notes [lens: alpha]"}] = fact.sources

      {%{facts: [fact | _]}, _recorded} =
        memory_search_result(two_writers: true, opts: [writers: ["lens:*", "direct"]])

      assert Enum.map(fact.sources, & &1.id) == ["episode-1", "lens-episode"]
    end
  end

  describe "when a memory search is run for a group > while writers are excluded" do
    setup [:start_real_embedded_pool, :seed_writer_graph]

    test "then the single search's filter rejects episodes written by an excluded writer",
         %{instance: instance} do
      {_results, recorded} = memory_search_result(opts: [excluded_writers: ["lens:alpha"]])
      assert recorded["filter_class"] == "WriterSearchFilters"
      assert recorded["excluded_writers"] == ["lens:alpha"]
      assert recorded["writers"] == nil

      assert writer_search(instance, %{"excluded_writers" => ["lens:alpha"]})["episodes"] ==
               ["beta-ep", "direct-ep", "review-ep"]

      assert writer_search(instance, %{"excluded_writers" => ["lens:*", "reflection:review"]})[
               "episodes"
             ] == ["direct-ep"]
    end

    test "and the single search's filter rejects edges produced only by excluded writers",
         %{instance: instance} do
      assert writer_search(instance, %{"excluded_writers" => ["lens:alpha"]})["edges"] ==
               ["beta-edge", "direct-edge", "shared-edge"]

      assert writer_search(instance, %{"excluded_writers" => ["lens:alpha", "direct"]})["edges"] ==
               ["beta-edge"]
    end

    test "and the single search's filter rejects nodes produced only by excluded writers",
         %{instance: instance} do
      assert writer_search(instance, %{"excluded_writers" => ["lens:alpha"]})["nodes"] ==
               ["beta-node", "direct-node", "shared-node"]

      assert writer_search(instance, %{"excluded_writers" => ["lens:*", "direct"]})["nodes"] == []
    end

    test "and each rejection is decided from the writers recorded on the edge, node, or episode itself, without a list of record identifiers",
         %{instance: instance} do
      queries =
        filter_queries(%{"excluded_writers" => ["direct", "lens:*"]}, "WriterSearchFilters")

      for {kind, variable} <- [
            {"node", "n"},
            {"falkor_node", "n"},
            {"edge", "e"},
            {"falkor_edge", "e"}
          ] do
        assert Enum.any?(queries[kind]["queries"], &(&1 =~ "#{variable}._gralkor_writers"))

        assert queries[kind]["params"] == %{
                 "gralkor_excluded_writers" => ["direct"],
                 "gralkor_excluded_writers_prefixes" => ["lens:"]
               }
      end

      %{"wrapped" => [query]} = episode_fulltext_queries(%{"excluded_writers" => ["lens:alpha"]})
      assert query["cypher"] =~ "e._gralkor_writers"
      assert query["gralkor_excluded_writers"] == ["lens:alpha"]
      refute Enum.any?(Map.keys(query), &(&1 =~ "uuid"))

      graph_query(
        instance,
        "MATCH ()-[e:RELATES_TO {uuid: 'beta-edge'}]->() SET e._gralkor_writers = ['lens:alpha']"
      )

      assert writer_search(instance, %{"excluded_writers" => ["lens:alpha"]})["edges"] ==
               ["direct-edge", "shared-edge"]
    end

    test "and every rejection is applied inside its query, before its limit", %{
      instance: instance
    } do
      found = writer_search(instance, %{"excluded_writers" => ["lens:beta", "direct"]}, 1)

      assert [edge] = found["edges"]
      assert edge in ["alpha-edge", "shared-edge"]
      assert [node] = found["nodes"]
      assert node in ["alpha-node", "shared-node"]
      assert [episode] = found["episodes"]
      assert episode in ["alpha-ep", "review-ep"]

      %{"wrapped" => [query]} = episode_fulltext_queries(%{"excluded_writers" => ["lens:alpha"]})
      assert {rejection_at, _} = :binary.match(query["cypher"], "e._gralkor_writers")
      assert {limit_at, _} = :binary.match(query["cypher"], "LIMIT $limit")
      assert rejection_at < limit_at
      assert query["limit"] == 5
    end

    test "and each rendered fact's sources omit episodes written by an excluded writer" do
      {%{facts: [fact | _]}, _recorded} =
        memory_search_result(two_writers: true, opts: [excluded_writers: ["lens:alpha"]])

      assert [%{id: "episode-1", source_description: "git log"}] = fact.sources
    end
  end

  # One group's graph whose every record carries its recorded writers. The
  # Lens `beta` and direct records match the query more strongly than any
  # `alpha` record does.
  defp seed_writer_graph(%{pid: pid}) do
    instance = GraphitiPool.for(pid, "writers")

    graph_query(instance, """
    CREATE (alpha:Episodic {uuid: 'alpha-ep', name: 'alpha', group_id: 'g', source: 'text', source_description: 'notes [lens: alpha]', content: 'amber alpha', entity_edges: [], created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z', _gralkor_writers: ['lens:alpha']}),
           (:Episodic {uuid: 'beta-ep', name: 'beta', group_id: 'g', source: 'text', source_description: 'notes [lens: beta]', content: 'amber amber amber beta', entity_edges: [], created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z', _gralkor_writers: ['lens:beta']}),
           (:Episodic {uuid: 'direct-ep', name: 'direct', group_id: 'g', source: 'text', source_description: 'manual', content: 'amber amber amber direct', entity_edges: [], created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z', _gralkor_writers: ['direct']}),
           (:Episodic {uuid: 'review-ep', name: 'review', group_id: 'g', source: 'json', source_description: 'reflection:review', content: 'amber review', entity_edges: [], created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z', _gralkor_writers: ['reflection:review']}),
           (a:Entity {uuid: 'alpha-node', name: 'amber alpha', group_id: 'g', summary: 'amber', created_at: '2026-01-01T00:00:00Z', _gralkor_writers: ['lens:alpha']}),
           (s:Entity {uuid: 'shared-node', name: 'amber shared', group_id: 'g', summary: 'amber', created_at: '2026-01-01T00:00:00Z', _gralkor_writers: ['lens:alpha', 'direct']}),
           (b:Entity {uuid: 'beta-node', name: 'amber amber amber beta', group_id: 'g', summary: 'amber amber amber', created_at: '2026-01-01T00:00:00Z', _gralkor_writers: ['lens:beta']}),
           (d:Entity {uuid: 'direct-node', name: 'amber amber amber direct', group_id: 'g', summary: 'amber amber amber', created_at: '2026-01-01T00:00:00Z', _gralkor_writers: ['direct']}),
           (a)-[:RELATES_TO {uuid: 'alpha-edge', name: 'OWNS', fact: 'amber alpha', group_id: 'g', episodes: ['alpha-ep'], created_at: '2026-01-01T00:00:00Z', _gralkor_writers: ['lens:alpha']}]->(s),
           (s)-[:RELATES_TO {uuid: 'shared-edge', name: 'OWNS', fact: 'amber shared', group_id: 'g', episodes: ['alpha-ep', 'direct-ep'], created_at: '2026-01-01T00:00:00Z', _gralkor_writers: ['lens:alpha', 'direct']}]->(a),
           (b)-[:RELATES_TO {uuid: 'beta-edge', name: 'OWNS', fact: 'amber amber amber beta', group_id: 'g', episodes: ['beta-ep'], created_at: '2026-01-01T00:00:00Z', _gralkor_writers: ['lens:beta']}]->(b),
           (d)-[:RELATES_TO {uuid: 'direct-edge', name: 'OWNS', fact: 'amber amber amber direct', group_id: 'g', episodes: ['direct-ep'], created_at: '2026-01-01T00:00:00Z', _gralkor_writers: ['direct']}]->(d)
    """)

    %{instance: instance}
  end

  # Runs the graph library's own node, edge, and episode full-text searches,
  # as a started pool wraps them, against the group's real graph.
  defp writer_search(instance, filter_kwargs, limit \\ 10) do
    """
    import graphiti_core.search.search as search_module
    import graphiti_core.search.search_utils as search_utils
    def text(value):
        return value.decode('utf-8') if isinstance(value, (bytes, bytearray)) else value
    filters = search_utils._gralkor_search_filters(**{
        text(key): text(value) if isinstance(value, (bytes, bytearray)) else [text(writer) for writer in value]
        for key, value in filter_kwargs.items()
    })
    async def run():
        edges = await search_utils.edge_fulltext_search(g.driver, 'amber', filters, None, limit)
        nodes = await search_utils.node_fulltext_search(g.driver, 'amber', filters, None, limit)
        episodes = await search_module.episode_fulltext_search(g.driver, 'amber', filters, None, limit)
        return {
            'edges': sorted(edge.uuid for edge in edges),
            'nodes': sorted(node.uuid for node in nodes),
            'episodes': sorted(episode.uuid for episode in episodes),
        }
    run()
    """
    |> Gralkor.Python.run_coroutine(%{
      "g" => instance,
      "filter_kwargs" => filter_kwargs,
      "limit" => limit
    })
    |> Pythonx.decode()
  end

  describe "when a memory search is run for a group > while an earliest creation time is supplied" do
    setup [:start_real_embedded_pool, :seed_aged_graph]

    test "then the single search's filter admits only edges created at or after that time",
         %{instance: instance} do
      {_results, recorded} = memory_search_result(opts: [since: ~U[2026-06-01 00:00:00Z]])
      assert recorded["filter_class"] == "WriterSearchFilters"
      assert recorded["since"] == "2026-06-01T00:00:00+00:00"
      assert recorded["writers"] == nil
      assert recorded["excluded_writers"] == nil

      assert writer_search(instance, %{"since" => "2026-06-01T00:00:00Z"})["edges"] ==
               ["at-edge", "new-edge"]

      assert writer_search(instance, %{"since" => "2026-06-01T02:00:00+02:00"})["edges"] ==
               ["at-edge", "new-edge"]
    end

    test "and the single search's filter admits only nodes created at or after that time",
         %{instance: instance} do
      assert writer_search(instance, %{"since" => "2026-06-01T00:00:00Z"})["nodes"] ==
               ["at-node", "new-node"]

      assert writer_search(instance, %{"since" => "2026-06-01T00:00:00.000001Z"})["nodes"] ==
               ["new-node"]
    end

    test "and the single search's filter admits only episodes created at or after that time",
         %{instance: instance} do
      assert writer_search(instance, %{"since" => "2026-06-01T00:00:00Z"})["episodes"] ==
               ["at-ep", "new-ep"]

      assert writer_search(instance, %{"since" => "2025-01-01T00:00:00Z"})["episodes"] ==
               ["at-ep", "new-ep", "old-ep"]
    end

    test "and every admission is applied inside its query, before its limit", %{
      instance: instance
    } do
      found = writer_search(instance, %{"since" => "2026-06-02T00:00:00Z"}, 1)

      assert found == %{
               "edges" => ["new-edge"],
               "nodes" => ["new-node"],
               "episodes" => ["new-ep"]
             }

      queries = filter_queries(%{"since" => "2026-06-01T00:00:00Z"}, "WriterSearchFilters")

      for {kind, variable} <- [
            {"node", "n"},
            {"falkor_node", "n"},
            {"edge", "e"},
            {"falkor_edge", "e"}
          ] do
        assert "#{variable}.created_at >= $gralkor_since" in queries[kind]["queries"]
        assert queries[kind]["params"] == %{"gralkor_since" => "2026-06-01T00:00:00+00:00"}
      end

      %{"wrapped" => [query]} = episode_fulltext_queries(%{"since" => "2026-06-01T00:00:00Z"})
      assert {admission_at, _} = :binary.match(query["cypher"], "e.created_at >= $gralkor_since")
      assert {limit_at, _} = :binary.match(query["cypher"], "LIMIT $limit")
      assert admission_at < limit_at
      assert query["gralkor_since"] == "2026-06-01T00:00:00+00:00"
      assert query["limit"] == 5
    end

    test "and any included or excluded writers are applied in the same queries", %{
      instance: instance
    } do
      restriction = %{
        "since" => "2026-06-01T00:00:00Z",
        "writers" => ["lens:*"],
        "excluded_writers" => ["lens:beta"]
      }

      queries = filter_queries(restriction, "WriterSearchFilters")

      for {kind, variable} <- [
            {"node", "n"},
            {"falkor_node", "n"},
            {"edge", "e"},
            {"falkor_edge", "e"}
          ] do
        assert "#{variable}.created_at >= $gralkor_since" in queries[kind]["queries"]
        assert Enum.count(queries[kind]["queries"], &(&1 =~ "#{variable}._gralkor_writers")) == 2
      end

      %{"wrapped" => [query]} = episode_fulltext_queries(restriction)
      assert query["cypher"] =~ "e.created_at >= $gralkor_since"
      assert query["cypher"] =~ "e._gralkor_writers"
      assert query["gralkor_writers_prefixes"] == ["lens:"]
      assert query["gralkor_excluded_writers"] == ["lens:beta"]

      assert writer_search(instance, restriction) == %{
               "edges" => ["at-edge"],
               "nodes" => ["at-node"],
               "episodes" => ["at-ep"]
             }
    end

    test "and the episode full-text query restricts the episodes the full-text index yields without looking each one up again",
         %{instance: instance} do
      %{"episode_plan" => plan, "episode_cypher" => cypher} = since_search(instance)

      refute cypher =~ "MATCH"
      refute Enum.any?(plan, &(&1 =~ "Scan"))
      assert String.trim(List.last(plan)) == "ProcedureCall"
    end
  end

  describe "when a memory search is run for a group > while an earliest creation time is supplied > where the fact vector index leaves fewer facts than the search keeps" do
    setup [:start_real_embedded_pool, :seed_aged_graph]

    test "then the fact similarity query returns the facts, in the same order, that the graph library's own query returns under the same restrictions",
         context do
      assert_fact_similarity_query_returns_facts_in_same_order_that_graph(context)
    end

    test "and the fact similarity query finds its facts through the creation-time index before it reads any entity",
         context do
      assert_fact_similarity_query_finds_facts_through_creationtime_index(context)
    end
  end

  # Gives the aged graph's facts embeddings at different distances from one
  # query vector, then runs the fact similarity search the started pool wraps
  # and the graph library's own query under several restrictions, and the
  # plans FalkorDB makes for the wrapped fact and episode queries.
  defp since_search(instance) do
    graph_query(
      instance,
      "MATCH ()-[e:RELATES_TO]->() SET e.fact_embedding = CASE e.uuid WHEN 'old-edge' THEN vecf32([0.7, 0.3, 0.0]) WHEN 'at-edge' THEN vecf32([0.8, 0.2, 0.0]) ELSE vecf32([1.0, 0.0, 0.0]) END"
    )

    """
    import graphiti_core.search.search as search_module
    import graphiti_core.search.search_utils as search_utils

    Filters = search_utils._gralkor_search_filters
    driver = g.driver
    vector = [1.0, 0.0, 0.0]
    restrictions = [
        Filters(since='2026-06-01T00:00:00Z'),
        Filters(since='2025-06-01T00:00:00Z'),
        Filters(since='2026-06-01T00:00:00Z', writers=['lens:*']),
        Filters(since='2026-06-01T00:00:00Z', excluded_writers=['lens:beta']),
        Filters(since='2026-06-01T00:00:00Z', edge_types=['OWNS']),
        Filters(since='2026-06-01T00:00:00Z', node_labels=['Entity', 'Missing']),
        Filters(since='2026-06-01T00:00:00Z', edge_types=['KNOWS']),
    ]

    async def run():
        similarity = []
        for restriction in restrictions:
            wrapped = await search_module.edge_similarity_search(driver, vector, None, None, restriction, None, 10, 0.5)
            own = await search_module.edge_similarity_search._gralkor_original(driver, vector, None, None, restriction, None, 10, 0.5)
            similarity.append({'wrapped': [e.uuid for e in wrapped], 'own': [e.uuid for e in own]})
        sent = []
        original = driver.execute_query
        async def recording(cypher, **params):
            params.pop('routing_', None)
            sent.append((cypher, params))
            return await original(cypher, **params)
        driver.execute_query = recording
        try:
            await search_module.edge_similarity_search(driver, vector, None, None, restrictions[0], None, 10, 0.5)
            await search_module.episode_fulltext_search(driver, 'amber', restrictions[0], None, 10)
        finally:
            del driver.execute_query
        graph = driver._get_graph(driver._database)
        similarity_sent = next((c, p) for c, p in sent if c.startswith('MATCH ()-[e:RELATES_TO]->()'))
        episode_sent = next((c, p) for c, p in sent if 'episode_content' in c or 'Episodic' in c)
        plan = lambda pair: graph.explain(pair[0], pair[1])
        return {
            'similarity': similarity,
            'similarity_plan': str(await plan(similarity_sent)).splitlines(),
            'episode_plan': str(await plan(episode_sent)).splitlines(),
            'episode_cypher': episode_sent[0],
        }

    run()
    """
    |> Gralkor.Python.run_coroutine(%{"g" => instance})
    |> Pythonx.decode()
  end

  # One group's graph holding an episode, an entity, and a fact created before
  # 2026-06-01, at it, and after it, stored as graphiti stores creation times.
  # The oldest records match the query most strongly; the records created at
  # that time were written through the Lens `alpha`, the newest through `beta`.
  defp seed_aged_graph(%{pid: pid}) do
    instance = GraphitiPool.for(pid, "aged")

    graph_query(instance, """
    CREATE (:Episodic {uuid: 'old-ep', name: 'old', group_id: 'g', source: 'text', source_description: 'notes [lens: alpha]', content: 'amber amber amber old', entity_edges: [], created_at: '2026-01-01T00:00:00+00:00', valid_at: '2026-01-01T00:00:00+00:00', _gralkor_writers: ['lens:alpha']}),
           (:Episodic {uuid: 'at-ep', name: 'at', group_id: 'g', source: 'text', source_description: 'notes [lens: alpha]', content: 'amber at', entity_edges: [], created_at: '2026-06-01T00:00:00+00:00', valid_at: '2026-06-01T00:00:00+00:00', _gralkor_writers: ['lens:alpha']}),
           (:Episodic {uuid: 'new-ep', name: 'new', group_id: 'g', source: 'text', source_description: 'notes [lens: beta]', content: 'amber new', entity_edges: [], created_at: '2026-06-03T00:00:00.250000+00:00', valid_at: '2026-06-03T00:00:00+00:00', _gralkor_writers: ['lens:beta']}),
           (o:Entity {uuid: 'old-node', name: 'amber amber amber old', group_id: 'g', summary: 'amber amber amber', created_at: '2026-01-01T00:00:00+00:00', _gralkor_writers: ['lens:alpha']}),
           (a:Entity {uuid: 'at-node', name: 'amber at', group_id: 'g', summary: 'amber', created_at: '2026-06-01T00:00:00+00:00', _gralkor_writers: ['lens:alpha']}),
           (n:Entity {uuid: 'new-node', name: 'amber new', group_id: 'g', summary: 'amber', created_at: '2026-06-03T00:00:00.250000+00:00', _gralkor_writers: ['lens:beta']}),
           (o)-[:RELATES_TO {uuid: 'old-edge', name: 'OWNS', fact: 'amber amber amber old', group_id: 'g', episodes: ['old-ep'], created_at: '2026-01-01T00:00:00+00:00', _gralkor_writers: ['lens:alpha']}]->(o),
           (a)-[:RELATES_TO {uuid: 'at-edge', name: 'OWNS', fact: 'amber at', group_id: 'g', episodes: ['at-ep'], created_at: '2026-06-01T00:00:00+00:00', _gralkor_writers: ['lens:alpha']}]->(a),
           (n)-[:RELATES_TO {uuid: 'new-edge', name: 'OWNS', fact: 'amber new', group_id: 'g', episodes: ['new-ep'], created_at: '2026-06-03T00:00:00.250000+00:00', _gralkor_writers: ['lens:beta']}]->(n)
    """)

    %{instance: instance}
  end

  describe "when a memory search is run for a group > when the query exceeds the graph library's full-text limit" do
    test "then the graph library receives a bounded non-empty query containing the earliest supported terms" do
      query = Enum.map_join(1..100, " ", &"term#{&1}")
      {_results, recorded} = memory_search_result(query: query)

      assert recorded["query"] != ""
      assert recorded["query"] =~ "term1 term2 term3"
      assert length(String.split(recorded["query"])) <= 63
      refute recorded["query"] =~ "term100"
    end
  end

  describe "when a memory search is run for a group > when a returned Reflection episode lacks its durable extraction-completion marker" do
    test "then that episode is excluded before the episode limit is applied" do
      {results, _recorded} =
        memory_search_result(reflections: true, limits: %{facts: 1, nodes: 1, episodes: 2})

      assert Enum.map(results.episodes, & &1.content) == [
               ~s({"id":"complete","payload":{}}),
               "commit 1 touched parse"
             ]
    end
  end

  describe "if running a memory search raises inside the graph library" do
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

      assert {:error, {:python, message}} =
               GraphitiPool.search_memory(pid, "g1", "q", %{facts: 5, nodes: 5, episodes: 5})

      assert message =~ "boom"

      GenServer.stop(pid)
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph's vector index for those embeddings is built" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph]

    test "then the vector index is asked for many more of the nearest facts or entities than the search keeps",
         %{instance: instance} do
      found =
        similarity_run(instance, """
        async def run():
            facts, fact_sent = await recorded(lambda: search('fact', SearchFilters(), 4, 0.6))
            entities, entity_sent = await recorded(lambda: search('entity', SearchFilters(), 4, 0.6))
            return {'k': search_utils._gralkor_nearest_count(4), 'sent': fact_sent + entity_sent}
        run()
        """)

      lookups = Enum.filter(found["sent"], &(&1["cypher"] =~ "db.idx.vector"))
      assert Enum.map(lookups, &(&1["cypher"] =~ "queryRelationships")) == [true, false]
      assert Enum.at(lookups, 1)["cypher"] =~ "queryNodes"

      for lookup <- lookups do
        assert lookup["gralkor_k"] == found["k"]
        assert lookup["gralkor_k"] > lookup["limit"]
      end
    end

    test "and the group, the graph library's own filters, the included and excluded writers, and the earliest creation time are applied to what the vector index gives, inside the same query, before the search's limit",
         context do
      assert_group_graph_librarys_own_filters_included_excluded_writers_e(context)
    end

    test "and each result is scored as the graph library scores it, and only results scoring above the search's minimum are kept, best first",
         context do
      assert_each_result_scored_as_graph_library_scores_it_only_results_s(context)
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph's vector index for those embeddings is built > where at least as many results pass as the search keeps > while the vector index gave fewer candidates than it was asked for, or the last result kept is within the nearest share of the candidates it gave" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph, :seed_deep_vector_graph]

    test "then no stored embedding is compared with the search's outside the vector index",
         context do
      assert_no_stored_embedding_compared_with_searchs_outside_vector_ind(context)
    end

    test "and the search returns as many results as the graph library's own query returns under the same restrictions",
         context do
      assert_search_returns_as_many_results_as_graph_librarys_own_query_r(context)
    end

    test "and every result scores at least as high as the lowest-scoring result of the graph library's own query, as long as the vector index gives the truly nearest candidates",
         context do
      assert_every_result_scores_at_least_as_high_as_lowestscoring_result(context)
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph's vector index for those embeddings is built > where at least as many results pass as the search keeps > while the vector index gave every candidate it was asked for and the last result kept lies beyond the nearest share of them" do
    setup [:start_real_embedded_pool, :seed_deep_vector_graph]

    test "then the search answers with the graph library's own query under the same restrictions",
         context do
      assert_deep_beyond_share_sends_own_query(context)
    end

    test "and returns what that query returns", context do
      assert_deep_beyond_share_returns_own_results(context)
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph's vector index for those embeddings is built > where fewer results pass than the search keeps > while the vector index gave every candidate it was asked for, every candidate scoring above the search's minimum is within the nearest share of them, and at least one result passed" do
    setup [:start_real_embedded_pool, :seed_crowded_vector_graph]

    test "then the results that passed are returned", context do
      assert_results_that_passed_are_returned(context)
    end

    test "and the graph library's own query is not sent", context do
      assert_graph_librarys_own_query_not_sent(context)
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph's vector index for those embeddings is built > where fewer results pass than the search keeps > while a candidate beyond the nearest share scores above the search's minimum, the vector index gave fewer candidates than it was asked for, or no result passed" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph, :seed_deep_vector_graph]

    test "then the search answers with the graph library's own query under the same restrictions, through the creation-time index when an earliest creation time is supplied to a fact search",
         context do
      assert_search_answers_with_graph_librarys_own_query_under_same_rest(context)
    end

    test "and returns as many results as that query does", context do
      assert_returns_as_many_results_as_that_query_does(context)
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph's vector index for those embeddings is built > while writers are included and few of the graph's facts are theirs" do
    setup [:start_real_embedded_pool, :seed_distant_writer_graph]

    test "then the fact search returns as many results as the graph library's own query returns under the same restrictions",
         context do
      assert_fact_search_returns_as_many_results_as_graph_librarys_own_qu(context)
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph's vector index for those embeddings is built > while writers are included and few of the graph's entities are theirs" do
    setup [:start_real_embedded_pool, :seed_distant_writer_graph]

    test "then the entity search returns as many results as the graph library's own query returns under the same restrictions",
         context do
      assert_entity_search_returns_as_many_results_as_graph_librarys_own(context)
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph's vector index for those embeddings is built > when the vector index is dropped > while the search reads that the vector index is no longer there" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph]

    test "then the search answers with the graph library's own query", context do
      assert_dropped_search_sends_own_query(context)
    end

    test "and the vector index is not asked", context do
      assert_dropped_search_asks_no_index(context)
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph's vector index for those embeddings is built > when the vector index is dropped > while the search reads that the vector index is still built > when the vector index refuses the search's lookup because it is gone" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph]

    test "then the search answers with the graph library's own query under the same restrictions, through the creation-time index when an earliest creation time is supplied to a fact search",
         context do
      assert_vanished_search_answers_with_own_query(context)
    end

    test "and the graph library's own query is sent once", context do
      assert_vanished_search_sends_own_query_once(context)
    end

    test "and the graph library's own query carries the search's query timeout", context do
      assert_vanished_search_own_query_carries_timeout(context)
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph's vector index for those embeddings is built > if the vector index lookup fails for any reason but the index being gone" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph]

    test "then the search fails with that failure", context do
      assert_failed_lookup_fails_search(context)
    end

    test "and the graph library's own query is not sent", context do
      assert_failed_lookup_sends_no_own_query(context)
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph's vector index for those embeddings is built but compares by another similarity than cosine, or at another dimension than the search's embedding" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph]

    test "then the search fails, naming the graph, the index, its similarity and dimension, and how to replace it",
         context do
      assert_mismatched_search_fails_naming_index(context)
    end

    test "and the vector index is not asked", context do
      assert_mismatched_search_asks_no_index(context)
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph's vector index for those embeddings is still being built" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph]

    test "then the search answers with the graph library's own query", %{instance: instance} do
      found = building_search(instance)

      for kind <- ["fact", "entity"] do
        assert [status, own] = found[kind]["sent"]
        assert status =~ "CALL db.indexes()"
        assert own =~ "vec.cosineDistance"
        assert found[kind]["wrapped"] == found[kind]["own"]
      end
    end

    test "and the vector index is not asked", %{instance: instance} do
      found = building_search(instance)

      for kind <- ["fact", "entity"] do
        refute Enum.any?(found[kind]["sent"], &(&1 =~ "db.idx.vector"))
      end
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > while the graph has no vector index for those embeddings" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph]

    test "then the search answers with the graph library's own query", %{instance: instance} do
      found = unindexed_search(instance)

      for kind <- ["fact", "entity"] do
        assert [status, own] = found[kind]["sent"]
        assert status =~ "CALL db.indexes()"
        assert own =~ "vec.cosineDistance"
        assert found[kind]["wrapped"] == found[kind]["own"]
        assert length(found[kind]["wrapped"]) == 4
      end
    end

    test "and the vector index is not asked", %{instance: instance} do
      found = unindexed_search(instance)

      for kind <- ["fact", "entity"] do
        refute Enum.any?(found[kind]["sent"], &(&1 =~ "db.idx.vector"))
      end
    end
  end

  describe "when a fact or entity similarity search runs on FalkorDB > where a fact search names the facts it may return, or the entities at either end of the facts it may return" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph]

    test "then the search answers with the graph library's own query", %{instance: instance} do
      for found <- naming_searches(instance) do
        assert [own] = found["sent"]
        assert own =~ "vec.cosineDistance"
        assert found["wrapped"] == found["own"]
      end
    end

    test "and neither the vector index nor whether it is built is read", %{instance: instance} do
      for found <- naming_searches(instance) do
        refute Enum.any?(found["sent"], &(&1 =~ "db.idx.vector" or &1 =~ "db.indexes"))
      end
    end
  end

  describe "when adding an episode looks for entities that may duplicate an extracted entity > while the entity vector index is built" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph]

    test "then the candidates come from the entity vector index, as every other entity similarity search's do",
         %{instance: instance} do
      found =
        similarity_run(instance, """
        import graphiti_core.utils.maintenance.node_operations as node_operations
        async def run():
            nodes, sent = await recorded(lambda: node_operations.node_similarity_search(
                g.driver, QUERY, SearchFilters(), ['g'], 15, 0.6))
            return {'nodes': [node.uuid for node in nodes], 'sent': [entry['cypher'] for entry in sent]}
        run()
        """)

      assert length(found["nodes"]) == 15
      assert [lookup] = Enum.filter(found["sent"], &(&1 =~ "db.idx.vector"))
      assert lookup =~ "queryNodes"
      assert lookup =~ "n.group_id IN $group_ids"
      refute Enum.any?(found["sent"], &(&1 =~ "vec.cosineDistance"))
    end
  end

  describe "when adding an episode looks for facts a new fact may invalidate > while the fact vector index is built" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph]

    test "then the candidates come from the fact vector index", %{instance: instance} do
      found = ingestion_fact_search(instance, "SearchFilters()")

      assert [lookup] = Enum.filter(found, &(&1 =~ "db.idx.vector"))
      assert lookup =~ "queryRelationships"
      assert lookup =~ "e.group_id IN $group_ids"
      refute Enum.any?(found, &(&1 =~ "vec.cosineDistance"))
    end
  end

  describe "when the graph library reads facts by identifier, loads a fact's embedding, or deletes relationships by identifier on FalkorDB" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph, :seed_mentions]

    test "then it finds them through the identifier index, without reading every entity", %{
      instance: instance
    } do
      found = identifier_operations(instance)

      assert length(found["plans"]) == 5

      for plan <- found["plans"] do
        refute plan =~ "Label Scan"
        refute plan =~ "All Node Scan"
        assert plan =~ "Edge By Index Scan"
      end
    end

    test "and it reads, loads, or deletes exactly what the graph library's own query does", %{
      instance: instance
    } do
      found = identifier_operations(instance)

      assert found["read"] == found["own_read"]
      assert length(found["read"]) == 3
      assert found["loaded"] == found["own_loaded"]
      assert found["missing"] == "EdgeNotFoundError"
      assert found["own_missing"] == "EdgeNotFoundError"
      assert found["left_by_own"] == found["left"] -- found["deleted_by_own"]
      assert found["left"] == found["before"] -- found["deleted"]
    end
  end

  describe "when adding an episode looks for facts that duplicate a new fact between the same two entities" do
    setup [:start_real_embedded_pool, :seed_standard_vector_graph]

    test "then the candidates are compared as the graph library's own query compares them, without the vector index",
         %{instance: instance} do
      found =
        ingestion_fact_search(
          instance,
          "SearchFilters(edge_source_node_uuids=['s0', 't0'], edge_target_node_uuids=['s0', 't0'])"
        )

      assert Enum.any?(found, &(&1 =~ "vec.cosineDistance"))
      refute Enum.any?(found, &(&1 =~ "db.idx.vector" or &1 =~ "db.indexes"))
    end
  end

  @similarity_python """
  import math
  import random
  from datetime import datetime, timedelta, timezone
  import graphiti_core.search.search as search_module
  import graphiti_core.search.search_utils as search_utils
  from graphiti_core.search.search_filters import SearchFilters, DateFilter, ComparisonOperator

  Filters = search_utils._gralkor_search_filters
  QUERY = [1.0, 0.0, 0.0]

  async def recorded(call):
      sent = []
      previous = g.driver.__dict__.get('execute_query')
      original = g.driver.execute_query
      async def recording(cypher, **params):
          params.pop('routing_', None)
          sent.append({'cypher': cypher, **{key: value for key, value in params.items() if key != 'search_vector'}})
          return await original(cypher, **params)
      g.driver.execute_query = recording
      try:
          result = await call()
      finally:
          if previous is None:
              del g.driver.execute_query
          else:
              g.driver.execute_query = previous
      return result, sent

  async def search(kind, restriction, limit, min_score, group_ids=None, wrapped=True, vector=QUERY):
      if kind == 'fact':
          function = search_module.edge_similarity_search
          function = function if wrapped else function._gralkor_original
          found = await function(g.driver, vector, None, None, restriction, group_ids, limit, min_score)
      else:
          function = search_module.node_similarity_search
          function = function if wrapped else function._gralkor_original
          found = await function(g.driver, vector, restriction, group_ids, limit, min_score)
      return [record.uuid for record in found]

  async def scores(kind, uuids, vector=QUERY):
      match = 'MATCH ()-[e:RELATES_TO]->() WHERE e.uuid IN $uuids RETURN e.uuid AS uuid, (2 - vec.cosineDistance(e.fact_embedding, vecf32($vector)))/2 AS score'
      if kind == 'entity':
          match = 'MATCH (e:Entity) WHERE e.uuid IN $uuids RETURN e.uuid AS uuid, (2 - vec.cosineDistance(e.name_embedding, vecf32($vector)))/2 AS score'
      records, _, _ = await g.driver.execute_query(match, uuids=uuids, vector=vector)
      by_uuid = {record['uuid']: record['score'] for record in records}
      return [by_uuid[uuid] for uuid in uuids]

  async def all_scores(kind, vector=QUERY):
      match = 'MATCH ()-[e:RELATES_TO]->() RETURN (2 - vec.cosineDistance(e.fact_embedding, vecf32($vector)))/2 AS score'
      if kind == 'entity':
          match = 'MATCH (e:Entity) RETURN (2 - vec.cosineDistance(e.name_embedding, vecf32($vector)))/2 AS score'
      records, _, _ = await g.driver.execute_query(match, vector=vector)
      return [record['score'] for record in records]

  async def fact_rows(uuids):
      records, _, _ = await g.driver.execute_query(
          'MATCH ()-[e:RELATES_TO]->() WHERE e.uuid IN $uuids '
          'RETURN e.uuid AS uuid, e.group_id AS group_id, e.name AS name, e._gralkor_writers AS writers, e.created_at AS created_at',
          uuids=uuids,
      )
      return records

  async def compare(kind, restriction, limit, min_score, group_ids=None):
      wrapped, sent = await recorded(lambda: search(kind, restriction, limit, min_score, group_ids))
      own = await search(kind, restriction, limit, min_score, group_ids, wrapped=False)
      return {
          'wrapped': wrapped,
          'own': own,
          'wrapped_scores': await scores(kind, wrapped),
          'own_scores': await scores(kind, own),
          'sent': [entry['cypher'] for entry in sent],
      }
  """

  @vector_seeding """
  import math
  import random
  from datetime import datetime, timedelta, timezone

  def at_cosine(cosine, rng):
      angle = rng.uniform(0, 2 * math.pi)
      side = math.sqrt(max(0.0, 1 - cosine * cosine))
      return [cosine, side * math.cos(angle), side * math.sin(angle)]

  def moment(day):
      return (datetime(2026, 1, 1, tzinfo=timezone.utc) + timedelta(days=day)).isoformat()

  async def write(entities, facts):
      for start in range(0, len(entities), 500):
          await g.driver.execute_query(
              'UNWIND $rows AS r CREATE (n:Entity {uuid: r.uuid, name: r.uuid, group_id: r.group_id, summary: r.uuid, '
              'created_at: r.created_at, _gralkor_writers: r.writers, kind: r.kind}) '
              'SET n.name_embedding = vecf32(r.vector)',
              rows=entities[start:start + 500],
          )
      for kind in ('Person', 'Team'):
          await g.driver.execute_query('MATCH (n:Entity {kind: $kind}) SET n:' + kind, kind=kind)
      for start in range(0, len(facts), 500):
          await g.driver.execute_query(
              'UNWIND $rows AS r MATCH (a:Entity {uuid: r.source}), (b:Entity {uuid: r.target}) '
              'CREATE (a)-[e:RELATES_TO {uuid: r.uuid, name: r.name, fact: r.uuid, group_id: r.group_id, episodes: [], '
              'created_at: r.created_at, valid_at: r.valid_at, _gralkor_writers: r.writers}]->(b) '
              'SET e.fact_embedding = vecf32(r.vector), e.invalid_at = r.invalid_at, e.expired_at = r.expired_at',
              rows=facts[start:start + 500],
          )

  def fact(uuid, source, target, vector, writers, day=0, name='OWNS', group_id='g', invalid_at=None, expired_at=None):
      return {
          'uuid': uuid, 'source': source, 'target': target, 'vector': vector, 'writers': writers, 'name': name,
          'group_id': group_id, 'created_at': moment(day), 'valid_at': moment(day), 'invalid_at': invalid_at,
          'expired_at': expired_at,
      }

  def entity(uuid, vector, writers, day=0, kind='Person', group_id='g'):
      return {'uuid': uuid, 'vector': vector, 'writers': writers, 'created_at': moment(day), 'kind': kind, 'group_id': group_id}

  WRITERS = [['lens:alpha'], ['lens:beta'], ['direct'], ['reflection:review'], ['lens:alpha', 'direct']]
  """

  # Runs Python that the similarity prelude makes able to search the instance's
  # graph as the started pool wraps it and as the graph library does, and to
  # record what every search sends.
  defp similarity_run(instance, code) do
    (@similarity_python <> code)
    |> Gralkor.Python.run_coroutine(%{"g" => instance})
    |> Pythonx.decode()
  end

  defp seed_vectors(instance, code) do
    (@vector_seeding <> code)
    |> Gralkor.Python.run_coroutine(%{"g" => instance})
    |> Pythonx.decode()

    assert eventually(fn -> vector_indexes_built?(instance) end)
  end

  defp vector_indexes_built?(instance) do
    instance
    |> graph_query(
      "CALL db.indexes() YIELD label, types, status WHERE label IN ['RELATES_TO', 'Entity'] RETURN label, types, status"
    )
    |> Enum.filter(fn index -> Enum.any?(Map.values(index["types"]), &("VECTOR" in &1)) end)
    |> then(
      &(length(&1) == 2 and Enum.all?(&1, fn index -> index["status"] == "OPERATIONAL" end))
    )
  end

  # Fifty facts, each between an entity `s<i>` and an entity `t<i>`, whose
  # embeddings are ever farther from the query vector [1, 0, 0] as `i` grows,
  # with relationship names, groups, labels, writers, and times that vary with `i`.
  defp seed_standard_vector_graph(%{pid: pid}) do
    instance = GraphitiPool.for(pid, "vectors")

    seed_vectors(instance, """
    async def seed():
        rng = random.Random(8)
        entities = []
        facts = []
        for i in range(50):
            writers = WRITERS[i % 5]
            group_id = 'h' if i % 7 == 0 else 'g'
            entities.append(entity('s' + str(i), at_cosine(0.95 - i * 0.006, rng), writers, i, 'Person' if i % 2 == 0 else 'Team', group_id))
            entities.append(entity('t' + str(i), at_cosine(0.947 - i * 0.006, rng), writers, i, 'Person' if i % 3 else 'Team', group_id))
            facts.append(fact(
                'f' + str(i), 's' + str(i), 't' + str(i), at_cosine(0.95 - i * 0.012, rng), writers, i,
                'OWNS' if i % 2 == 0 else 'KNOWS', group_id,
                moment(i + 10) if i % 3 == 0 else None, moment(i + 5) if i % 4 == 0 else None,
            ))
        await write(entities, facts)
    seed()
    """)

    %{instance: instance}
  end

  # As many facts as the vector index is asked for when a search keeps four,
  # and ten more, all far from the query vector but two equal to it.
  defp seed_crowded_vector_graph(%{pid: pid}) do
    instance = GraphitiPool.for(pid, "crowded")

    seed_vectors(instance, """
    import graphiti_core.search.search_utils as search_utils
    async def seed():
        rng = random.Random(9)
        entities = [entity('pool' + str(i), at_cosine(-0.5, rng), ['unknown']) for i in range(20)]
        facts = [
            fact('far-' + str(i), 'pool' + str(i % 20), 'pool' + str((i + 1) % 20), at_cosine(rng.uniform(-0.9, 0.4), rng), ['lens:alpha'])
            for i in range(search_utils._gralkor_nearest_count(4) + 8)
        ]
        facts += [fact('exact-' + str(i), 'pool0', 'pool1', [1.0, 0.0, 0.0], ['lens:alpha']) for i in (1, 2)]
        await write(entities, facts)
    seed()
    """)

    %{instance: instance}
  end

  # Ten more facts and entities than the vector index is asked for when a search
  # keeps four, ever farther from the query vector, all scoring above 0.6 but
  # the farthest; four of each, by `lens:rare`, lie beyond the nearest share
  # of the candidates the vector index gives.
  defp seed_deep_vector_graph(%{pid: pid}) do
    instance = GraphitiPool.for(pid, "deep")

    seed_vectors(instance, """
    import graphiti_core.search.search_utils as search_utils
    async def seed():
        rng = random.Random(11)
        count = search_utils._gralkor_nearest_count(4) + 10
        middle = (search_utils._gralkor_trusted_count(4) + search_utils._gralkor_nearest_count(4)) // 2
        step = 0.8 / count
        def writers(i):
            return ['lens:rare'] if middle <= i < middle + 4 else ['lens:alpha']
        entities = [entity('e' + str(i), at_cosine(0.99 - i * step, rng), writers(i)) for i in range(count)]
        facts = [fact('f' + str(i), 'e' + str(i), 'e' + str(i), at_cosine(0.99 - i * step, rng), writers(i)) for i in range(count)]
        await write(entities, facts)
    seed()
    """)

    %{deep: instance}
  end

  # As many facts and entities by `lens:near` near the query vector as the
  # vector index is asked for when a search keeps four, and four more, and four
  # facts and entities by `lens:far`, farthest from it but still scoring above
  # the search's minimum.
  defp seed_distant_writer_graph(%{pid: pid}) do
    instance = GraphitiPool.for(pid, "distant")

    seed_vectors(instance, """
    import graphiti_core.search.search_utils as search_utils
    async def seed():
        rng = random.Random(10)
        near = search_utils._gralkor_nearest_count(4) + 4
        entities = [entity('near-' + str(i), at_cosine(rng.uniform(0.9, 1.0), rng), ['lens:near']) for i in range(near)]
        entities += [entity('far-' + str(i), at_cosine(0.3, rng), ['lens:far']) for i in range(4)]
        facts = [fact('near-fact-' + str(i), 'near-' + str(i), 'near-' + str(i), at_cosine(rng.uniform(0.9, 1.0), rng), ['lens:near']) for i in range(near)]
        facts += [fact('far-fact-' + str(i), 'far-' + str(i), 'far-' + str(i), at_cosine(0.3, rng), ['lens:far']) for i in range(4)]
        await write(entities, facts)
    seed()
    """)

    %{instance: instance}
  end

  defp seed_mentions(%{instance: instance}) do
    graph_query(instance, """
    CREATE (ep:Episodic {uuid: 'ep', group_id: 'g'})
    WITH ep
    MATCH (n:Entity) WHERE n.uuid IN ['s1', 's2', 's3']
    CREATE (ep)-[:MENTIONS {uuid: 'mention-' + n.uuid, group_id: 'g'}]->(n)
    """)

    :ok
  end

  # Reads, loads, and deletes facts and relationships by identifier as the
  # started pool wraps the graph library, recording each query the wrapped
  # forms send and FalkorDB's plan for it, and does the same with the graph
  # library's own forms.
  defp identifier_operations(instance) do
    similarity_run(instance, """
    import graphiti_core.edges as edges_module
    from graphiti_core.errors import EdgeNotFoundError
    EntityEdge = edges_module.EntityEdge
    Edge = edges_module.Edge

    async def relationships():
        records, _, _ = await g.driver.execute_query('MATCH ()-[e]->() RETURN e.uuid AS uuid ORDER BY uuid')
        return [record['uuid'] for record in records]

    def dumped(edges):
        return sorted((edge.model_dump(mode='json') for edge in edges), key=lambda edge: edge['uuid'])

    async def missing(load, edge):
        try:
            await load(edge, g.driver)
        except EdgeNotFoundError as error:
            return type(error).__name__

    async def run():
        driver = g.driver
        identifiers = ['f1', 'f2', 'f3', 'absent']
        read, read_sent = await recorded(lambda: EntityEdge.get_by_uuids(driver, identifiers))
        own_read = await EntityEdge.get_by_uuids._gralkor_original(driver, identifiers)
        loaded = read[0].model_copy()
        loaded.fact_embedding = None
        _, load_sent = await recorded(lambda: loaded.load_fact_embedding(driver))
        own_loaded = read[0].model_copy()
        own_loaded.fact_embedding = None
        await EntityEdge.load_fact_embedding._gralkor_original(own_loaded, driver)
        absent = read[0].model_copy(update={'uuid': 'absent'})
        before = await relationships()
        _, delete_sent = await recorded(lambda: Edge.delete_by_uuids(driver, ['f4', 'mention-s1', 'absent']))
        left = await relationships()
        await Edge.delete_by_uuids._gralkor_original(driver, ['f5', 'mention-s2'])
        left_by_own = await relationships()
        graph = driver._get_graph(driver._database)
        plans = []
        for entry in read_sent + load_sent + delete_sent:
            params = {key: value for key, value in entry.items() if key != 'cypher'}
            plans.append(str(await graph.explain(entry['cypher'], params)))
        return {
            'read': dumped(read),
            'own_read': dumped(own_read),
            'loaded': list(loaded.fact_embedding),
            'own_loaded': list(own_loaded.fact_embedding),
            'missing': await missing(EntityEdge.load_fact_embedding, absent.model_copy()),
            'own_missing': await missing(EntityEdge.load_fact_embedding._gralkor_original, absent.model_copy()),
            'before': before,
            'left': left,
            'left_by_own': left_by_own,
            'deleted': ['f4', 'mention-s1'],
            'deleted_by_own': ['f5', 'mention-s2'],
            'plans': plans,
        }
    run()
    """)
  end

  defp restriction_comparisons(instance) do
    similarity_run(instance, """
    def on(field, day):
        return {field: [[DateFilter(date=datetime(2026, 1, 1, tzinfo=timezone.utc) + timedelta(days=day), comparison_operator=ComparisonOperator.greater_than)]]}

    fact_restrictions = [
        ('none', SearchFilters(), None),
        ('one label', SearchFilters(node_labels=['Person']), None),
        ('two labels', SearchFilters(node_labels=['Person', 'Team']), None),
        ('edge types', SearchFilters(edge_types=['KNOWS']), None),
        ('valid_at', SearchFilters(**on('valid_at', 20)), None),
        ('invalid_at', SearchFilters(**on('invalid_at', 20)), None),
        ('created_at', SearchFilters(**on('created_at', 20)), None),
        ('expired_at', SearchFilters(**on('expired_at', 20)), None),
        ('group', SearchFilters(), ['h']),
        ('writers by name', Filters(writers=['reflection:review']), None),
        ('writers by prefix', Filters(writers=['lens:*']), None),
        ('excluded writers', Filters(excluded_writers=['lens:alpha']), None),
        ('since', Filters(since='2026-02-01T00:00:00Z'), None),
    ]
    entity_restrictions = [
        ('entity labels', SearchFilters(node_labels=['Team']), None),
        ('entity writers', Filters(writers=['direct']), None),
        ('entity excluded writers', Filters(excluded_writers=['lens:beta']), None),
        ('entity since', Filters(since='2026-02-01T00:00:00Z'), None),
        ('entity group', SearchFilters(), ['h']),
    ]

    async def run():
        compared = []
        for kind, restrictions in (('fact', fact_restrictions), ('entity', entity_restrictions)):
            for name, restriction, group_ids in restrictions:
                result = await compare(kind, restriction, 4, 0.6, group_ids)
                result['restriction'] = name
                compared.append(result)
        return compared
    run()
    """)
  end

  defp crowded_search(instance) do
    similarity_run(instance, """
    async def run():
        facts, sent = await recorded(lambda: search('fact', SearchFilters(), 4, 0.9))
        lookup = next(entry for entry in sent if 'db.idx.vector' in entry['cypher'])
        params = {key: value for key, value in lookup.items() if key != 'cypher'}
        records, _, _ = await g.driver.execute_query(lookup['cypher'], search_vector=QUERY, **params)
        return {
            'facts': facts,
            'sent': [entry['cypher'] for entry in sent],
            'k': search_utils._gralkor_nearest_count(4),
            'reached': records[0]['gralkor_reached'],
        }
    run()
    """)
  end

  defp fallback_searches(instance) do
    similarity_run(instance, """
    async def run():
        after_day_25 = [[DateFilter(date=datetime(2026, 1, 26, tzinfo=timezone.utc), comparison_operator=ComparisonOperator.greater_than_equal)]]
        cases = {
            'writers': ('fact', Filters(writers=['reflection:review'], edge_types=['KNOWS'], created_at=after_day_25), 0.6),
            'since': ('fact', Filters(since='2026-02-17T00:00:00Z'), 0.6),
            'none passed': ('fact', SearchFilters(), 0.99),
            'entity writers': ('entity', Filters(writers=['reflection:review'], since='2026-02-14T00:00:00Z'), 0.6),
            'fewer candidates': ('fact', SearchFilters(), 0.97),
        }
        found = {}
        for name, (kind, restriction, min_score) in cases.items():
            found[name] = await compare(kind, restriction, 4, min_score)
        return found
    run()
    """)
  end

  defp deep_fallback_searches(deep) do
    similarity_run(deep, """
    async def run():
        return {
            'beyond share': await compare('fact', Filters(writers=['lens:rare']), 5, 0.6),
            'entity beyond share': await compare('entity', Filters(writers=['lens:rare']), 5, 0.6),
        }
    run()
    """)
  end

  defp distant_writer_search(instance, kind) do
    similarity_run(instance, """
    compare('#{kind}', Filters(writers=['lens:far']), 4, 0.6)
    """)
  end

  # Searches as the started pool wraps the search while each vector index is
  # dropped until FalkorDB no longer lists it, and with `replacement` created
  # again and built, just after the search reads that it is built and before
  # the search asks it, recording what the search
  # sends and the query timeout of each query, and searches as the graph
  # library does once the index is gone.
  @vanishing_python """
  from falkordb.asyncio.graph import AsyncGraph

  READ_TIMEOUT = 4321

  async def vanishing(kind, restriction, replacement=None):
      await until_listed(kind, True)
      original = g.driver.execute_query
      async def dropping_after_status(cypher, **params):
          records = await original(cypher, **params)
          if cypher.startswith('CALL db.indexes()') and 'gralkor_label' in params:
              await original(DROPS[kind])
              await until_listed(kind, False, execute=original)
              if replacement:
                  await until_listed(kind, True, replacement, original)
          return records
      timeouts = []
      own_query = AsyncGraph._query
      async def timed(graph, q, params=None, timeout=None, read_only=False):
          timeouts.append([q, timeout])
          return await own_query(graph, q, params=params, timeout=timeout, read_only=read_only)
      AsyncGraph._query = timed
      token = search_utils._gralkor_read_timeout.set(READ_TIMEOUT)
      g.driver.execute_query = dropping_after_status
      async def call():
          try:
              return await search(kind, restriction, 4, 0.6)
          except Exception as error:
              return type(error).__name__ + ': ' + str(error)
      try:
          found, sent = await recorded(call)
      finally:
          del g.driver.execute_query
          search_utils._gralkor_read_timeout.reset(token)
          AsyncGraph._query = own_query
      result = {
          'sent': [entry['cypher'] for entry in sent],
          'own_timeouts': [timeout for q, timeout in timeouts if 'vec.cosineDistance' in q],
          'read_timeout': READ_TIMEOUT,
      }
      if isinstance(found, str):
          result['error'] = found
      else:
          result['found'] = found
          result['own'] = await search(kind, restriction, 4, 0.6, wrapped=False)
      return result
  """

  @vector_index_listing """
  import asyncio

  DROPS = {
      'fact': 'DROP VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding)',
      'entity': 'DROP VECTOR INDEX FOR (n:Entity) ON (n.name_embedding)',
  }
  CREATES = {
      'fact': "CREATE VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding) OPTIONS {dimension: 3, similarityFunction: 'cosine'}",
      'entity': "CREATE VECTOR INDEX FOR (n:Entity) ON (n.name_embedding) OPTIONS {dimension: 3, similarityFunction: 'cosine'}",
  }
  FIELDS = {'fact': ('RELATES_TO', 'fact_embedding'), 'entity': ('Entity', 'name_embedding')}

  async def until_listed(kind, built, create=None, execute=None):
      label, field = FIELDS[kind]
      execute = execute or g.driver.execute_query
      for _ in range(500):
          records, _, _ = await execute(
              'CALL db.indexes() YIELD label, types, status WHERE label = $label RETURN types, status', label=label)
          statuses = [record['status'] for record in records if 'VECTOR' in (record['types'].get(field) or [])]
          if statuses == (['OPERATIONAL'] if built else []):
              return
          if built and not statuses:
              await execute(create or CREATES[kind])
          await asyncio.sleep(0.01)
      raise RuntimeError(f'the {kind} vector index never became ' + ('built' if built else 'unlisted'))
  """

  # Drops each vector index in turn and searches once FalkorDB no longer lists
  # it: a large index is still listed as built, and still answers, for a while
  # after its drop returns.
  defp dropped_search(instance) do
    similarity_run(
      instance,
      @vector_index_listing <>
        """
        async def run():
            found = {}
            for kind in ('fact', 'entity'):
                _, before = await recorded(lambda: search(kind, SearchFilters(), 4, 0.6))
                await g.driver.execute_query(DROPS[kind])
                await until_listed(kind, False)
                results, after = await recorded(lambda: search(kind, SearchFilters(), 4, 0.6))
                found[kind] = {
                    'before': [entry['cypher'] for entry in before],
                    'after': [entry['cypher'] for entry in after],
                    'found': results,
                    'own': await search(kind, SearchFilters(), 4, 0.6, wrapped=False),
                }
            return found
        run()
        """
    )
  end

  defp vanished_searches(instance) do
    similarity_run(
      instance,
      @vector_index_listing <>
        @vanishing_python <>
        """
        async def run():
            return {
                'fact since': await vanishing('fact', Filters(since='2026-01-20T00:00:00Z', writers=['lens:*'])),
                'fact': await vanishing('fact', SearchFilters()),
                'entity': await vanishing('entity', Filters(writers=['direct'])),
            }
        run()
        """
    )
  end

  # A vector index created again at another dimension, and built, between the
  # search's status read and its lookup: FalkorDB refuses the lookup for its
  # dimension, not because the index is gone. An index still being built
  # refuses a lookup as one that is gone does, so the replacement is built
  # before the lookup.
  defp failed_lookup_searches(instance) do
    similarity_run(
      instance,
      @vector_index_listing <>
        @vanishing_python <>
        """
        async def run():
            return {
                kind: await vanishing(kind, SearchFilters(), CREATES[kind].replace('dimension: 3', 'dimension: 4'))
                for kind in ('fact', 'entity')
            }
        run()
        """
    )
  end

  defp mismatched_search(instance) do
    graph_query(instance, "DROP VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding)")
    graph_query(instance, "DROP VECTOR INDEX FOR (n:Entity) ON (n.name_embedding)")

    graph_query(
      instance,
      "CREATE VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding) OPTIONS {dimension: 3, similarityFunction: 'euclidean'}"
    )

    graph_query(
      instance,
      "CREATE VECTOR INDEX FOR (n:Entity) ON (n.name_embedding) OPTIONS {dimension: 4, similarityFunction: 'cosine'}"
    )

    assert eventually(fn -> vector_indexes_built?(instance) end)

    similarity_run(instance, """
    async def failed(kind):
        sent = []
        async def call():
            try:
                await search(kind, SearchFilters(), 4, 0.6)
            except RuntimeError as error:
                return 'RuntimeError: ' + str(error)
        error, sent = await recorded(call)
        return {'error': error, 'sent': [entry['cypher'] for entry in sent]}
    async def run():
        return {kind: await failed(kind) for kind in ('fact', 'entity')}
    run()
    """)
  end

  # Searches the deep graph for its four `lens:rare` facts and entities, which
  # lie among the candidates the vector index gives but beyond their nearest
  # share, as the started pool wraps the search and as the graph library does.
  defp deep_beyond_share(deep) do
    similarity_run(deep, """
    async def run():
        return {kind: await compare(kind, Filters(writers=['lens:rare']), 4, 0.6) for kind in ('fact', 'entity')}
    run()
    """)
  end

  defp deep_within_share(deep) do
    similarity_run(deep, """
    async def run():
        found = []
        for kind in ('fact', 'entity'):
            result = await compare(kind, SearchFilters(), 4, 0.6)
            result['restriction'] = 'deep ' + kind
            found.append(result)
        return found
    run()
    """)
  end

  defp building_search(instance) do
    similarity_run(instance, """
    def building(field):
        return [
            {'types': {'uuid': ['RANGE'], field: ['VECTOR']}, 'options': {'uuid': {}, field: {'dimension': 3, 'similarityFunction': 'cosine'}}, 'status': '[Indexing] 1/2: UNDER CONSTRUCTION'},
            {'types': {'uuid': ['RANGE']}, 'options': {'uuid': {}}, 'status': 'OPERATIONAL'},
        ]

    async def run():
        found = {}
        original = g.driver.execute_query
        async def under_construction(cypher, **params):
            if cypher.startswith('CALL db.indexes()') and 'gralkor_label' in params:
                field = 'fact_embedding' if params['gralkor_label'] == 'RELATES_TO' else 'name_embedding'
                return building(field), ['types', 'options', 'status'], None
            return await original(cypher, **params)
        for kind in ('fact', 'entity'):
            g.driver.execute_query = under_construction
            try:
                result = await compare(kind, SearchFilters(), 4, 0.6)
            finally:
                del g.driver.execute_query
            found[kind] = result
        return found
    run()
    """)
  end

  defp unindexed_search(instance) do
    similarity_run(instance, """
    async def run():
        await g.driver.execute_query('DROP VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding)')
        await g.driver.execute_query('DROP VECTOR INDEX FOR (n:Entity) ON (n.name_embedding)')
        return {kind: await compare(kind, SearchFilters(), 4, 0.6) for kind in ('fact', 'entity')}
    run()
    """)
  end

  defp naming_searches(instance) do
    similarity_run(instance, """
    async def named(restriction, source=None, target=None, group_ids=None):
        function = search_module.edge_similarity_search
        async def wrapped():
            return [e.uuid for e in await function(g.driver, QUERY, source, target, restriction, group_ids, 4, 0.6)]
        found, sent = await recorded(wrapped)
        own = [e.uuid for e in await function._gralkor_original(g.driver, QUERY, source, target, restriction, group_ids, 4, 0.6)]
        return {'wrapped': found, 'own': own, 'sent': [entry['cypher'] for entry in sent]}

    async def run():
        return [
            await named(SearchFilters(edge_uuids=['f1', 'f2', 'f3'])),
            await named(SearchFilters(edge_source_node_uuids=['s1', 't1'], edge_target_node_uuids=['s1', 't1'])),
            await named(SearchFilters(), source='s2', group_ids=['g']),
            await named(SearchFilters(), target='t2', group_ids=['g']),
        ]
    run()
    """)
  end

  defp ingestion_fact_search(instance, filter) do
    similarity_run(
      instance,
      """
      from graphiti_core.search.search_config_recipes import EDGE_HYBRID_SEARCH_RRF
      async def run():
          _, sent = await recorded(lambda: search_module.search(
              g.clients, 'amber', ['g'], EDGE_HYBRID_SEARCH_RRF.model_copy(deep=True), FILTER, query_vector=QUERY))
          return [entry['cypher'] for entry in sent]
      run()
      """
      |> String.replace("FILTER", filter)
    )
  end

  defp memory_search_outcome(options) do
    {g, _} =
      Pythonx.eval(
        """
        from datetime import datetime, timezone
        from graphiti_core.driver.driver import GraphProvider
        from graphiti_core.nodes import EpisodeType

        class _Episode:
            def __init__(self, uuid, source, source_description, content=""):
                self.uuid = uuid
                self.source = source
                self.source_description = source_description
                self.content = content

        import asyncio

        class _GraphOperations:
            async def episodic_node_get_by_uuids(self, cls, driver, uuids):
                await driver.follow_up("source episodes")
                return [driver.episodes[uuid] for uuid in uuids]

        class _EntityDriver:
            provider = GraphProvider.FALKORDB

            def __init__(self, recorded):
                self.graph_operations_interface = _GraphOperations()
                self.recorded = recorded
                self.in_flight = 0
                recorded["follow_ups"] = []
                recorded["most_in_flight"] = 0
                recorded["cancelled"] = []
                recorded["finished"] = []
                self.episodes = {
                    "episode-1": _Episode("episode-1", EpisodeType.text, "git log"),
                    "lens-episode": _Episode("lens-episode", EpisodeType.text, "notes [lens: alpha]"),
                }
                self.entities = {
                    "commit-1": "Commit 1",
                    "commit-2": "Commit 2",
                    "parse-fn": "parse/1",
                    "render-fn": "render/2",
                }
                self.writers = {"episode-1": ["direct"], "lens-episode": ["lens:alpha"]}
                self._gralkor_completed_episode_uuids = {"complete"}

            async def follow_up(self, read):
                self.recorded["follow_ups"].append(read)
                if failing is not None and read == failing.decode():
                    await asyncio.sleep(0.01)
                    if failure == b"cancelled":
                        raise asyncio.CancelledError()
                    raise TimeoutError() if failure == b"timeout" else RuntimeError(f"{read} failed")
                self.in_flight += 1
                self.recorded["most_in_flight"] = max(self.recorded["most_in_flight"], self.in_flight)
                try:
                    await asyncio.sleep(0.5 if failing else 0.05)
                except asyncio.CancelledError:
                    self.recorded["cancelled"].append(read)
                    raise
                self.recorded["finished"].append(read)
                self.in_flight -= 1

            async def execute_query(self, query, **params):
                if "_gralkor_writers AS writers" in query:
                    await self.follow_up("recorded")
                    return ([
                        {
                            "uuid": uuid,
                            "writer": None,
                            "writers": self.writers.get(uuid),
                            "complete": uuid in self._gralkor_completed_episode_uuids,
                        }
                        for uuid in params["uuids"]
                    ], None, None)
                await self.follow_up("entity names")
                return ([{"uuid": uuid, "name": self.entities[uuid]} for uuid in params["uuids"] if uuid in self.entities], None, None)

        class _Edge:
            def __init__(self, fact, name, source, target):
                self.fact = fact
                self.name = name
                self.source_node_uuid = source
                self.target_node_uuid = target
                self.created_at = datetime(2024, 1, 1, tzinfo=timezone.utc)
                self.valid_at = datetime(2024, 1, 2, tzinfo=timezone.utc)
                self.invalid_at = None
                self.expired_at = None
                self.episodes = ["episode-1", "lens-episode"] if two_writers else ["episode-1"]

        class _Node:
            def __init__(self, name, summary, attributes):
                self.name = name
                self.summary = summary
                self.attributes = attributes

        class _Results:
            def __init__(self, edges, nodes, episodes):
                self.edges = edges
                self.nodes = nodes
                self.episodes = episodes

        class _FakeGraphiti:
            def __init__(self):
                self.recorded = {"calls": 0}
                self.driver = _EntityDriver(self.recorded)

            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                self.recorded["calls"] += 1
                self.recorded["query"] = query
                self.recorded["group_ids"] = None if group_ids is None else list(group_ids)
                self.recorded["limit"] = config.limit
                self.recorded["edge_config"] = config.edge_config is not None
                self.recorded["node_config"] = config.node_config is not None
                self.recorded["episode_config"] = config.episode_config is not None
                self.recorded["community_config"] = config.community_config is not None
                self.recorded["edge_reranker"] = config.edge_config.reranker.value
                self.recorded["node_reranker"] = config.node_config.reranker.value
                self.recorded["edge_methods"] = [m.value for m in config.edge_config.search_methods]
                self.recorded["node_methods"] = [m.value for m in config.node_config.search_methods]
                self.recorded["episode_methods"] = [m.value for m in config.episode_config.search_methods]
                self.recorded["node_labels"] = search_filter.node_labels
                self.recorded["edge_types"] = search_filter.edge_types
                self.recorded["edge_uuids"] = search_filter.edge_uuids
                self.recorded["filter_class"] = type(search_filter).__name__
                self.recorded["writers"] = getattr(search_filter, "writers", None)
                self.recorded["excluded_writers"] = getattr(search_filter, "excluded_writers", None)
                since = getattr(search_filter, "since", None)
                self.recorded["since"] = None if since is None else since.isoformat()
                edges = [
                    _Edge("commit-1 changes parse", "CHANGES", "commit-1", "parse-fn"),
                    _Edge("commit-2 changes render", "CHANGES", "commit-2", "render-fn"),
                ] if with_edges else []
                nodes = [
                    _Node("parse/1", "parses input", {"arity": 1}),
                    _Node("render/2", "renders output", {"arity": 2}),
                ] if with_nodes else []
                episodes = [
                    _Episode("e1", EpisodeType.text, "git log", "commit 1 touched parse"),
                    _Episode("e2", EpisodeType.text, "git log", "commit 2 touched render"),
                    _Episode("e3", EpisodeType.text, "git log", "commit 3 touched lexer"),
                ]
                if with_reflections:
                    episodes = [
                        _Episode("partial", EpisodeType.json, "reflection:review", '{"id":"partial","payload":{}}'),
                        _Episode("complete", EpisodeType.json, "reflection:review", '{"id":"complete","payload":{}}'),
                    ] + episodes
                return _Results(edges, nodes, episodes)

        _FakeGraphiti()
        """,
        %{
          "with_edges" => Keyword.get(options, :edges, true),
          "with_nodes" => Keyword.get(options, :nodes, true),
          "with_reflections" => Keyword.get(options, :reflections, false),
          "two_writers" => Keyword.get(options, :two_writers, false),
          "failing" => Keyword.get(options, :failing),
          "failure" => Keyword.get(options, :failure, "runtime")
        }
      )

    test_pid = self()

    %{pid: pid} =
      start_pool(
        construct_instance: fn _db, _shared, group_id ->
          send(test_pid, {:memory_search_instance, group_id})
          g
        end,
        warmup: false,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      )

    outcome =
      GraphitiPool.search_memory(
        pid,
        "group-with-hyphens",
        Keyword.get(options, :query, "what changed parse"),
        Keyword.get(options, :limits, %{facts: 7, nodes: 7, episodes: 7}),
        Keyword.get(options, :opts, [])
      )

    recorded = recorded(g)
    Process.sleep(Keyword.get(options, :settle_ms, 0))
    settled = recorded(g)
    GenServer.stop(pid)

    {outcome, recorded, settled}
  end

  defp recorded(g) do
    {recorded, _} = Pythonx.eval("g.recorded", %{"g" => g})
    Pythonx.decode(recorded)
  end

  defp memory_search_result(options \\ []) do
    {outcome, recorded, _settled} = memory_search_outcome(options)
    assert {:ok, results} = outcome
    {results, recorded}
  end

  describe "when a graph instance is requested for a group" do
    test "then the instance is looked up from a cache shared across callers by the collision-free physical identifier encoded at this boundary" do
      counter = :counters.new(1, [])
      test_pid = self()
      first_physical = physical("with-hyphens")
      second_physical = physical("another")

      construct_instance = fn _db, _shared, group ->
        :counters.add(counter, 1, 1)
        send(test_pid, {:constructed, group})
        {:stub_graphiti, group}
      end

      %{pid: pid, table: table} = start_pool(construct_instance: construct_instance)

      a1 = GraphitiPool.for(pid, "with-hyphens")
      assert_receive {:constructed, ^first_physical}
      assert :counters.get(counter, 1) == 1
      assert a1 == {:stub_graphiti, first_physical}

      assert [{^first_physical, {:stub_graphiti, ^first_physical}}] =
               :ets.lookup(table, first_physical)

      a2 = GraphitiPool.for(pid, "with-hyphens")
      assert a2 == a1
      assert :counters.get(counter, 1) == 1

      b = GraphitiPool.for(pid, "another")
      assert_receive {:constructed, ^second_physical}
      assert :counters.get(counter, 1) == 2
      refute b == a1

      assert Enum.sort(Enum.map(:ets.tab2list(table), fn {k, _} -> k end)) ==
               Enum.sort([first_physical, second_physical])
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

      assert {:stub_graphiti, physical_group} = GraphitiPool.for(pid, "slowgroup")
      assert physical_group == physical("slowgroup")
    end
  end

  describe "when a graph instance is requested for a group > while no instance is cached for that group" do
    test "then the instance is constructed, cached, and held for the pool's lifetime" do
      construction_count = :counters.new(1, [])
      physical_group = physical("operator-one")

      %{pid: pid, table: table} =
        start_pool(
          construct_instance: fn _db, _shared, group ->
            :counters.add(construction_count, 1, 1)
            {:instance, group}
          end
        )

      assert {:instance, ^physical_group} = GraphitiPool.for(pid, "operator-one")

      assert [{^physical_group, {:instance, ^physical_group}}] =
               :ets.lookup(table, physical_group)

      assert {:instance, ^physical_group} = GraphitiPool.for(pid, "operator-one")
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

      physical_group = physical("indexed")
      assert ^instance = GraphitiPool.for(pid, "indexed")
      assert [{^physical_group, ^instance}] = :ets.lookup(table, physical_group)

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

          physical_group = physical("best-effort")
          assert ^instance = GraphitiPool.for(pid, "best-effort")
          assert [{^physical_group, ^instance}] = :ets.lookup(table, physical_group)
          assert ^instance = GraphitiPool.for(pid, "best-effort")
        end)

      assert log =~ "build_indices_and_constraints failed (non-fatal)"
      assert log =~ "RuntimeError: index setup unavailable"
    end

    test "and the instance is still cached and returned" do
      physical_group = physical("best-effort")

      %{pid: pid, table: table} =
        start_pool(
          construct_instance: fn _db, _shared, group -> {:instance, group} end,
          initialise_instance: fn _instance -> raise "index setup unavailable" end
        )

      capture_log(fn ->
        assert {:instance, ^physical_group} = GraphitiPool.for(pid, "best-effort")
      end)

      assert [{^physical_group, {:instance, ^physical_group}}] =
               :ets.lookup(table, physical_group)
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
      first_physical = physical("with-hyphens")
      second_physical = physical("another")

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
      assert match?({:stub_graphiti, ^first_physical, {:stub_falkor_db, 1}, _}, a)

      assert [{^first_physical, ^a}] = :ets.lookup(table, first_physical)

      b = GraphitiPool.for(pid, "with-hyphens")
      assert b == a
      assert :counters.get(instance_count, 1) == 1
      assert :counters.get(falkor_db_count, 1) == 1

      c = GraphitiPool.for(pid, "another")
      assert :counters.get(instance_count, 1) == 2
      refute c == a
      assert :counters.get(falkor_db_count, 1) == 1

      assert Enum.sort(Enum.map(:ets.tab2list(table), fn {k, _} -> k end)) ==
               Enum.sort([first_physical, second_physical])
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

      construct_shared_clients = fn _spec ->
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

    test "and the graph library's node and edge filter constructors, its fact similarity search, its entity similarity search both where searching calls it and where adding an episode calls it to find an extracted entity's possible duplicates, its episode full-text search, and its fact and entity result columns are wrapped once, before any search" do
      assert_graph_librarys_node_edge_filter_constructors_fact_similarity()
    end

    test "and the graph library's reading of facts by identifier, its loading of a fact's embedding, and its deletion of relationships by identifier are wrapped once, before any graph operation" do
      unwrap_search_filters()
      refute Enum.any?(identifier_wraps(), fn [_name, _id, wrapped?] -> wrapped? end)

      %{pid: first} = start_pool([])
      wrapped = identifier_wraps()

      assert Enum.map(wrapped, &hd/1) == [
               "graphiti_core.edges.EntityEdge.get_by_uuids",
               "graphiti_core.edges.EntityEdge.load_fact_embedding",
               "graphiti_core.edges.Edge.delete_by_uuids"
             ]

      assert Enum.all?(wrapped, fn [_name, _id, wrapped?] -> wrapped? end)

      %{pid: second} = start_pool([])
      assert identifier_wraps() == wrapped

      GenServer.stop(first)
      GenServer.stop(second)
    end

    test "and the graph client's query is wrapped once, before any search, so a search can give its queries a query timeout" do
      unwrap_search_filters()
      refute graph_client_query()["wrapped"]

      %{pid: first} = start_pool([])
      wrapped = graph_client_query()
      assert wrapped["wrapped"]
      assert wrapped["read_timeout"]

      %{pid: second} = start_pool([])
      assert graph_client_query() == wrapped

      GenServer.stop(first)
      GenServer.stop(second)
    end

    test "and the graph library's FalkorDB index building is wrapped once, before any graph instance is built" do
      %{pid: first} = start_pool([])
      wrapped = wrapped_index_building()

      assert [[_id, true], [_fulltext_id, true]] = wrapped

      %{pid: second} = start_pool([])
      assert wrapped_index_building() == wrapped

      GenServer.stop(first)
      GenServer.stop(second)
    end
  end

  describe "if a graph library function the pool wraps is missing or has another signature" do
    setup do
      previous_trap_exit = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)
      :ok
    end

    test "then startup raises naming that function and the pinned graph library version" do
      version = pinned_graphiti_core_version()
      %{pid: pid} = start_pool([])
      GenServer.stop(pid)

      {reader, _} =
        Pythonx.eval(
          "import graphiti_core.search.search_utils as search_utils\nsearch_utils.get_entity_node_from_record",
          %{}
        )

      on_exit(fn ->
        Pythonx.eval(
          "import graphiti_core.search.search_utils as search_utils\nsearch_utils.get_entity_node_from_record = reader\nNone",
          %{"reader" => reader}
        )
      end)

      for {mutation, function} <- [
            {"del falkor_search_ops.node_search_filter_query_constructor",
             "graphiti_core.driver.falkordb.operations.search_ops.node_search_filter_query_constructor"},
            {"async def changed(driver, query):\n    return []\nsearch_module.episode_fulltext_search = changed",
             "graphiti_core.search.search.episode_fulltext_search"},
            {"async def changed(driver, search_vector):\n    return []\nsearch_module.edge_similarity_search = changed",
             "graphiti_core.search.search.edge_similarity_search"},
            {"async def changed(driver, search_vector):\n    return []\nsearch_module.node_similarity_search = changed",
             "graphiti_core.search.search.node_similarity_search"},
            {"del node_operations.node_similarity_search",
             "graphiti_core.utils.maintenance.node_operations.node_similarity_search"},
            {"edges_module.EntityEdge.get_by_uuids = classmethod(lambda cls, driver: None)",
             "graphiti_core.edges.EntityEdge.get_by_uuids"},
            {"edges_module.EntityEdge.load_fact_embedding = lambda self: None",
             "graphiti_core.edges.EntityEdge.load_fact_embedding"},
            {"del edges_module.Edge.delete_by_uuids", "graphiti_core.edges.Edge.delete_by_uuids"},
            {"search_utils.get_entity_edge_return_query = lambda provider: 'e.uuid AS uuid'",
             "graphiti_core.search.search_utils.get_entity_edge_return_query"},
            {"from falkordb.asyncio.graph import AsyncGraph\nasync def changed(self, q):\n    return None\nAsyncGraph.query = changed",
             "falkordb.asyncio.graph.AsyncGraph.query"},
            {"search_utils.get_entity_node_from_record = lambda record: None",
             "graphiti_core.search.search_utils.get_entity_node_from_record"}
          ] do
        unwrap_search_filters()
        Pythonx.eval(@search_filter_targets <> mutation <> "\nNone", %{})

        assert {:error, {%RuntimeError{message: message}, _stacktrace}} =
                 GraphitiPool.start_link(pool_opts([]))

        assert message =~ function
        assert message =~ "graphiti-core #{version}"
        refute Enum.any?(wrapped_search_functions(), fn [_name, _id, wrapped?] -> wrapped? end)
      end
    end
  end

  describe "when the pool starts > while every configured model spec names a supported inference provider" do
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
            construct_shared_clients: fn spec ->
              send(test_pid, {:construct_shared, spec})
              %{llm_client: nil, embedder: nil, cross_encoder: nil}
            end
          )

        assert_receive {:construct_shared, spec}
        assert Map.take(spec.llm, [:provider, :id]) == llm_model
        assert Map.take(spec.embedder, [:provider, :id]) == embedder_model
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

  describe "when the pool starts > while every configured model spec names a supported inference provider > while the role specs name different providers" do
    test "and startup completes" do
      test_pid = self()
      llm_model = %{provider: :openai, id: "gpt-4.1-mini"}
      embedder_model = %{provider: :google, id: "gemini-embedding-2-preview"}

      %{pid: pid} =
        start_pool(
          llm_model: llm_model,
          embedder_model: embedder_model,
          construct_shared_clients: fn spec ->
            send(test_pid, {:construct_shared, spec})
            %{llm_client: nil, embedder: nil, cross_encoder: nil}
          end
        )

      assert_receive {:construct_shared, spec}
      assert Map.take(spec.llm, [:provider, :id]) == llm_model
      assert Map.take(spec.embedder, [:provider, :id]) == embedder_model
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

  describe "when the pool starts > while every configured model spec names a supported inference provider > while LLM routes are configured" do
    setup do
      %{shared: shared, instance: instance} =
        constructed_clients(
          llm_model: %{provider: :openai, id: "gpt-5.4-mini"},
          llm_tuning: %{reasoning: "low"},
          llm_routes: %{
            "extract_edges" => %{model: %{provider: :google, id: "gemini-3-flash"}, tuning: %{}},
            "extract_edges.extract_timestamps" => %{
              model: %{provider: :openai, id: "gpt-5.4-nano"},
              tuning: %{reasoning: "low"}
            },
            "dedupe_nodes" => %{
              model: %{provider: :openai, id: "gpt-5.4"},
              tuning: %{max_tokens: 2048}
            },
            "summarize_nodes" => %{model: %{provider: :google, id: "gemini-3-pro"}, tuning: %{}}
          }
        )

      %{shared: shared, instance: instance}
    end

    test "then graph instances receive an LLM runtime whose default model is the LLM spec's", %{
      instance: instance
    } do
      assert python(%{"g" => instance}, "type(g.llm_runtime).__name__") == "LLMRuntime"
      assert python(%{"g" => instance}, "g.clients.llm_runtime is g.llm_runtime")
      assert python(%{"g" => instance}, "g.llm_runtime.model.id") == "gpt-5.4-mini"

      assert python(%{"g" => instance}, "type(g.llm_runtime.model.transport.client).__name__") ==
               "OpenAIClient"
    end

    test "and each routed group or prompt runs on its route's model", %{shared: shared} do
      for {prompt, model} <- [
            {"extract_edges.edge", "gemini-3-flash"},
            {"extract_edges.extract_attributes", "gemini-3-flash"},
            {"extract_edges.extract_timestamps", "gpt-5.4-nano"},
            {"dedupe_nodes.node_list", "gpt-5.4"},
            {"summarize_nodes.summarize_pair", "gemini-3-pro"},
            {"dedupe_edges.resolve_edge", "gpt-5.4-mini"}
          ] do
        assert python(%{"runtime" => shared.llm_runtime}, "runtime.resolve_model('#{prompt}').id") ==
                 model
      end
    end

    test "and routes sharing a provider and tuning share one client", %{shared: shared} do
      runtime = %{"runtime" => shared.llm_runtime}

      assert python(
               runtime,
               "runtime.resolve_model('extract_edges.extract_timestamps').transport.client is runtime.client"
             )

      assert python(
               runtime,
               "runtime.resolve_model('extract_edges.edge').transport.client is runtime.resolve_model('summarize_nodes.summarize_pair').transport.client"
             )

      refute python(
               runtime,
               "runtime.resolve_model('dedupe_nodes.node').transport.client is runtime.client"
             )

      assert python(runtime, "len({id(t.client) for t in runtime.transports})") == 3
    end

    test "and a route's tuning applies only to the prompts it routes", %{shared: shared} do
      runtime = %{"runtime" => shared.llm_runtime}

      assert python(
               runtime,
               "runtime.resolve_model('dedupe_nodes.node').transport.client.max_tokens"
             ) ==
               2048

      assert python(runtime, "runtime.client.max_tokens") ==
               python(
                 %{},
                 "from graphiti_core.llm_client.config import DEFAULT_MAX_TOKENS\nDEFAULT_MAX_TOKENS"
               )

      assert python(runtime, "runtime.client.reasoning") == "low"

      assert python(
               runtime,
               "runtime.resolve_model('dedupe_nodes.node').transport.client.reasoning"
             ) ==
               python(
                 %{},
                 "from graphiti_core.llm_client.openai_base_client import DEFAULT_REASONING\nDEFAULT_REASONING"
               )
    end
  end

  describe "when the pool starts > while every configured model spec names a supported inference provider > while no LLM routes are configured" do
    test "then graph instances receive the LLM client without an LLM runtime" do
      %{shared: shared, instance: instance} =
        constructed_clients(llm_model: %{provider: :openai, id: "gpt-5.4-mini"}, llm_routes: %{})

      assert shared.llm_runtime == nil
      assert python(%{"g" => instance}, "g.llm_runtime") == nil
      assert python(%{"g" => instance, "llm" => shared.llm_client}, "g.llm_client is llm")
      assert python(%{"g" => instance}, "g.llm_client.model") == "gpt-5.4-mini"
    end
  end

  describe "when the pool starts > while every configured model spec names a supported inference provider > while a reranker model is configured" do
    test "then the cross-encoder is built for the provider and model it names" do
      for {reranker, client} <- [
            {%{provider: :google, id: "gemini-2.5-flash-lite"}, "GeminiRerankerClient"},
            {%{provider: :openai, id: "gpt-4.1-nano"}, "OpenAIRerankerClient"}
          ] do
        %{shared: shared} =
          constructed_clients(
            llm_model: %{provider: :google, id: "gemini-3.1-flash-lite"},
            reranker_model: reranker
          )

        reranker_object = %{"reranker" => shared.cross_encoder}
        assert python(reranker_object, "type(reranker).__name__") == client
        assert python(reranker_object, "reranker.config.model") == reranker.id
      end
    end
  end

  describe "when the pool starts > while every configured model spec names a supported inference provider > while no reranker model is configured" do
    test "then the cross-encoder is built for the LLM's provider with the graph library's default reranker model" do
      for {llm, client} <- [
            {%{provider: :google, id: "gemini-3.1-flash-lite"}, "GeminiRerankerClient"},
            {%{provider: :openai, id: "gpt-5.4-mini"}, "OpenAIRerankerClient"}
          ] do
        %{shared: shared} = constructed_clients(llm_model: llm, reranker_model: nil)

        reranker_object = %{"reranker" => shared.cross_encoder}
        assert python(reranker_object, "type(reranker).__name__") == client
        assert python(reranker_object, "reranker.config.model") == nil
      end
    end
  end

  describe "when the pool starts > while every configured model spec names a supported inference provider > while an LLM tuning setting is configured" do
    test "then the LLM spec's client receives it" do
      %{shared: openai} =
        constructed_clients(
          llm_model: %{provider: :openai, id: "gpt-5.4-mini"},
          llm_tuning: %{
            temperature: 0.3,
            max_tokens: 1024,
            reasoning: "medium",
            verbosity: "high"
          }
        )

      assert python(
               %{"llm" => openai.llm_client},
               "[llm.temperature, llm.max_tokens, llm.reasoning, llm.verbosity]"
             ) == [0.3, 1024, "medium", "high"]

      %{shared: google} =
        constructed_clients(
          llm_model: %{provider: :google, id: "gemini-3.1-flash-lite"},
          llm_tuning: %{temperature: 0.7, max_tokens: 2048, thinking_budget: 256}
        )

      assert python(
               %{"llm" => google.llm_client},
               "[llm.temperature, llm.max_tokens, llm.thinking_config.thinking_budget]"
             ) == [0.7, 2048, 256]

      for budget <- [0, -1] do
        %{shared: google} =
          constructed_clients(
            llm_model: %{provider: :google, id: "gemini-3.1-flash-lite"},
            llm_tuning: %{thinking_budget: budget}
          )

        assert python(%{"llm" => google.llm_client}, "llm.thinking_config.thinking_budget") ==
                 budget
      end
    end
  end

  describe "when the pool starts > while every configured model spec names a supported inference provider > while no LLM tuning setting is configured" do
    test "then the LLM spec's client receives the graph library's default for it" do
      %{shared: openai} =
        constructed_clients(llm_model: %{provider: :openai, id: "gpt-5.5"}, llm_tuning: %{})

      assert python(%{"llm" => openai.llm_client}, """
             from graphiti_core.llm_client.config import DEFAULT_MAX_TOKENS, DEFAULT_TEMPERATURE
             from graphiti_core.llm_client.openai_base_client import DEFAULT_REASONING, DEFAULT_VERBOSITY
             [llm.temperature == DEFAULT_TEMPERATURE, llm.max_tokens == DEFAULT_MAX_TOKENS,
              llm.reasoning == DEFAULT_REASONING, llm.verbosity == DEFAULT_VERBOSITY]
             """) == [true, true, true, true]

      %{shared: google} =
        constructed_clients(
          llm_model: %{provider: :google, id: "gemini-3.1-flash-lite"},
          llm_tuning: %{}
        )

      assert python(%{"llm" => google.llm_client}, """
             from graphiti_core.llm_client.config import DEFAULT_TEMPERATURE
             [llm.temperature == DEFAULT_TEMPERATURE, llm.max_tokens is None, llm.thinking_config is None]
             """) == [true, true, true]
    end
  end

  describe "when the pool starts > while every configured model spec names a supported inference provider > while an embedder dimension is configured" do
    test "then the embedder is configured with that dimension" do
      for embedder <- [
            %{provider: :openai, id: "text-embedding-3-small"},
            %{provider: :google, id: "gemini-embedding-2-preview"}
          ] do
        %{shared: shared} = constructed_clients(embedder_model: embedder, embedder_dimension: 768)

        assert python(%{"embedder" => shared.embedder}, "embedder.config.embedding_dim") == 768
      end
    end
  end

  describe "when the pool starts > while every configured model spec names a supported inference provider > while the embedder spec names Google > while no embedder batch size is configured" do
    test "then the embedder sends one input per request" do
      %{shared: shared} =
        constructed_clients(
          embedder_model: %{provider: :google, id: "gemini-embedding-2-preview"},
          embedder_batch_size: nil
        )

      assert python(%{"embedder" => shared.embedder}, "embedder.batch_size") == 1
    end
  end

  describe "when the pool starts > while every configured model spec names a supported inference provider > while the embedder spec names Google > while an embedder batch size is configured" do
    test "then the embedder sends at most that many inputs per request" do
      %{shared: shared} =
        constructed_clients(
          embedder_model: %{provider: :google, id: "gemini-embedding-2-preview"},
          embedder_batch_size: 25
        )

      assert python(%{"embedder" => shared.embedder}, "embedder.batch_size") == 25
    end
  end

  describe "when the pool has constructed its database" do
    test "then a warmup search runs once against a throwaway query and group, paying the cold-start cost before any consumer can recall" do
      test_pid = self()

      {g, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def search(self, query, num_results=10, search_filter=None):
                  self.recorded['query'] = query
                  self.recorded['num_results'] = num_results
                  return []

          _FakeGraphiti()
          """,
          %{}
        )

      log =
        capture_log(fn ->
          %{pid: pid} =
            start_pool(
              construct_instance: fn _db, _shared, group_id ->
                send(test_pid, {:construct_instance, group_id})
                g
              end,
              warmup: true,
              install_loop_fn: &Gralkor.Python.install_async_runtime/0
            )

          assert Process.alive?(pid)
          GenServer.stop(pid)
        end)

      assert_receive {:construct_instance, "warmup"}

      {recorded, _} = Pythonx.eval("g.recorded", %{"g" => g})
      assert Pythonx.decode(recorded) == %{"query" => "warmup", "num_results" => 1}
      refute log =~ "warmup failed"
    end

    test "and a single line reporting the search and total warmup durations is logged" do
      log =
        capture_log(fn ->
          %{pid: pid} = start_pool(successful_warmup_opts())
          GenServer.stop(pid)
        end)

      assert log =~ ~r/\[gralkor\] warmup — search:\d+ \d+ms/
    end
  end

  describe "if any configured model spec names a provider that is neither OpenAI nor Google" do
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
                   construct_shared_clients: fn _spec ->
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

    test "and the failure names every configured model spec" do
      message = unsupported_provider_error() |> Exception.message()
      assert message =~ "claude-opus-5"
      assert message =~ "gemini-embedding-2-preview"
      assert message =~ "gpt-4.1-nano"
      assert message =~ "command-r"
      assert message =~ "extract_edges"
    end

    test "and the failure names the providers that are supported" do
      message = unsupported_provider_error() |> Exception.message()
      assert message =~ "openai"
      assert message =~ "google"
    end
  end

  describe "if a tuning setting is configured for a model whose provider does not accept it" do
    setup do
      previous_trap_exit = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)
      :ok
    end

    @rejected_tuning [
      {[
         llm_model: %{provider: :google, id: "gemini-3.1-flash-lite"},
         llm_tuning: %{reasoning: "low"}
       ], "GRALKOR_LLM_REASONING", ":google"},
      {[
         llm_model: %{provider: :google, id: "gemini-3.1-flash-lite"},
         llm_tuning: %{verbosity: "low"}
       ], "GRALKOR_LLM_VERBOSITY", ":google"},
      {[llm_model: %{provider: :openai, id: "gpt-5.4-mini"}, llm_tuning: %{thinking_budget: 64}],
       "GRALKOR_LLM_THINKING_BUDGET", ":openai"},
      {[
         llm_routes: %{
           "eval" => %{
             model: %{provider: :google, id: "gemini-3-flash"},
             tuning: %{reasoning: "high"}
           }
         }
       ], "reasoning", ":google"},
      {[
         embedder_model: %{provider: :openai, id: "text-embedding-3-small"},
         embedder_batch_size: 10
       ], "GRALKOR_EMBEDDER_BATCH_SIZE", ":openai"}
    ]

    defp start_pool_with_tuning(opts, test_pid) do
      defaults = [
        name: nil,
        table: :"pool_table_#{System.unique_integer([:positive])}",
        falkordb_spec: {:embedded, "/tmp/never_used"},
        llm_model: %{provider: :openai, id: "gpt-5.4-mini"},
        embedder_model: %{provider: :google, id: "gemini-embedding-2-preview"},
        reranker_model: nil,
        llm_routes: %{},
        llm_tuning: %{},
        embedder_dimension: nil,
        embedder_batch_size: nil,
        construct_shared_clients: fn _spec ->
          send(test_pid, :inference_client_construction_started)
          %{llm_client: nil, embedder: nil, cross_encoder: nil}
        end,
        construct_falkor_db: fn _ -> :stub_falkor_db end,
        construct_instance: fn _, _, group -> {:stub_graphiti, group} end,
        initialise_instance: fn _ -> :ok end,
        install_loop_fn: fn -> :ok end,
        warmup: false
      ]

      GraphitiPool.start_link(Keyword.merge(defaults, opts))
    end

    test "then startup raises before any inference client is constructed" do
      for {opts, _setting, _provider} <- @rejected_tuning do
        assert {:error, {%ArgumentError{}, _}} = start_pool_with_tuning(opts, self())
        refute_received :inference_client_construction_started
      end
    end

    test "and the failure names the setting and the model's provider" do
      for {opts, setting, provider} <- @rejected_tuning do
        assert {:error, {%ArgumentError{} = error, _}} = start_pool_with_tuning(opts, self())
        assert Exception.message(error) =~ setting
        assert Exception.message(error) =~ provider
      end

      assert {:error, {%ArgumentError{} = error, _}} =
               start_pool_with_tuning(
                 [
                   llm_routes: %{
                     "eval" => %{
                       model: %{provider: :google, id: "gemini-3-flash"},
                       tuning: %{reasoning: "high"}
                     }
                   }
                 ],
                 self()
               )

      assert Exception.message(error) =~ ~s("eval")
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
        construct_shared_clients: fn _spec ->
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

      google = %{provider: :google, id: "gemini-3.1-flash-lite"}
      google_embedder = %{provider: :google, id: "gemini-embedding-2-preview"}
      openai = %{provider: :openai, id: "gpt-4.1-nano"}

      for {extra, role} <- [
            {[reranker_model: openai], "reranker"},
            {[llm_routes: %{"eval" => %{model: openai, tuning: %{}}}], ~s(llm route "eval")}
          ] do
        assert {:error, {%ArgumentError{} = error, _}} =
                 GraphitiPool.start_link(
                   [
                     name: nil,
                     table: :"pool_table_#{System.unique_integer([:positive])}",
                     falkordb_spec: {:embedded, "/tmp/never_used"},
                     llm_model: google,
                     embedder_model: google_embedder,
                     construct_shared_clients: fn _ ->
                       send(test_pid, :inference_client_construction_started)
                       %{llm_client: nil, embedder: nil, cross_encoder: nil}
                     end,
                     construct_falkor_db: fn _ -> :stub_falkor_db end,
                     construct_instance: fn _, _, group -> {:stub_graphiti, group} end,
                     initialise_instance: fn _ -> :ok end,
                     install_loop_fn: fn -> :ok end,
                     warmup: false
                   ] ++ extra
                 )

        assert Exception.message(error) =~ "OPENAI_API_KEY"
        assert Exception.message(error) =~ role
        refute_received :inference_client_construction_started
      end
    end
  end

  describe "where a provider is named by no configured model spec" do
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

  describe "when the pool starts > while every configured model spec names a supported inference provider > where the credential exists only in the BEAM environment" do
    test "then the BEAM-side credential lookup returns the configured value" do
      previous_openai = System.get_env("OPENAI_API_KEY")

      on_exit(fn ->
        restore_env("OPENAI_API_KEY", previous_openai)
      end)

      System.put_env("OPENAI_API_KEY", "openai-secret")
      assert GraphitiPool.api_key!(:openai) == "openai-secret"
    end

    test "and the embedded Python environment cannot read that BEAM-only value directly" do
      previous_openai = System.get_env("OPENAI_API_KEY")
      beam_only_value = "beam-only-#{System.unique_integer([:positive])}"

      on_exit(fn -> restore_env("OPENAI_API_KEY", previous_openai) end)

      System.put_env("OPENAI_API_KEY", beam_only_value)
      assert GraphitiPool.api_key!(:openai) == beam_only_value

      {seen_by_python, _} =
        Pythonx.eval(
          """
          import os
          os.environ.get('OPENAI_API_KEY', '<<ABSENT>>')
          """,
          %{}
        )

      refute Pythonx.decode(seen_by_python) == beam_only_value
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
    test "then the remote database client is closed before termination completes" do
      previous_key = System.get_env("OPENAI_API_KEY")
      System.put_env("OPENAI_API_KEY", "test-key")

      {original, _} =
        Pythonx.eval(
          """
          import falkordb.asyncio as falkor_asyncio
          from types import SimpleNamespace
          from redis.asyncio.connection import Connection
          original = falkor_asyncio.FalkorDB

          class _CloseProbe:
              def __init__(self, **kwargs):
                  self.closed = False
                  # A real client's shape: the pool the remote constructor
                  # replaces with a waiting one.
                  self.connection = SimpleNamespace(
                      connection_pool=SimpleNamespace(
                          connection_class=Connection,
                          connection_kwargs={'host': kwargs['host'], 'port': kwargs['port']},
                      )
                  )

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
          construct_shared_clients: fn _spec ->
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
    setup do
      data_dir =
        Path.join(
          System.tmp_dir!(),
          "gralkor_close_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
        )

      table = :"close_pool_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        GraphitiPool.start_link(
          name: nil,
          table: table,
          falkordb_spec: {:embedded, data_dir},
          construct_shared_clients: fn _spec ->
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
          %{pid: pid} = start_pool(failing_warmup_opts())
          GenServer.stop(pid)
        end)

      assert log =~ "[gralkor] warmup failed (non-fatal) — search:"
      assert log =~ "RuntimeError: warmup search exploded"
    end

    test "and startup completes anyway" do
      capture_log(fn ->
        %{pid: pid} = start_pool(failing_warmup_opts())
        assert Process.alive?(pid)
        GenServer.stop(pid)
      end)
    end
  end

  describe "when the pool starts > while an embedded connection is configured" do
    test "then stale embedded resume state is removed before database construction" do
      data_dir =
        Path.join(
          System.tmp_dir!(),
          "gralkor_pool_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
        )

      File.mkdir_p!(data_dir)

      stale_tmp =
        Path.join(
          System.tmp_dir!(),
          "gralkor_stale_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
        )

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

    test "and an absent data directory is created before database construction" do
      data_dir =
        Path.join([
          System.tmp_dir!(),
          "gralkor_pool_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}",
          "absent"
        ])

      refute File.exists?(data_dir)
      test_pid = self()

      construct_falkor_db = fn {:embedded, ^data_dir} ->
        send(test_pid, {:data_dir_present_at_construction, File.dir?(data_dir)})
        :stub_falkor_db
      end

      {:ok, pid} = start_embedded_pool(data_dir, construct_falkor_db: construct_falkor_db)

      assert_receive {:data_dir_present_at_construction, true}

      GenServer.stop(pid)
      File.rm_rf!(Path.dirname(data_dir))
    end

    test "and the embedded database is constructed once and held for the pool's lifetime" do
      first_physical = physical("one")
      second_physical = physical("two")

      data_dir =
        Path.join(
          System.tmp_dir!(),
          "gralkor_pool_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
        )

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
      assert {:stub_graphiti, ^first_physical} = GraphitiPool.for(pid, "one")
      assert {:stub_graphiti, ^second_physical} = GraphitiPool.for(pid, "two")
      assert :counters.get(construction_count, 1) == 1

      assert Enum.sort(:ets.tab2list(instance_databases)) ==
               Enum.sort([
                 {first_physical, :embedded_database},
                 {second_physical, :embedded_database}
               ])

      GenServer.stop(pid)
      File.rm_rf!(data_dir)
    end
  end

  describe "when an episode is added > while an ontology module is supplied" do
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
        Path.join(
          System.tmp_dir!(),
          "gralkor_pool_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
        )

      File.mkdir_p!(data_dir)

      {:ok, pid} = start_embedded_pool(data_dir)

      try do
        strict = GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)

        strict_again =
          GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)

        assert Enum.sort(Map.keys(strict)) ==
                 ["edge_type_map", "edge_types", "entity_types", "excluded_entity_types"]

        assert strict["excluded_entity_types"] == ["Entity"]

        assert strict === strict_again
      after
        GenServer.stop(pid)
        File.rm_rf!(data_dir)
      end
    end

    test "and a later add with the same ontology reuses the translated representation rather than rebuilding it" do
      data_dir =
        Path.join(
          System.tmp_dir!(),
          "gralkor_pool_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
        )

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
        Path.join(
          System.tmp_dir!(),
          "gralkor_pool_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
        )

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
        Path.join(
          System.tmp_dir!(),
          "gralkor_pool_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
        )

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

  describe "when an episode is added > while an ontology module is supplied > where an entity field declares a maximum length" do
    defmodule LongTextOntologyForGraphitiTest do
      use Gralkor.Ontology, entities: :strict, relationships: :scoped

      entity Lesson do
        field(:approach, :string, doc: "how the work was done", max_length: 1000)
        field(:outcome, :string, doc: "what came of it")
      end

      from Lesson do
        follows Lesson do
          field(:reason, :string, doc: "why one lesson follows another", max_length: 1000)
        end
      end
    end

    test "then the graph library is given that maximum length for the field" do
      with_materialised_long_text_ontology(fn dicts ->
        assert graphiti_field_max_length(
                 materialised_model(dicts, "entity_types", "Lesson"),
                 "approach"
               ) ==
                 declared_max_length(:entity_types, :approach)
      end)
    end

    test "and the schema the model fills for extraction carries no length limit for the field" do
      with_materialised_long_text_ontology(fn dicts ->
        {schema, _} =
          Pythonx.eval(
            """
            import json
            json.dumps(model.model_json_schema()["properties"]["approach"])
            """,
            %{"model" => materialised_model(dicts, "entity_types", "Lesson")}
          )

        refute Pythonx.decode(schema) =~ "maxLength"
        assert Pythonx.decode(schema) =~ "string"
      end)
    end

    test "and the graph library keeps a value longer than its default limit but within the declared length" do
      with_materialised_long_text_ontology(fn dicts ->
        default_limit = graphiti_default_attribute_limit()
        declared = declared_max_length(:entity_types, :approach)
        assert default_limit < declared

        {kept, dropped} =
          cap_attribute(
            materialised_model(dicts, "entity_types", "Lesson"),
            "approach",
            declared,
            nil,
            "overlay"
          )

        assert String.length(kept) == declared
        assert dropped == []
      end)
    end

    test "and the graph library drops a value longer than the declared length" do
      with_materialised_long_text_ontology(fn dicts ->
        declared = declared_max_length(:entity_types, :approach)

        {kept, dropped} =
          cap_attribute(
            materialised_model(dicts, "entity_types", "Lesson"),
            "approach",
            declared + 1,
            nil,
            "overlay"
          )

        assert kept == nil
        assert dropped == ["approach"]
      end)
    end

    test "and the field keeps its earlier value" do
      with_materialised_long_text_ontology(fn dicts ->
        declared = declared_max_length(:entity_types, :approach)

        {kept, _dropped} =
          cap_attribute(
            materialised_model(dicts, "entity_types", "Lesson"),
            "approach",
            declared + 1,
            "earlier approach",
            "overlay"
          )

        assert kept == "earlier approach"
      end)
    end
  end

  describe "when an episode is added > while an ontology module is supplied > where an edge property declares a maximum length" do
    test "then the graph library is given that maximum length for the property" do
      with_materialised_long_text_ontology(fn dicts ->
        assert graphiti_field_max_length(
                 materialised_model(dicts, "edge_types", "FOLLOWS"),
                 "reason"
               ) ==
                 declared_max_length(:edge_types, :reason)
      end)
    end

    test "and the graph library keeps a value longer than its default limit but within the declared length" do
      with_materialised_long_text_ontology(fn dicts ->
        default_limit = graphiti_default_attribute_limit()
        declared = declared_max_length(:edge_types, :reason)
        assert default_limit < declared

        {kept, dropped} =
          cap_attribute(
            materialised_model(dicts, "edge_types", "FOLLOWS"),
            "reason",
            declared,
            nil,
            "replace"
          )

        assert String.length(kept) == declared
        assert dropped == []
      end)
    end

    test "and the graph library drops a value longer than the declared length" do
      with_materialised_long_text_ontology(fn dicts ->
        declared = declared_max_length(:edge_types, :reason)

        {kept, dropped} =
          cap_attribute(
            materialised_model(dicts, "edge_types", "FOLLOWS"),
            "reason",
            declared + 1,
            nil,
            "replace"
          )

        assert kept == nil
        assert dropped == ["reason"]
      end)
    end

    test "and the property keeps its earlier value" do
      with_materialised_long_text_ontology(fn dicts ->
        declared = declared_max_length(:edge_types, :reason)

        {kept, _dropped} =
          cap_attribute(
            materialised_model(dicts, "edge_types", "FOLLOWS"),
            "reason",
            declared + 1,
            "earlier reason",
            "replace"
          )

        assert kept == "earlier reason"
      end)
    end
  end

  describe "when an episode is added > while an ontology module is supplied > where an optional string field declares no maximum length" do
    test "then the graph library drops a value longer than its default limit" do
      with_materialised_long_text_ontology(fn dicts ->
        default_limit = graphiti_default_attribute_limit()

        {kept, dropped} =
          cap_attribute(
            materialised_model(dicts, "entity_types", "Lesson"),
            "outcome",
            default_limit + 1,
            nil,
            "overlay"
          )

        assert kept == nil
        assert dropped == ["outcome"]
      end)
    end
  end

  defp with_materialised_long_text_ontology(fun) do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "gralkor_pool_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    File.mkdir_p!(data_dir)
    {:ok, pid} = start_embedded_pool(data_dir)

    try do
      dicts =
        GenServer.call(
          pid,
          {:materialise, Gralkor.GraphitiPoolTest.LongTextOntologyForGraphitiTest},
          :infinity
        )

      fun.(dicts)
    after
      GenServer.stop(pid)
      File.rm_rf!(data_dir)
    end
  end

  defp declared_max_length(kind, field_name) do
    [%{fields: fields}] =
      Map.fetch!(Gralkor.GraphitiPoolTest.LongTextOntologyForGraphitiTest.__ontology__(), kind)

    fields |> Enum.find(&(&1.name == field_name)) |> Map.fetch!(:max_length)
  end

  defp materialised_model(dicts, kind, type_name) do
    {model, _} =
      Pythonx.eval(
        """
        types[type_name.decode("utf-8")]
        """,
        %{"types" => Map.fetch!(dicts, kind), "type_name" => type_name}
      )

    model
  end

  defp graphiti_field_max_length(model, field_name) do
    {max_length, _} =
      Pythonx.eval(
        """
        from graphiti_core.utils.maintenance.attribute_utils import _field_max_length
        _field_max_length(model, field_name.decode("utf-8"))
        """,
        %{"model" => model, "field_name" => field_name}
      )

    Pythonx.decode(max_length)
  end

  defp graphiti_default_attribute_limit do
    {limit, _} =
      Pythonx.eval(
        """
        from graphiti_core.utils.maintenance.attribute_utils import (
            DEFAULT_ATTRIBUTE_MAX_LENGTH,
            _resolve_default_max_length,
        )
        _resolve_default_max_length(DEFAULT_ATTRIBUTE_MAX_LENGTH)
        """,
        %{}
      )

    Pythonx.decode(limit)
  end

  defp cap_attribute(model, field_name, value_length, prior, merge_mode) do
    {result, _} =
      Pythonx.eval(
        """
        from graphiti_core.utils.maintenance.attribute_utils import apply_capped_attributes

        def decode(value):
            return value.decode("utf-8") if isinstance(value, (bytes, bytearray)) else value

        name = decode(field_name)
        prior_attributes = {} if prior is None else {name: decode(prior)}
        merged, dropped = apply_capped_attributes(
            {name: "x" * value_length},
            model,
            prior_attributes,
            merge_mode=decode(merge_mode),
        )
        model(**merged)
        (merged.get(name), sorted(dropped))
        """,
        %{
          "model" => model,
          "field_name" => field_name,
          "value_length" => value_length,
          "prior" => prior,
          "merge_mode" => merge_mode
        }
      )

    Pythonx.decode(result)
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
                 reranker_model: %{provider: :openai, id: "gpt-4.1-nano"},
                 llm_routes: %{
                   "extract_edges" => %{model: %{provider: :cohere, id: "command-r"}, tuning: %{}}
                 },
                 construct_shared_clients: fn _ ->
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
            async def search(self, query, num_results=10, search_filter=None):
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

  # Builds the pool's real provider clients and one real graph instance;
  # constructing them calls no provider and the database is a stand-in.
  defp constructed_clients(opts) do
    {telemetry, _} = Pythonx.eval("import os\nos.environ.get('GRAPHITI_TELEMETRY_ENABLED')", %{})
    previous = Pythonx.decode(telemetry)

    on_exit(fn ->
      Pythonx.eval(
        "import os\nos.environ.pop('GRAPHITI_TELEMETRY_ENABLED', None) if previous is None else os.environ.__setitem__('GRAPHITI_TELEMETRY_ENABLED', previous.decode('utf-8'))",
        %{"previous" => previous}
      )
    end)

    {falkor_db, _} =
      Pythonx.eval("import os\nos.environ['GRAPHITI_TELEMETRY_ENABLED'] = 'false'\nobject()", %{})

    defaults = [
      name: nil,
      table: :"pool_table_#{System.unique_integer([:positive])}",
      falkordb_spec: {:embedded, "/tmp/never_used"},
      llm_model: %{provider: :openai, id: "gpt-5.4-mini"},
      embedder_model: %{provider: :openai, id: "text-embedding-3-small"},
      reranker_model: nil,
      llm_routes: %{},
      llm_tuning: %{},
      embedder_dimension: nil,
      embedder_batch_size: nil,
      construct_falkor_db: fn _spec -> falkor_db end,
      initialise_instance: fn _instance -> :ok end,
      install_loop_fn: fn -> :ok end,
      warmup: false
    ]

    {:ok, pid} = GraphitiPool.start_link(Keyword.merge(defaults, opts))
    instance = GraphitiPool.for(pid, "routes")
    shared = :sys.get_state(pid).shared
    GenServer.stop(pid)
    %{shared: shared, instance: instance}
  end

  defp python(globals, script) do
    {value, _} = Pythonx.eval(script, globals)
    Pythonx.decode(value)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

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
                self.episodes = []

        class _FakeGraphiti:
            async def search(self, query, num_results=10, search_filter=None):
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

  defp start_episode_identity_pool do
    {g, _} =
      Pythonx.eval(
        """
        from graphiti_core.errors import NodeNotFoundError

        class _GraphOperations:
            async def episodic_node_get_by_uuid(self, cls, driver, uuid):
                if uuid not in driver.episodes:
                    raise NodeNotFoundError(uuid)
                return driver.episodes[uuid]

            async def episodic_node_save(self, episode, driver):
                driver.episodes[episode.uuid] = episode

        class _Driver:
            def __init__(self):
                self.graph_operations_interface = _GraphOperations()
                self.episodes = {}

        class _FakeGraphiti:
            def __init__(self):
                self.driver = _Driver()
                self.extractions = 0

            async def add_episode(self, **kwargs):
                from graphiti_core.nodes import EpisodicNode
                self.extractions += 1
                episode = await EpisodicNode.get_by_uuid(self.driver, kwargs['uuid'])
                await episode.save(self.driver)

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

    {pid, g}
  end

  defp eventually(assertion, attempts \\ 100)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      true
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(_assertion, 0), do: false

  defp wrapped_index_building do
    {wrapped, _} =
      Pythonx.eval(
        """
        import graphiti_core.driver.falkordb_driver as falkordb_driver
        build = falkordb_driver.FalkorDriver.build_indices_and_constraints
        fulltext = falkordb_driver.get_fulltext_indices
        [
            [id(build), hasattr(build, '_gralkor_original')],
            [id(fulltext), hasattr(fulltext, '_gralkor_original')],
        ]
        """,
        %{}
      )

    Pythonx.decode(wrapped)
  end

  # Memory written before writers were recorded, in the `history` group's
  # database before its graph instance exists.
  defp seed_unrecorded_writer_graph(%{pid: pid}) do
    physical_graph_query(pid, "history", [
      """
      CREATE (lens:Episodic {uuid: 'lens-ep', source_description: 'notes [lens: alpha]', content: 'a'}),
             (durable:Episodic {uuid: 'durable-direct-ep', source_description: 'manual', content: 'b', _gralkor_writer: 'direct'}),
             (described:Episodic {uuid: 'described-direct-ep', source_description: 'captured [gralkor: direct]', content: 'c'}),
             (reflection:Episodic {uuid: 'reflection-ep', source_description: 'reflection:review', content: 'd'}),
             (:Episodic {uuid: 'unknown-ep', source_description: 'old notes', content: 'e'}),
             (shared:Entity {uuid: 'shared-node', name: 'shared'}),
             (direct:Entity {uuid: 'direct-node', name: 'direct'}),
             (orphan:Entity {uuid: 'orphan-node', name: 'orphan'}),
             (lens)-[:MENTIONS]->(shared),
             (reflection)-[:MENTIONS]->(shared),
             (durable)-[:MENTIONS]->(direct),
             (shared)-[:RELATES_TO {uuid: 'shared-edge', episodes: ['lens-ep', 'described-direct-ep']}]->(direct),
             (direct)-[:RELATES_TO {uuid: 'reflection-edge', episodes: ['reflection-ep', 'deleted-ep']}]->(shared),
             (orphan)-[:RELATES_TO {uuid: 'orphan-edge', episodes: []}]->(orphan)
      """
    ])

    :ok
  end

  # Memory whose writers are already recorded, deliberately unlike what its
  # provenance would name, in the `recorded` group's database.
  defp seed_recorded_writer_graph(%{pid: pid}) do
    physical_graph_query(pid, "recorded", [
      """
      CREATE (lens:Episodic {uuid: 'lens-ep', source_description: 'notes [lens: alpha]', content: 'a', _gralkor_writers: ['direct']}),
             (node:Entity {uuid: 'node', name: 'node', _gralkor_writers: ['unknown']}),
             (lens)-[:MENTIONS]->(node),
             (node)-[:RELATES_TO {uuid: 'edge', episodes: ['lens-ep'], _gralkor_writers: ['reflection:review']}]->(node)
      """
    ])

    :ok
  end

  defp capture_log_result(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:captured_result, fun.()}) end)
    assert_received {:captured_result, result}
    result
  end

  defp recorded_writers(instance, query) do
    instance
    |> graph_query(query)
    |> Map.new(&{&1["key"], &1["writers"]})
  end

  # A pool over a real embedded FalkorDB whose graph instances stand in for
  # the graph library's extraction: each episode write saves the planned
  # entities, mentions, and facts through the graph library's own bulk save,
  # every fact carrying every episode that has drawn it so far. A planned
  # stolen claim writes the episode and its entities straight into the graph, then hands the
  # claim to another owner before durable extraction completion is recorded.
  defp start_writer_recording_pool do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "gralkor_writers_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)
    test_pid = self()

    pid =
      start_supervised!(
        {GraphitiPool,
         name: nil,
         table: :"writer_pool_#{System.unique_integer([:positive])}",
         falkordb_spec: {:embedded, data_dir},
         construct_shared_clients: fn _spec ->
           %{llm_client: nil, embedder: nil, cross_encoder: nil}
         end,
         construct_instance: fn falkor_db, _shared, group_id ->
           {g, _} =
             Pythonx.eval(
               """
               from graphiti_core.driver.falkordb_driver import FalkorDriver

               class _WriterRecordingGraphiti:
                   def __init__(self, falkor_db, group_id):
                       self.driver = FalkorDriver(falkor_db=falkor_db, database=group_id)
                       self.group_id = group_id
                       self.plan = {'entities': [], 'edges': [], 'steal_claim': False}
                       self.edge_episodes = {}

                   async def add_episode(self, **kwargs):
                       from datetime import datetime, timezone
                       from graphiti_core.edges import EntityEdge, EpisodicEdge
                       from graphiti_core.graphiti import AddEpisodeResults, add_nodes_and_edges_bulk
                       from graphiti_core.nodes import EntityNode, EpisodicNode
                       now = datetime.now(timezone.utc)
                       if 'uuid' in kwargs:
                           episode = await EpisodicNode.get_by_uuid(self.driver, kwargs['uuid'])
                       else:
                           episode = EpisodicNode(
                               name=kwargs['name'],
                               group_id=self.group_id,
                               labels=[],
                               source=kwargs['source'],
                               content=kwargs['episode_body'],
                               source_description=kwargs['source_description'],
                               created_at=now,
                               valid_at=kwargs['reference_time'],
                           )
                       nodes = [
                           EntityNode(uuid=name, name=name, group_id=self.group_id, labels=['Entity'],
                                      created_at=now, name_embedding=[0.1, 0.2, 0.3])
                           for name in self.plan['entities']
                       ]
                       mentions = [
                           EpisodicEdge(uuid=f'{episode.uuid}-{node.uuid}', group_id=self.group_id,
                                        source_node_uuid=episode.uuid, target_node_uuid=node.uuid,
                                        created_at=now)
                           for node in nodes
                       ]
                       edges = []
                       for uuid, source, target in self.plan['edges']:
                           self.edge_episodes[uuid] = self.edge_episodes.get(uuid, []) + [episode.uuid]
                           edges.append(EntityEdge(
                               uuid=uuid, group_id=self.group_id, source_node_uuid=source,
                               target_node_uuid=target, created_at=now, name='RELATES', fact=uuid,
                               fact_embedding=[0.1, 0.2, 0.3], episodes=self.edge_episodes[uuid],
                           ))
                       if self.plan['steal_claim']:
                           await self.driver.execute_query(
                               '''
                               MERGE (e:Episodic {uuid: $uuid})
                               SET e.group_id = $group_id, e.content = $content, e.source = 'text',
                                   e.source_description = $source_description, e.name = $uuid,
                                   e.entity_edges = [], e.created_at = $now, e.valid_at = $now
                               WITH e
                               UNWIND $entities AS entity
                               MERGE (n:Entity {uuid: entity})
                               SET n.name = entity, n.group_id = $group_id
                               MERGE (e)-[:MENTIONS {uuid: $uuid + '-' + entity}]->(n)
                               RETURN count(n) AS mentioned
                               ''',
                               uuid=episode.uuid,
                               group_id=self.group_id,
                               content=episode.content,
                               source_description=episode.source_description,
                               now=now.isoformat(),
                               entities=[node.uuid for node in nodes],
                           )
                           await self.driver.execute_query(
                               '''
                               MATCH (c:_GralkorEpisodeClaim {uuid: $uuid})
                               SET c.owner = 'replacement-owner', c.generation = c.generation + 1
                               RETURN c.generation AS generation
                               ''',
                               uuid=episode.uuid,
                           )
                       else:
                           await add_nodes_and_edges_bulk(self.driver, [episode], mentions, nodes, edges, None)
                       return AddEpisodeResults(
                           episode=episode, episodic_edges=mentions, nodes=nodes, edges=edges,
                           communities=[], community_edges=[],
                       )

               _WriterRecordingGraphiti(falkor_db, group_id.decode('utf-8'))
               """,
               %{"falkor_db" => falkor_db, "group_id" => group_id}
             )

           send(test_pid, {:writer_recording_instance, g})
           g
         end,
         initialise_instance: fn _instance -> :ok end,
         warmup: false,
         install_loop_fn: &Gralkor.Python.install_async_runtime/0}
      )

    g = GraphitiPool.for(pid, "writers")
    assert_received {:writer_recording_instance, ^g}
    %{pid: pid, g: g}
  end

  defp plan_extraction(g, entities, edges, opts \\ []) do
    Pythonx.eval(
      """
      import json
      g.plan = json.loads(plan.decode('utf-8'))
      None
      """,
      %{
        "g" => g,
        "plan" =>
          Jason.encode!(%{
            entities: entities,
            edges: edges,
            steal_claim: Keyword.get(opts, :steal_claim, false)
          })
      }
    )
  end

  # A pool over a real embedded FalkorDB with a 4-second socket timeout whose
  # graph instances search the real graph through the graph library's own
  # full-text searches, as the pool wraps them, and may also run a slow query.
  defp start_real_searching_pool(_context) do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "gralkor_searching_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)
    test_pid = self()

    pid =
      start_supervised!(
        {GraphitiPool,
         name: nil,
         table: :"searching_pool_#{System.unique_integer([:positive])}",
         falkordb_spec: {:embedded, data_dir},
         embedded_falkordb_socket_timeout_ms: 4_000,
         construct_shared_clients: fn _spec ->
           %{llm_client: nil, embedder: nil, cross_encoder: nil}
         end,
         construct_instance: fn falkor_db, _shared, group_id ->
           {g, _} =
             Pythonx.eval(
               """
               from types import SimpleNamespace
               from graphiti_core.driver.falkordb_driver import FalkorDriver
               from graphiti_core.search.search_filters import SearchFilters
               import graphiti_core.search.search as search_module
               import graphiti_core.search.search_utils as search_utils

               class _SearchingGraphiti:
                   def __init__(self, falkor_db, group_id):
                       self.driver = FalkorDriver(falkor_db=falkor_db, database=group_id)
                       self.slow = None

                   async def build_indices_and_constraints(self):
                       await self.driver.build_indices_and_constraints()

                   async def search_(self, query, config=None, group_ids=None, search_filter=None):
                       edges = await search_utils.edge_fulltext_search(self.driver, query, search_filter, None, config.limit)
                       nodes = await search_utils.node_fulltext_search(self.driver, query, search_filter, None, config.limit)
                       episodes = await search_module.episode_fulltext_search(self.driver, query, search_filter, None, config.limit)
                       if self.slow:
                           await self.driver.execute_query(self.slow)
                       return SimpleNamespace(edges=edges, nodes=nodes, episodes=episodes)

                   async def search(self, query, num_results=10, search_filter=None):
                       return await search_utils.edge_fulltext_search(
                           self.driver, query, search_filter or SearchFilters(), None, num_results
                       )

               _SearchingGraphiti(falkor_db, group_id.decode('utf-8'))
               """,
               %{"falkor_db" => falkor_db, "group_id" => group_id}
             )

           send(test_pid, {:searching_graph, g})
           g
         end,
         warmup: false,
         install_loop_fn: &Gralkor.Python.install_async_runtime/0}
      )

    instance = GraphitiPool.for(pid, "searching")
    assert_received {:searching_graph, ^instance}

    graph_query(instance, """
    CREATE (ep:Episodic {uuid: 'amber-ep', name: 'amber', group_id: 'g', source: 'text', source_description: 'notes [lens: alpha]', content: 'amber notes', entity_edges: [], created_at: '2026-06-01T00:00:00+00:00', valid_at: '2026-06-01T00:00:00+00:00', _gralkor_writers: ['lens:alpha']}),
           (a:Entity {uuid: 'amber-node', name: 'amber node', group_id: 'g', summary: 'amber', created_at: '2026-06-01T00:00:00+00:00', _gralkor_writers: ['lens:alpha']}),
           (b:Entity {uuid: 'other-node', name: 'other node', group_id: 'g', summary: 'other', created_at: '2026-06-01T00:00:00+00:00', _gralkor_writers: ['lens:alpha']}),
           (a)-[:RELATES_TO {uuid: 'amber-edge', name: 'OWNS', fact: 'amber owns other', group_id: 'g', episodes: ['amber-ep'], created_at: '2026-06-01T00:00:00+00:00', _gralkor_writers: ['lens:alpha']}]->(b)
    """)

    %{pid: pid, instance: instance}
  end

  # Records the query timeout of every query the FalkorDB client sends until
  # the test exits.
  defp spy_query_timeouts do
    {spy, _} =
      Pythonx.eval(
        """
        from falkordb.asyncio.graph import AsyncGraph

        class _TimeoutSpy:
            def __init__(self):
                self.timeouts = []
                self.original = AsyncGraph._query
                spy = self

                async def _query(graph, q, params=None, timeout=None, read_only=False):
                    spy.timeouts.append(timeout)
                    return await spy.original(graph, q, params=params, timeout=timeout, read_only=read_only)

                AsyncGraph._query = _query

            def restore(self):
                from falkordb.asyncio.graph import AsyncGraph
                AsyncGraph._query = self.original

        _TimeoutSpy()
        """,
        %{}
      )

    on_exit(fn -> Pythonx.eval("spy.restore()", %{"spy" => spy}) end)
    spy
  end

  defp spied_timeouts(spy) do
    {timeouts, _} = Pythonx.eval("list(spy.timeouts)", %{"spy" => spy})
    Pythonx.decode(timeouts)
  end

  defp start_real_embedded_pool(_context) do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "gralkor_indexes_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    {embedder, _} =
      Pythonx.eval(
        """
        from graphiti_core.embedder.openai import OpenAIEmbedder, OpenAIEmbedderConfig
        OpenAIEmbedder(config=OpenAIEmbedderConfig(api_key='unused', base_url='http://127.0.0.1:1', embedding_dim=3))
        """,
        %{}
      )

    pid =
      start_supervised!(
        {GraphitiPool,
         name: nil,
         table: :"index_pool_#{System.unique_integer([:positive])}",
         falkordb_spec: {:embedded, data_dir},
         construct_shared_clients: fn _spec ->
           %{llm_client: nil, embedder: embedder, cross_encoder: nil}
         end,
         warmup: false,
         install_loop_fn: &Gralkor.Python.install_async_runtime/0}
      )

    %{pid: pid}
  end

  defp create_stopword_indexes(%{pid: pid}) do
    physical_graph_query(pid, "stopwords", [
      "CREATE INDEX FOR (n:Episodic) ON (n.uuid, n.group_id, n.custom)",
      "CREATE FULLTEXT INDEX FOR (n:Episodic) ON (n.content, n.source, n.group_id) OPTIONS {stopwords: ['a', 'the']}",
      "CREATE (:Episodic {uuid: 'the', content: 'the cat', source: 'notes', group_id: 'g'})"
    ])

    :ok
  end

  defp create_stopword_indexes_beside_a_vector_index(%{pid: pid}) do
    physical_graph_query(pid, "stopwords", [
      "CREATE INDEX FOR (n:Episodic) ON (n.uuid)",
      "CREATE FULLTEXT INDEX FOR (n:Episodic) ON (n.content) OPTIONS {stopwords: ['a', 'the']}",
      "CREATE VECTOR INDEX FOR (n:Episodic) ON (n.embedding) OPTIONS {dimension: 3, similarityFunction: 'euclidean'}"
    ])

    :ok
  end

  defp physical_graph_query(pid, logical_group_id, queries) do
    Gralkor.Python.run_coroutine(
      """
      async def run_queries():
          graph = database.select_graph(group_id.decode('utf-8'))
          results = []
          for query in queries:
              result = await graph.query(query.decode('utf-8'))
              header = [column[1] for column in result.header]
              results.append([dict(zip(header, row)) for row in result.result_set])
          return results
      run_queries()
      """,
      %{
        "database" => :sys.get_state(pid).falkor_db,
        "group_id" => physical(logical_group_id),
        "queries" => queries
      }
    )
    |> Pythonx.decode()
  end

  defp physical_graph_indexes(pid, logical_group_id) do
    [indexes] = physical_graph_query(pid, logical_group_id, [@index_listing])
    indexes
  end

  defp graph_query(instance, query) do
    {records, _header, _summary} =
      "g.driver.execute_query(query.decode('utf-8'))"
      |> Gralkor.Python.run_coroutine(%{"g" => instance, "query" => query})
      |> Pythonx.decode()

    records
  end

  defp graph_indexes(instance), do: graph_query(instance, @index_listing)

  defp assert_results_that_passed_are_returned(%{instance: instance}) do
    found = crowded_search(instance)

    assert Enum.sort(found["facts"]) == ["exact-1", "exact-2"]
  end

  defp assert_index_building_fails_naming_graph_index_dimension_similarity(%{pid: pid}) do
    for {group, options} <- [
          {"fresh", "{dimension: 4, similarityFunction: 'cosine'}"},
          {"euclidean", "{dimension: 3, similarityFunction: 'euclidean'}"}
        ] do
      instance = GraphitiPool.for(pid, group)
      graph_query(instance, "DROP VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding)")

      graph_query(
        instance,
        "CREATE VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding) OPTIONS " <> options
      )
    end

    assert {:error, {:vector_indexes, message}} = GraphitiPool.build_indices(pid)

    assert message =~
             "graph #{physical("fresh")}: the RELATES_TO.fact_embedding vector index compares cosine at 4 dimensions, but the embedder writes 3"

    assert message =~
             "graph #{physical("euclidean")}: the RELATES_TO.fact_embedding vector index compares euclidean at 3 dimensions, but the embedder writes 3"

    assert message =~
             "drop it with DROP VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding), wait until db.indexes() no longer lists it"
  end

  defp assert_fact_similarity_query_returns_facts_in_same_order_that_graph(%{instance: instance}) do
    compared = since_search(instance)["similarity"]

    assert Enum.map(compared, & &1["wrapped"]) == [
             ["new-edge", "at-edge"],
             ["new-edge", "at-edge", "old-edge"],
             ["new-edge", "at-edge"],
             ["at-edge"],
             ["new-edge", "at-edge"],
             ["new-edge", "at-edge"],
             []
           ]

    for %{"wrapped" => wrapped, "own" => own} <- compared, do: assert(wrapped == own)
  end

  defp assert_fact_similarity_query_finds_facts_through_creationtime_index(%{instance: instance}) do
    %{"similarity_plan" => plan} = since_search(instance)

    assert [scan] = Enum.filter(plan, &(&1 =~ "Scan"))
    assert scan =~ "Edge By Index Scan | [e:RELATES_TO]"
    assert List.last(plan) == scan
  end

  defp assert_group_graph_librarys_own_filters_included_excluded_writers_e(%{instance: instance}) do
    found =
      similarity_run(instance, """
      async def run():
          restriction = Filters(
              edge_types=['OWNS'], node_labels=['Person', 'Team'], writers=['lens:*'],
              excluded_writers=['lens:beta'], since='2026-01-05T00:00:00Z',
          )
          facts, sent = await recorded(lambda: search('fact', restriction, 4, 0.6, ['g']))
          rows = await fact_rows(facts)
          return {'facts': facts, 'rows': rows, 'sent': sent}
      run()
      """)

    [lookup] = Enum.filter(found["sent"], &(&1["cypher"] =~ "db.idx.vector"))
    cypher = lookup["cypher"]

    for clause <- [
          "e.group_id IN $group_ids",
          "e.name in $edge_types",
          "(n:Person OR n:Team) AND (m:Person OR m:Team)",
          "e._gralkor_writers",
          "e.created_at >= $gralkor_since"
        ] do
      assert cypher =~ clause
    end

    {start_node, _} = :binary.match(cypher, "startNode(e)")
    {limit, _} = :binary.match(cypher, "LIMIT $limit")

    for clause <- [
          "e.group_id IN $group_ids",
          "e._gralkor_writers",
          "e.created_at >= $gralkor_since"
        ] do
      {at, _} = :binary.match(cypher, clause)
      assert at < start_node
    end

    assert limit > start_node
    refute Enum.any?(found["sent"], &(&1["cypher"] =~ "vec.cosineDistance"))
    assert length(found["facts"]) == 4

    for row <- found["rows"] do
      assert row["group_id"] == "g"
      assert row["name"] == "OWNS"
      assert Enum.any?(row["writers"], &String.starts_with?(&1, "lens:"))
      refute row["writers"] == ["lens:beta"]
      assert row["created_at"] >= "2026-01-05"
    end

    assert_entity_lookup_applies_restrictions(instance)
  end

  defp assert_entity_lookup_applies_restrictions(instance) do
    found =
      similarity_run(instance, """
      async def run():
          restriction = Filters(
              node_labels=['Team'], writers=['lens:*'], excluded_writers=['lens:beta'],
              since='2026-01-05T00:00:00Z',
          )
          entities, sent = await recorded(lambda: search('entity', restriction, 4, 0.6, ['g']))
          own = await search('entity', restriction, 4, 0.6, ['g'], wrapped=False)
          records, _, _ = await g.driver.execute_query(
              'MATCH (n:Entity) WHERE n.uuid IN $uuids '
              'RETURN n.uuid AS uuid, labels(n) AS labels, n.group_id AS group_id, '
              'n._gralkor_writers AS writers, n.created_at AS created_at',
              uuids=entities,
          )
          return {'entities': entities, 'own': own, 'rows': records, 'sent': sent}
      run()
      """)

    [lookup] = Enum.filter(found["sent"], &(&1["cypher"] =~ "db.idx.vector"))

    for clause <- [
          "queryNodes",
          "n.group_id IN $group_ids",
          "n:Team",
          "n._gralkor_writers",
          "n.created_at >= $gralkor_since",
          "LIMIT $limit"
        ] do
      assert lookup["cypher"] =~ clause
    end

    refute Enum.any?(found["sent"], &(&1["cypher"] =~ "vec.cosineDistance"))
    assert length(found["entities"]) == 4
    assert found["entities"] == found["own"]

    for row <- found["rows"] do
      assert row["group_id"] == "g"
      assert "Team" in row["labels"]
      assert Enum.any?(row["writers"], &String.starts_with?(&1, "lens:"))
      refute row["writers"] == ["lens:beta"]
      assert row["created_at"] >= "2026-01-05"
    end
  end

  defp assert_each_result_scored_as_graph_library_scores_it_only_results_s(%{instance: instance}) do
    found =
      similarity_run(instance, """
      async def run():
          facts, sent = await recorded(lambda: search('fact', SearchFilters(), 13, 0.9))
          return {'scores': await scores('fact', facts), 'all': await all_scores('fact'), 'sent': sent}
      run()
      """)

    assert length(found["scores"]) == 13
    assert Enum.all?(found["scores"], &(&1 > 0.9))
    assert found["scores"] == Enum.sort(found["scores"], :desc)
    assert Enum.count(found["all"], &(&1 > 0.9)) == 13
    assert Enum.any?(found["all"], &(&1 <= 0.9))
    refute Enum.any?(found["sent"], &(&1["cypher"] =~ "vec.cosineDistance"))
  end

  defp assert_no_stored_embedding_compared_with_searchs_outside_vector_ind(context) do
    for compared <- answered_alone_comparisons(context) do
      assert Enum.any?(compared["sent"], &(&1 =~ "db.idx.vector")), compared["restriction"]
      refute Enum.any?(compared["sent"], &(&1 =~ "vec.cosineDistance")), compared["restriction"]
    end
  end

  defp assert_search_returns_as_many_results_as_graph_librarys_own_query_r(context) do
    for compared <- answered_alone_comparisons(context) do
      assert length(compared["wrapped"]) == length(compared["own"]), compared["restriction"]
      assert length(compared["wrapped"]) == 4, compared["restriction"]
    end
  end

  defp answered_alone_comparisons(%{instance: instance, deep: deep}) do
    restriction_comparisons(instance) ++ deep_within_share(deep)
  end

  defp assert_every_result_scores_at_least_as_high_as_lowestscoring_result(context) do
    for compared <- answered_alone_comparisons(context) do
      lowest = List.last(compared["own_scores"])

      assert Enum.all?(compared["wrapped_scores"], &(&1 >= lowest - 1.0e-6)),
             compared["restriction"]
    end
  end

  defp assert_graph_librarys_own_query_not_sent(%{instance: instance}) do
    found = crowded_search(instance)

    assert [lookup] = Enum.filter(found["sent"], &(&1 =~ "db.idx.vector"))
    assert lookup =~ "queryRelationships"
    refute Enum.any?(found["sent"], &(&1 =~ "vec.cosineDistance"))
    assert found["reached"] == found["k"]
  end

  defp assert_search_answers_with_graph_librarys_own_query_under_same_rest(%{
         instance: instance,
         deep: deep
       }) do
    found = Map.merge(fallback_searches(instance), deep_fallback_searches(deep))

    for {case_name, expected} <- [
          {"writers", "vec.cosineDistance"},
          {"since", "MATCH ()-[e:RELATES_TO]->()"},
          {"none passed", "vec.cosineDistance"},
          {"entity writers", "vec.cosineDistance"},
          {"fewer candidates", "vec.cosineDistance"},
          {"beyond share", "vec.cosineDistance"},
          {"entity beyond share", "vec.cosineDistance"}
        ] do
      [lookup, own] = Enum.reject(found[case_name]["sent"], &(&1 =~ "CALL db.indexes()"))
      assert lookup =~ "db.idx.vector", case_name
      assert own =~ expected, case_name
    end

    assert String.starts_with?(
             List.last(found["since"]["sent"]),
             "MATCH ()-[e:RELATES_TO]->()"
           )
  end

  defp assert_returns_as_many_results_as_that_query_does(%{instance: instance, deep: deep}) do
    found = Map.merge(fallback_searches(instance), deep_fallback_searches(deep))

    for case_name <- [
          "writers",
          "since",
          "none passed",
          "entity writers",
          "fewer candidates",
          "beyond share",
          "entity beyond share"
        ] do
      assert found[case_name]["wrapped"] == found[case_name]["own"], case_name
    end

    assert length(found["writers"]["wrapped"]) == 2
    assert found["none passed"]["wrapped"] == []
    assert length(found["fewer candidates"]["wrapped"]) == 1
    assert length(found["beyond share"]["wrapped"]) == 4
  end

  defp assert_fact_search_returns_as_many_results_as_graph_librarys_own_qu(%{instance: instance}) do
    compared = distant_writer_search(instance, "fact")

    assert length(compared["wrapped"]) == 4
    assert length(compared["wrapped"]) == length(compared["own"])
    lowest = List.last(compared["own_scores"])
    assert Enum.all?(compared["wrapped_scores"], &(&1 >= lowest - 1.0e-6))
  end

  defp assert_entity_search_returns_as_many_results_as_graph_librarys_own(%{instance: instance}) do
    compared = distant_writer_search(instance, "entity")

    assert length(compared["wrapped"]) == 4
    assert length(compared["wrapped"]) == length(compared["own"])
    lowest = List.last(compared["own_scores"])
    assert Enum.all?(compared["wrapped_scores"], &(&1 >= lowest - 1.0e-6))
  end

  defp assert_graph_librarys_node_edge_filter_constructors_fact_similarity do
    unwrap_search_filters()
    refute Enum.any?(wrapped_search_functions(), fn [_name, _id, wrapped?] -> wrapped? end)

    %{pid: first} = start_pool([])
    wrapped = wrapped_search_functions()

    assert Enum.map(wrapped, &hd/1) == [
             "graphiti_core.search.search_utils.node_search_filter_query_constructor",
             "graphiti_core.search.search_utils.edge_search_filter_query_constructor",
             "graphiti_core.driver.falkordb.operations.search_ops.node_search_filter_query_constructor",
             "graphiti_core.driver.falkordb.operations.search_ops.edge_search_filter_query_constructor",
             "graphiti_core.search.search.episode_fulltext_search",
             "graphiti_core.search.search.edge_similarity_search",
             "graphiti_core.search.search.node_similarity_search",
             "graphiti_core.utils.maintenance.node_operations.node_similarity_search",
             "graphiti_core.search.search_utils.get_entity_edge_return_query",
             "graphiti_core.search.search_utils.get_entity_node_return_query",
             "graphiti_core.edges.EntityEdge.get_by_uuids",
             "graphiti_core.edges.EntityEdge.load_fact_embedding",
             "graphiti_core.edges.Edge.delete_by_uuids"
           ]

    assert Enum.all?(wrapped, fn [_name, _id, wrapped?] -> wrapped? end)

    %{pid: second} = start_pool([])
    assert wrapped_search_functions() == wrapped

    GenServer.stop(first)
    GenServer.stop(second)
  end

  defp embedder_dimension(instance) do
    {dimension, _} = Pythonx.eval("g.embedder.config.embedding_dim", %{"g" => instance})
    Pythonx.decode(dimension)
  end

  defp vector_index_options(instance) do
    for index <-
          graph_query(
            instance,
            "CALL db.indexes() YIELD label, types, options RETURN label, types, options"
          ),
        {field, kinds} <- index["types"],
        "VECTOR" in kinds,
        into: %{} do
      options = index["options"][field]
      {"#{index["label"]}.#{field}", {options["similarityFunction"], options["dimension"]}}
    end
  end

  # Every query the group's graph instance sends while the pool rebuilds its
  # indexes, after its vector indexes are dropped.
  defp rebuilt_queries(pid, group_id) do
    instance = GraphitiPool.for(pid, group_id)
    graph_query(instance, "DROP VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding)")
    graph_query(instance, "DROP VECTOR INDEX FOR (n:Entity) ON (n.name_embedding)")
    recorded_build(pid, group_id)
  end

  defp recorded_build(pid, group_id, status \\ :as_found) do
    instance = GraphitiPool.for(pid, group_id)

    {sent, _} =
      Pythonx.eval(
        """
        sent = []
        original = g.driver.execute_query
        def building(field):
            return [
                {'types': {'uuid': ['RANGE'], field: ['VECTOR']}, 'options': {'uuid': {}, field: {'dimension': 3, 'similarityFunction': 'cosine'}}, 'status': '[Indexing] 1/2: UNDER CONSTRUCTION'},
                {'types': {'uuid': ['RANGE']}, 'options': {'uuid': {}}, 'status': 'OPERATIONAL'},
            ]
        async def recording(cypher, **params):
            sent.append(cypher)
            if being_built and cypher.startswith('CALL db.indexes()') and 'gralkor_label' in params:
                field = 'fact_embedding' if params['gralkor_label'] == 'RELATES_TO' else 'name_embedding'
                return building(field), ['types', 'options', 'status'], None
            return await original(cypher, **params)
        g.driver.execute_query = recording
        sent
        """,
        %{"g" => instance, "being_built" => status == :being_built}
      )

    assert {:ok, _} = capture_log_result(fn -> GraphitiPool.build_indices(pid) end)

    {sent, _} =
      Pythonx.eval("del g.driver.execute_query\nlist(sent)", %{"g" => instance, "sent" => sent})

    Pythonx.decode(sent)
  end

  defp assert_building_tried_again_after_set_wait_up_to_set_number_of_times(%{pid: pid}) do
    waits = GraphitiPool.index_building_retry_delays_ms()

    for {matching, failure} <- [
          {"stopwords, entitytype", "failed"},
          {"stopwords, entitytype", "timed out"},
          {"stopwords, entitytype", "connection lost"},
          {"stopwords, entitytype", "loading"},
          {"CREATE FULLTEXT INDEX", "connection lost"},
          {"e._gralkor_writers IS NULL", "connection lost"},
          {"$gralkor_label", "connection lost"},
          {"CREATE VECTOR INDEX", "timed out"}
        ] do
      built = failing_build(pid, "fresh", matching, :always, failure)

      assert built.waits == waits, "#{matching}: #{failure}"
      assert tries(built.sent) == length(waits) + 1, "#{matching}: #{failure}"
    end
  end

  defp assert_tries_failing_at_different_steps_share_limit(%{pid: pid}) do
    waits = GraphitiPool.index_building_retry_delays_ms()

    built =
      failing_build(
        pid,
        "fresh",
        [
          "stopwords, entitytype",
          "CREATE FULLTEXT INDEX",
          "e._gralkor_writers IS NULL",
          "CREATE VECTOR INDEX"
        ],
        :always
      )

    assert built.waits == waits
    assert tries(built.sent) == length(waits) + 1
    assert {:error, {:vector_indexes, message}} = built.result
    assert message =~ "(tries: #{length(waits) + 1}, "
  end

  defp assert_later_try_runs_every_step_again(%{pid: pid}) do
    built = failing_build(pid, "fresh", "CREATE VECTOR INDEX", 1)

    {_first_try, [_failed | later]} = Enum.split_while(built.sent, &(&1 != "failed"))

    assert Enum.any?(later, &(&1 =~ "CREATE INDEX FOR"))
    assert Enum.any?(later, &(&1 =~ "CREATE FULLTEXT INDEX"))
    assert Enum.any?(later, &(&1 =~ "stopwords, entitytype"))
    assert Enum.any?(later, &(&1 =~ "e._gralkor_writers IS NULL"))
  end

  defp assert_replacement_and_recording_of_each_try_logged(%{pid: pid}) do
    create_stopword_indexes(%{pid: pid})

    failing =
      fail_queries("stopwords", "UNWIND $rows AS row MATCH (e:Episodic", 1, "connection lost")

    log = capture_log(fn -> GraphitiPool.for(pid, "stopwords") end)
    sent = sent_by(failing)

    assert tries(sent) == 2

    assert log =~
             "full-text indexes rebuilt without stopwords (FalkorDB #3348) — labels: Episodic"

    assert log =~
             "recorded writers for memory written before writers were recorded — graph: #{physical("stopwords")} episodes: 1"
  end

  defp assert_try_creates_only_indexes_graph_lacks(%{pid: pid}) do
    GraphitiPool.for(pid, "fresh")
    failing = fail_queries("first-use", "CREATE FULLTEXT INDEX", 1, "connection lost")
    log = capture_log(fn -> GraphitiPool.for(pid, "first-use") end)
    sent = sent_by(failing)

    assert Enum.count(sent, &(&1 == "failed")) == 1
    refute log =~ "failed (non-fatal)"
    assert index_kinds(pid, "first-use") == index_kinds(pid, "fresh")
  end

  defp assert_try_replaces_only_indexes_still_carrying_stopwords(%{pid: pid}) do
    create_stopword_indexes(%{pid: pid})

    physical_graph_query(pid, "stopwords", [
      "CREATE INDEX FOR (n:Entity) ON (n.uuid, n.group_id)",
      "CREATE FULLTEXT INDEX FOR (n:Entity) ON (n.name, n.summary, n.group_id) OPTIONS {stopwords: ['a', 'the']}"
    ])

    failing =
      fail_queries("stopwords", "DROP FULLTEXT INDEX FOR (n:Episodic)", 1, "connection lost")

    capture_log(fn -> GraphitiPool.for(pid, "stopwords") end)
    sent = sent_by(failing)

    replaced_entity = &(&1 =~ "DROP FULLTEXT INDEX FOR (n:Entity) ON (n.name)")

    assert Enum.find_index(sent, replaced_entity) < Enum.find_index(sent, &(&1 == "failed"))
    assert Enum.count(sent, replaced_entity) == 1
    assert tries(sent) == 2

    for index <- physical_graph_indexes(pid, "stopwords"),
        index["label"] in ["Episodic", "Entity"] do
      assert index["stopwords"] == [], index["label"]
    end
  end

  defp assert_try_records_only_writers_still_missing(%{pid: pid}) do
    seed_unrecorded_writer_graph(%{pid: pid})

    failing =
      fail_queries(
        "history",
        "MATCH (:Entity)-[gralkor_target:RELATES_TO]->(:Entity)",
        1,
        "connection lost"
      )

    instance = capture_log_result(fn -> GraphitiPool.for(pid, "history") end)
    sent = sent_by(failing)

    assert tries(sent) == 2
    assert Enum.count(sent, &(&1 =~ "UNWIND $rows AS row MATCH (e:Episodic")) == 1

    assert recorded_writers(
             instance,
             "MATCH ()-[e:RELATES_TO]->() RETURN e.uuid AS key, e._gralkor_writers AS writers"
           ) == %{
             "shared-edge" => ["lens:alpha", "direct"],
             "reflection-edge" => ["reflection:review"],
             "orphan-edge" => ["unknown"]
           }

    assert recorded_writers(
             instance,
             "MATCH (n:Entity) RETURN n.uuid AS key, n._gralkor_writers AS writers"
           ) == %{
             "shared-node" => ["lens:alpha", "reflection:review"],
             "direct-node" => ["direct"],
             "orphan-node" => ["unknown"]
           }
  end

  defp assert_try_reads_which_vector_indexes_graph_has(%{pid: pid}) do
    built = failing_build(pid, "fresh", "CREATE VECTOR INDEX", 1)

    assert vector_index_queries(built.sent) == [
             "status RELATES_TO",
             "create RELATES_TO",
             "status RELATES_TO",
             "create RELATES_TO",
             "status Entity",
             "create Entity"
           ]
  end

  defp assert_try_creates_only_vector_indexes_graph_lacks(%{pid: pid}) do
    failed_try = failing_build(pid, "fresh", "CREATE VECTOR INDEX FOR (n:Entity)", 1)

    assert vector_index_queries(failed_try.sent) == [
             "status RELATES_TO",
             "create RELATES_TO",
             "status Entity",
             "create Entity",
             "status RELATES_TO",
             "status Entity",
             "create Entity"
           ]

    not_awaited =
      failing_build(
        pid,
        "fresh",
        "CREATE VECTOR INDEX FOR ()-[e:RELATES_TO]",
        1,
        "answer not awaited"
      )

    assert vector_index_queries(not_awaited.sent) == [
             "status RELATES_TO",
             "create RELATES_TO",
             "status RELATES_TO",
             "status Entity",
             "create Entity"
           ]

    assert vector_index_options(not_awaited.instance) == %{
             "RELATES_TO.fact_embedding" => {"cosine", 3},
             "Entity.name_embedding" => {"cosine", 3}
           }
  end

  defp assert_building_not_tried_again_once_try_succeeds(%{pid: pid}) do
    built = failing_build(pid, "fresh", "stopwords, entitytype", 1, "loading")

    assert built.waits == Enum.take(GraphitiPool.index_building_retry_delays_ms(), 1)
    assert tries(built.sent) == 2
  end

  defp assert_success_logged_once_naming_graph_and_try(%{pid: pid}) do
    retries = length(GraphitiPool.index_building_retry_delays_ms())
    built = failing_build(pid, "fresh", "stopwords, entitytype", retries, "loading")

    assert occurrences(
             built.log,
             "[gralkor] index building succeeded on try #{retries + 1} — graph: #{physical("fresh")}"
           ) == 1

    assert occurrences(built.log, "succeeded on try") == 1
  end

  defp assert_indexes_tries_created_logged_together(%{pid: pid}) do
    built = failing_build(pid, "fresh", "CREATE VECTOR INDEX FOR (n:Entity)", 1)

    assert occurrences(
             built.log,
             "[gralkor] vector indexes created — graph: #{physical("fresh")} " <>
               "indexes: RELATES_TO.fact_embedding, Entity.name_embedding dimension: 3"
           ) == 1

    assert occurrences(built.log, "vector indexes created") == 1
  end

  defp assert_index_building_succeeds_after_failed_try(%{pid: pid}) do
    for matching <- ["stopwords, entitytype", "CREATE VECTOR INDEX"] do
      built = failing_build(pid, "fresh", matching, 1, "loading")

      assert built.result == {:ok, %{status: "built"}}, matching

      assert vector_index_options(built.instance) == %{
               "RELATES_TO.fact_embedding" => {"cosine", 3},
               "Entity.name_embedding" => {"cosine", 3}
             },
             matching
    end
  end

  defp assert_index_building_fails_naming_graph_tries_and_last_failure(%{pid: pid}) do
    tries = length(GraphitiPool.index_building_retry_delays_ms()) + 1
    built = failing_build(pid, "fresh", "CREATE VECTOR INDEX", :always)

    assert {:error, {:vector_indexes, message}} = built.result

    assert message =~
             "graph #{physical("fresh")}: building the indexes failed (tries: #{tries}, " <>
               "last failure: redis.exceptions.ConnectionError: Connection closed by server.)"

    failing = fail_queries("first-use", "stopwords, entitytype", :always, "loading")
    log = capture_log(fn -> GraphitiPool.for(pid, "first-use") end)
    sent_by(failing)

    assert log =~
             "[gralkor] build_indices_and_constraints failed (non-fatal): graph #{physical("first-use")}: " <>
               "building the indexes failed (tries: #{tries}, " <>
               "last failure: redis.exceptions.BusyLoadingError: Redis is loading the dataset in memory)"
  end

  defp assert_building_not_tried_again_beside_mismatch_and_failure(%{pid: pid}) do
    built = mismatched_failing_build(pid, "CREATE VECTOR INDEX", 1)

    assert built.waits == []
    assert tries(built.sent) == 1

    assert vector_index_queries(built.sent) == [
             "status RELATES_TO",
             "status Entity",
             "create Entity"
           ]
  end

  defp assert_index_building_fails_naming_mismatch_and_failure(%{pid: pid}) do
    built = mismatched_failing_build(pid, "CREATE VECTOR INDEX", 1)

    assert {:error, {:vector_indexes, message}} = built.result

    assert message =~
             "graph #{physical("fresh")}: the RELATES_TO.fact_embedding vector index compares cosine at 4 dimensions"

    assert message =~
             "graph #{physical("fresh")}: building the indexes failed (tries: 1, " <>
               "last failure: redis.exceptions.ConnectionError: Connection closed by server.)"
  end

  defp assert_index_created_for_unawaited_query_logged(%{pid: pid}) do
    built =
      failing_build(
        pid,
        "fresh",
        "CREATE VECTOR INDEX FOR ()-[e:RELATES_TO]",
        1,
        "answer not awaited"
      )

    assert occurrences(
             built.log,
             "[gralkor] vector indexes created — graph: #{physical("fresh")} " <>
               "indexes: RELATES_TO.fact_embedding, Entity.name_embedding dimension: 3"
           ) == 1
  end

  defp assert_no_success_logged_when_try_finds_mismatch(%{pid: pid}) do
    built = mismatched_failing_build(pid, "$gralkor_label", 1)

    assert built.waits == Enum.take(GraphitiPool.index_building_retry_delays_ms(), 1)
    refute built.log =~ "succeeded on try"
  end

  defp assert_index_building_fails_naming_mismatch_a_try_found(%{pid: pid}) do
    built = mismatched_failing_build(pid, "$gralkor_label", 1)

    assert {:error, {:vector_indexes, message}} = built.result

    assert message =~
             "graph #{physical("fresh")}: the RELATES_TO.fact_embedding vector index compares cosine at 4 dimensions"

    refute message =~ "building the indexes failed"
  end

  defp assert_other_graphs_built_beside_failed_building(%{pid: pid}) do
    others = ["other-1", "other-2", "other-3"]

    for group <- others do
      pid
      |> GraphitiPool.for(group)
      |> graph_query("DROP VECTOR INDEX FOR (n:Entity) ON (n.name_embedding)")
    end

    failing_build(pid, "fresh", "stopwords, entitytype", :always)

    for group <- others do
      assert vector_index_options(GraphitiPool.for(pid, group))["Entity.name_embedding"] ==
               {"cosine", 3},
             group
    end
  end

  defp assert_building_not_tried_again_after_another_failure(%{pid: pid}) do
    for matching <- ["stopwords, entitytype", "CREATE VECTOR INDEX"] do
      built = failing_build(pid, "fresh", matching, :always, "another way")

      assert built.waits == [], matching
      assert tries(built.sent) == 1, matching

      assert built.result == {:error, {:python, "RuntimeError: index building is broken"}},
             matching
    end

    built =
      within_graph_operation_deadline(0.5, fn ->
        failing_build(pid, "fresh", "stopwords, entitytype", 1, "past the deadline")
      end)

    assert built.waits == []
    assert tries(built.sent) == 1
    assert built.result == {:error, :timeout}
  end

  defp within_graph_operation_deadline(seconds, fun) do
    {previous, _} = Pythonx.eval("import asyncio\nasyncio._gralkor_deadline_seconds", %{})

    Pythonx.eval("import asyncio\nasyncio._gralkor_deadline_seconds = seconds\nNone", %{
      "seconds" => seconds
    })

    try do
      fun.()
    after
      Pythonx.eval("import asyncio\nasyncio._gralkor_deadline_seconds = previous\nNone", %{
        "previous" => previous
      })
    end
  end

  defp substitute_index_building_retry_sleep(_context \\ %{}) do
    test_pid = self()
    previous = Application.get_env(:jido_gralkor, :index_building_retry_sleep)

    Application.put_env(:jido_gralkor, :index_building_retry_sleep, fn ms ->
      send(test_pid, {:index_building_retry_sleep, ms})
    end)

    on_exit(fn ->
      if previous do
        Application.put_env(:jido_gralkor, :index_building_retry_sleep, previous)
      else
        Application.delete_env(:jido_gralkor, :index_building_retry_sleep)
      end
    end)

    :ok
  end

  defp index_building_retry_waits(waits \\ []) do
    receive do
      {:index_building_retry_sleep, ms} -> index_building_retry_waits(waits ++ [ms])
    after
      0 -> waits
    end
  end

  # Until `sent_by/1` or the test's exit, the FalkorDB client fails the group's
  # queries as `failure` names, the first `times` times one holds `matching`;
  # a list of patterns names, in order, the query each failure waits for, its
  # last pattern serving every later failure. It records each query the group's
  # graph is sent: a read of whether a vector index exists (`status <label>`),
  # the creation of one (`create <label>`), or else the query itself, followed
  # by `failed` when it failed that query.
  defp fail_queries(group_id, matching, times, failure) do
    {failing, _} =
      Pythonx.eval(
        """
        import asyncio
        import redis.exceptions
        from falkordb.asyncio.graph import AsyncGraph

        class _FailingQueries:
            RAISED = {
                'failed': lambda: redis.exceptions.ResponseError('Query timed out'),
                'timed out': lambda: redis.exceptions.TimeoutError('Timeout reading from socket'),
                'connection lost': lambda: redis.exceptions.ConnectionError('Connection closed by server.'),
                'loading': lambda: redis.exceptions.BusyLoadingError('Redis is loading the dataset in memory'),
                'answer not awaited': lambda: redis.exceptions.TimeoutError('Timeout reading from socket'),
                'another way': lambda: RuntimeError('index building is broken'),
            }

            def __init__(self, name, matching, times, failure):
                self.sent = []
                self.left = times
                self.matching = matching
                self.original = AsyncGraph._query
                failing = self

                async def _query(graph, q, params=None, timeout=None, read_only=False):
                    async def answered():
                        return await failing.original(graph, q, params=params, timeout=timeout, read_only=read_only)

                    if graph.name != name:
                        return await answered()
                    failing.sent.append(failing.described(q, params))
                    if failing.left > 0 and failing.matching[0] in q:
                        failing.left -= 1
                        if len(failing.matching) > 1:
                            failing.matching = failing.matching[1:]
                        if failure == 'answer not awaited':
                            await answered()
                        failing.sent.append('failed')
                        if failure == 'past the deadline':
                            await asyncio.sleep(3600)
                        raise failing.RAISED[failure]()
                    return await answered()

                AsyncGraph._query = _query

            @staticmethod
            def described(q, params):
                label = (params or {}).get('gralkor_label')
                if label is not None:
                    return 'status ' + label
                if q.startswith('CREATE VECTOR INDEX'):
                    return 'create ' + ('RELATES_TO' if 'RELATES_TO' in q else 'Entity')
                return q

            def restore(self):
                from falkordb.asyncio.graph import AsyncGraph
                AsyncGraph._query = self.original

        _FailingQueries(
            group_id.decode('utf-8'),
            [pattern.decode('utf-8') for pattern in matching],
            times,
            failure.decode('utf-8'),
        )
        """,
        %{
          "group_id" => physical(group_id),
          "matching" => List.wrap(matching),
          "times" => if(times == :always, do: 1_000_000, else: times),
          "failure" => failure
        }
      )

    on_exit(fn -> Pythonx.eval("failing.restore()", %{"failing" => failing}) end)
    failing
  end

  defp sent_by(failing) do
    {sent, _} = Pythonx.eval("failing.restore()\nlist(failing.sent)", %{"failing" => failing})
    Pythonx.decode(sent)
  end

  defp vector_index_queries(sent),
    do: Enum.filter(sent, &String.starts_with?(&1, ["status ", "create "]))

  defp tries(sent), do: Enum.count(sent, &(&1 =~ "stopwords, entitytype"))

  defp index_kinds(pid, group_id) do
    pid
    |> physical_graph_indexes(group_id)
    |> Enum.map(fn index ->
      {index["label"],
       Map.new(index["types"], fn {field, kinds} -> {field, Enum.sort(kinds)} end),
       index["stopwords"]}
    end)
    |> Enum.sort()
  end

  defp occurrences(text, part), do: length(String.split(text, part)) - 1

  defp drop_vector_indexes(instance) do
    existing = Map.keys(vector_index_options(instance))

    if "RELATES_TO.fact_embedding" in existing do
      graph_query(instance, "DROP VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding)")
    end

    if "Entity.name_embedding" in existing do
      graph_query(instance, "DROP VECTOR INDEX FOR (n:Entity) ON (n.name_embedding)")
    end
  end

  # Builds the pool's indexes after the group's vector indexes are dropped,
  # while the group's queries holding `matching` fail the first `times` times.
  defp failing_build(pid, group_id, matching, times, failure \\ "connection lost") do
    instance = GraphitiPool.for(pid, group_id)
    drop_vector_indexes(instance)
    build_while_failing(pid, instance, group_id, matching, times, failure)
  end

  # The same build while the group's only vector index is a fact index at
  # another dimension than the embedder's.
  defp mismatched_failing_build(pid, matching, times) do
    instance = GraphitiPool.for(pid, "fresh")
    drop_vector_indexes(instance)

    graph_query(
      instance,
      "CREATE VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding) OPTIONS {dimension: 4, similarityFunction: 'cosine'}"
    )

    build_while_failing(pid, instance, "fresh", matching, times, "connection lost")
  end

  defp build_while_failing(pid, instance, group_id, matching, times, failure) do
    index_building_retry_waits()
    failing = fail_queries(group_id, matching, times, failure)
    parent = self()
    log = capture_log(fn -> send(parent, {:built, GraphitiPool.build_indices(pid)}) end)
    sent = sent_by(failing)
    assert_received {:built, result}

    %{
      result: result,
      log: log,
      sent: sent,
      waits: index_building_retry_waits(),
      instance: instance
    }
  end

  defp mismatched_build(pid) do
    instance = GraphitiPool.for(pid, "fresh")
    graph_query(instance, "DROP VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding)")
    graph_query(instance, "DROP VECTOR INDEX FOR (n:Entity) ON (n.name_embedding)")

    graph_query(
      instance,
      "CREATE VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding) OPTIONS {dimension: 4, similarityFunction: 'cosine'}"
    )

    assert {:error, _} = GraphitiPool.build_indices(pid)
    instance
  end

  defp assert_deep_beyond_share_sends_own_query(%{deep: deep}) do
    for {kind, found} <- deep_beyond_share(deep) do
      [lookup, own] = Enum.reject(found["sent"], &(&1 =~ "CALL db.indexes()"))
      assert lookup =~ "db.idx.vector", kind
      assert own =~ "vec.cosineDistance", kind
    end
  end

  defp assert_deep_beyond_share_returns_own_results(%{deep: deep}) do
    for {kind, found} <- deep_beyond_share(deep) do
      assert found["wrapped"] == found["own"], kind
      assert length(found["wrapped"]) == 4, kind
    end
  end

  defp assert_dropped_search_sends_own_query(%{instance: instance}) do
    for {kind, found} <- dropped_search(instance) do
      assert Enum.any?(found["before"], &(&1 =~ "db.idx.vector")), kind
      assert [status, own] = found["after"]
      assert status =~ "CALL db.indexes()", kind
      assert own =~ "vec.cosineDistance", kind
      assert found["found"] == found["own"], kind
    end
  end

  defp assert_dropped_search_asks_no_index(%{instance: instance}) do
    for {kind, found} <- dropped_search(instance) do
      refute Enum.any?(found["after"], &(&1 =~ "db.idx.vector")), kind
    end
  end

  defp assert_vanished_search_answers_with_own_query(%{instance: instance}) do
    found = vanished_searches(instance)

    for {name, case_found} <- found do
      assert [status, lookup, own] = case_found["sent"], name
      assert status =~ "CALL db.indexes()", name
      assert lookup =~ "db.idx.vector", name
      assert own =~ "vec.cosineDistance", name
      assert case_found["found"] == case_found["own"], name
      assert case_found["found"] != [], name
    end

    own_since = List.last(found["fact since"]["sent"])
    assert own_since =~ "MATCH ()-[e:RELATES_TO]->()"
    assert own_since =~ "e.created_at >= $gralkor_since"
  end

  defp assert_vanished_search_sends_own_query_once(%{instance: instance}) do
    for {name, found} <- vanished_searches(instance) do
      assert Enum.count(found["sent"], &(&1 =~ "vec.cosineDistance")) == 1, name
      assert Enum.count(found["sent"], &(&1 =~ "db.idx.vector")) == 1, name
    end
  end

  defp assert_vanished_search_own_query_carries_timeout(%{instance: instance}) do
    for {name, found} <- vanished_searches(instance) do
      assert found["own_timeouts"] == [found["read_timeout"]], name
    end
  end

  defp assert_failed_lookup_fails_search(%{instance: instance}) do
    for {kind, found} <- failed_lookup_searches(instance) do
      assert found["error"] =~ "ResponseError: Vector dimension mismatch", kind
    end
  end

  defp assert_failed_lookup_sends_no_own_query(%{instance: instance}) do
    for {kind, found} <- failed_lookup_searches(instance) do
      assert Enum.any?(found["sent"], &(&1 =~ "db.idx.vector")), kind
      refute Enum.any?(found["sent"], &(&1 =~ "vec.cosineDistance")), kind
    end
  end

  defp assert_mismatched_search_fails_naming_index(%{instance: instance}) do
    found = mismatched_search(instance)

    assert found["fact"]["error"] =~ "RuntimeError: graph #{physical("vectors")}"

    assert found["fact"]["error"] =~
             "RELATES_TO.fact_embedding vector index compares euclidean at 3 dimensions"

    assert found["fact"]["error"] =~
             "DROP VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding)"

    assert found["entity"]["error"] =~
             "Entity.name_embedding vector index compares cosine at 4 dimensions"

    assert found["entity"]["error"] =~ "but the embedder writes 3"
    assert found["entity"]["error"] =~ "DROP VECTOR INDEX FOR (n:Entity) ON (n.name_embedding)"
  end

  defp assert_mismatched_search_asks_no_index(%{instance: instance}) do
    for {kind, found} <- mismatched_search(instance) do
      assert [status] = found["sent"], kind
      assert status =~ "CALL db.indexes()", kind
    end
  end

  defp assert_no_vector_index_created_again(%{pid: pid}) do
    GraphitiPool.for(pid, "fresh")
    built = recorded_build(pid, "fresh")
    being_built = recorded_build(pid, "fresh", :being_built)

    refute Enum.any?(built, &(&1 =~ "CREATE VECTOR INDEX"))
    refute Enum.any?(being_built, &(&1 =~ "CREATE VECTOR INDEX"))
  end

  defp assert_replacement_and_recording_logged_beside_mismatch(%{pid: pid}) do
    create_stopword_indexes(%{pid: pid})

    physical_graph_query(pid, "stopwords", [
      "CREATE VECTOR INDEX FOR ()-[e:RELATES_TO]-() ON (e.fact_embedding) OPTIONS {dimension: 4, similarityFunction: 'cosine'}"
    ])

    log = capture_log(fn -> GraphitiPool.for(pid, "stopwords") end)

    assert log =~
             "full-text indexes rebuilt without stopwords (FalkorDB #3348) — labels: Episodic"

    assert log =~
             "recorded writers for memory written before writers were recorded — graph: #{physical("stopwords")} episodes: 1"

    assert log =~
             "build_indices_and_constraints failed (non-fatal): graph #{physical("stopwords")}: the RELATES_TO.fact_embedding vector index"
  end

  defp assert_other_graphs_built_beside_mismatch(%{pid: pid}) do
    others = ["other-1", "other-2", "other-3"]

    for group <- others do
      pid
      |> GraphitiPool.for(group)
      |> graph_query("DROP VECTOR INDEX FOR (n:Entity) ON (n.name_embedding)")
    end

    mismatched_build(pid)

    for group <- others do
      assert vector_index_options(GraphitiPool.for(pid, group))["Entity.name_embedding"] ==
               {"cosine", 3},
             group
    end
  end
end
