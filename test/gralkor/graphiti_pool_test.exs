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

  @search_filter_targets """
  import graphiti_core.search.search as search_module
  import graphiti_core.search.search_utils as search_utils
  import graphiti_core.driver.falkordb.operations.search_ops as falkor_search_ops
  targets = [
      (search_utils, 'node_search_filter_query_constructor'),
      (search_utils, 'edge_search_filter_query_constructor'),
      (falkor_search_ops, 'node_search_filter_query_constructor'),
      (falkor_search_ops, 'edge_search_filter_query_constructor'),
      (search_module, 'episode_fulltext_search'),
  ]
  """

  defp wrapped_search_functions do
    {functions, _} =
      Pythonx.eval(
        @search_filter_targets <>
          """
          [
              [
                  module.__name__ + '.' + name,
                  id(getattr(module, name, None)),
                  hasattr(getattr(module, name, None), '_gralkor_original'),
              ]
              for module, name in targets
          ]
          """,
        %{}
      )

    Pythonx.decode(functions)
  end

  # Puts graphiti's own functions back, as before any pool started, and
  # restores whatever was installed when the test exits.
  defp unwrap_search_filters do
    {saved, _} =
      Pythonx.eval(
        @search_filter_targets <>
          """
          saved = (
              [(module, name, getattr(module, name, None)) for module, name in targets],
              getattr(search_utils, '_gralkor_search_filters', None),
              getattr(search_utils, '_gralkor_search_filter_originals', None),
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
          functions, installed, originals = saved
          for module, name, function in functions:
              setattr(module, name, function)
          search_utils._gralkor_search_filters = installed
          search_utils._gralkor_search_filter_originals = originals
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
              text(key): [text(item) for item in value]
              for key, value in filter_kwargs.items()
          }
          cls = (
              search_utils._gralkor_search_filters
              if text(filter_class) == 'LensSearchFilters'
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
  defp episode_fulltext_queries(episode_uuids) do
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

          uuids = None if episode_uuids is None else [
              uuid.decode('utf-8') if isinstance(uuid, (bytes, bytearray)) else uuid
              for uuid in episode_uuids
          ]
          filters = (
              SearchFilters()
              if uuids is None
              else search_utils._gralkor_search_filters(episode_uuids=uuids)
          )
          wrapped = _RecordingDriver()
          own = _RecordingDriver()
          asyncio._gralkor_run(search_module.episode_fulltext_search(wrapped, 'amber notes', filters, None, 5))
          asyncio._gralkor_run(search_utils.episode_fulltext_search(own, 'amber notes', SearchFilters(), None, 5))
          {'wrapped': wrapped.recorded, 'own': own.recorded}
          """,
        %{"episode_uuids" => episode_uuids}
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
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "partial-uuid")

      assert :ok =
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "partial-uuid")

      {proof, _} =
        Pythonx.eval(
          "[len(g.driver.episodes), g.extractions, g.completed_effects, 'partial-uuid' in g.driver._gralkor_completed_episode_uuids]",
          %{"g" => g}
        )

      assert Pythonx.decode(proof) == [1, 2, 1, true]

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
               GraphitiPool.add_episode(pid, "g1", "content", "source", nil, uuid: "episode-uuid")

      assert {:ok, %{"extraction_complete" => true}} =
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

      {count, _} = Pythonx.eval("g.extractions", %{"g" => g})
      assert Pythonx.decode(count) == 1
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

  describe "when a memory search is run for a group > while neither node labels, edge types, nor Lenses are supplied" do
    test "then the single search's filter leaves every node and edge eligible" do
      {_results, recorded} = memory_search_result()
      assert recorded["node_labels"] == nil
      assert recorded["edge_types"] == nil
      assert recorded["edge_uuids"] == nil
      assert recorded["node_uuids"] == nil
      assert recorded["episode_uuids"] == nil
      assert recorded["lens_queries"] == []
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

  describe "when a memory search is run for a group > while Lenses are supplied" do
    test "then the single search's filter admits only edges drawn from an episode whose source description names a supplied Lens" do
      {_results, recorded} =
        memory_search_result(lens_scope: lens_scope(), opts: [lenses: ["alpha"]])

      assert recorded["edge_uuids"] == ["alpha-edge"]

      assert %{"episode_uuids" => ["lens-episode"]} = lens_query(recorded, "RELATES_TO")

      assert %{"lens_suffixes" => [" [lens: alpha]"]} = lens_query(recorded, "ENDS WITH")
    end

    test "and the single search's filter admits only nodes mentioned by such an episode" do
      {_results, recorded} =
        memory_search_result(lens_scope: lens_scope(), opts: [lenses: ["alpha"]])

      assert recorded["node_uuids"] == ["mentioned-node"]
      assert %{"episode_uuids" => ["lens-episode"]} = lens_query(recorded, "MENTIONS")
    end

    test "and the single search's filter admits only episodes whose source description names a supplied Lens" do
      {_results, recorded} =
        memory_search_result(lens_scope: lens_scope(), opts: [lenses: ["alpha"]])

      assert recorded["episode_uuids"] == ["lens-episode"]
      assert %{"lens_suffixes" => [" [lens: alpha]"]} = lens_query(recorded, "ENDS WITH")
    end

    test "and the episode restriction is applied inside the full-text query, before its limit" do
      %{"wrapped" => [query]} = episode_fulltext_queries(["lens-episode"])

      restriction = :binary.match(query["cypher"], "e.uuid IN $gralkor_episode_uuids")
      limit = :binary.match(query["cypher"], "LIMIT $limit")

      assert {restriction_at, _} = restriction
      assert {limit_at, _} = limit
      assert restriction_at < limit_at
      assert query["cypher"] =~ "db.idx.fulltext.queryNodes"
      assert query["query"] == "amber notes"
      assert query["gralkor_episode_uuids"] == ["lens-episode"]
      assert query["limit"] == 5
    end

    test "and each rendered fact's sources include only episodes whose source description names a supplied Lens" do
      {%{facts: [fact | _]}, _recorded} =
        memory_search_result(lens_scope: lens_scope(), opts: [lenses: ["alpha"]])

      assert [%{id: "lens-episode", source_description: "notes [lens: alpha]"}] = fact.sources
    end
  end

  describe "when a memory search is run for a group > while Lenses are supplied > while nothing in the group was written by a supplied Lens" do
    test "then the graph library is not searched" do
      {_results, recorded} =
        memory_search_result(lens_scope: %{}, opts: [lenses: ["silent"]])

      assert recorded["calls"] == 0

      {_results, recorded} =
        memory_search_result(lens_scope: %{"mentioned" => [nil]}, opts: [lenses: ["silent"]])

      assert recorded["calls"] == 0
    end

    test "and no facts, nodes, or episodes are returned" do
      {results, _recorded} =
        memory_search_result(lens_scope: %{}, opts: [lenses: ["silent"]])

      assert results == %{facts: [], nodes: [], episodes: []}
    end
  end

  defp lens_scope do
    %{
      "episodes" => ["lens-episode"],
      "edges" => ["alpha-edge"],
      "mentioned" => ["mentioned-node"]
    }
  end

  defp lens_query(recorded, marker) do
    Enum.find(recorded["lens_queries"], &String.contains?(&1["query"], marker))
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

  defp memory_search_result(options \\ []) do
    {g, _} =
      Pythonx.eval(
        """
        from datetime import datetime, timezone
        from graphiti_core.nodes import EpisodeType

        def _text(value):
            return value.decode('utf-8') if isinstance(value, (bytes, bytearray)) else value

        scope = (
            None
            if lens_scope is None
            else {_text(key): [_text(uuid) for uuid in uuids] for key, uuids in lens_scope.items()}
        )

        class _Episode:
            def __init__(self, uuid, source, source_description, content=""):
                self.uuid = uuid
                self.source = source
                self.source_description = source_description
                self.content = content

        class _GraphOperations:
            async def episodic_node_get_by_uuids(self, cls, driver, uuids):
                return [driver.episodes[uuid] for uuid in uuids]

        class _EntityDriver:
            def __init__(self, recorded):
                self.graph_operations_interface = _GraphOperations()
                self.recorded = recorded
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
                self._gralkor_completed_episode_uuids = {"complete"}

            def lens_records(self, key, query, params):
                self.recorded["lens_queries"].append({"query": query, **params})
                return ([{"uuid": uuid} for uuid in scope.get(key, [])], None, None)

            async def execute_query(self, query, **params):
                if "RELATES_TO" in query:
                    return self.lens_records("edges", query, params)
                if "MENTIONS" in query:
                    return self.lens_records("mentioned", query, params)
                if "ENDS WITH" in query:
                    return self.lens_records("episodes", query, params)
                if "_gralkor_extraction_complete" in query:
                    return ([{"uuid": uuid} for uuid in params["uuids"] if uuid in self._gralkor_completed_episode_uuids], None, None)
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
                self.episodes = ["episode-1", "lens-episode"] if scope is not None else ["episode-1"]

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
                self.recorded = {"calls": 0, "lens_queries": []}
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
                self.recorded["node_uuids"] = getattr(search_filter, "node_uuids", None)
                self.recorded["episode_uuids"] = getattr(search_filter, "episode_uuids", None)
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
          "lens_scope" => Keyword.get(options, :lens_scope)
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

    assert {:ok, results} =
             GraphitiPool.search_memory(
               pid,
               "group-with-hyphens",
               Keyword.get(options, :query, "what changed parse"),
               Keyword.get(options, :limits, %{facts: 7, nodes: 7, episodes: 7}),
               Keyword.get(options, :opts, [])
             )

    {recorded, _} = Pythonx.eval("g.recorded", %{"g" => g})
    GenServer.stop(pid)

    {results, Pythonx.decode(recorded)}
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

    test "and the graph library's node and edge filter constructors and episode full-text search are wrapped once, before any search" do
      unwrap_search_filters()
      refute Enum.any?(wrapped_search_functions(), fn [_name, _id, wrapped?] -> wrapped? end)

      %{pid: first} = start_pool([])
      wrapped = wrapped_search_functions()

      assert Enum.map(wrapped, &hd/1) == [
               "graphiti_core.search.search_utils.node_search_filter_query_constructor",
               "graphiti_core.search.search_utils.edge_search_filter_query_constructor",
               "graphiti_core.driver.falkordb.operations.search_ops.node_search_filter_query_constructor",
               "graphiti_core.driver.falkordb.operations.search_ops.edge_search_filter_query_constructor",
               "graphiti_core.search.search.episode_fulltext_search"
             ]

      assert Enum.all?(wrapped, fn [_name, _id, wrapped?] -> wrapped? end)

      %{pid: second} = start_pool([])
      assert wrapped_search_functions() == wrapped

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

      for {mutation, function} <- [
            {"del falkor_search_ops.node_search_filter_query_constructor",
             "graphiti_core.driver.falkordb.operations.search_ops.node_search_filter_query_constructor"},
            {"async def changed(driver, query):\n    return []\nsearch_module.episode_fulltext_search = changed",
             "graphiti_core.search.search.episode_fulltext_search"}
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
end
