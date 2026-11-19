defmodule Gralkor.GraphOperationDeadlinesFunctionalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.GraphitiPool

  @moduletag :functional
  @moduletag timeout: 120_000

  @remote {:remote, host: "127.0.0.1", port: 6379}

  setup do
    :ok = Gralkor.Python.smoke_import_graphiti()

    put_env_restored(:client, Native)
    put_env_restored(:lens_storage, Gralkor.Lens.Storage.Graphiti)
    on_exit(fn -> Gralkor.Python.install_async_runtime() end)

    :ok
  end

  describe "when the remote runtime starts > while no remote FalkorDB socket timeout is configured" do
    test "then the remote connection uses a sixty-second socket timeout" do
      delete_env_restored(:remote_falkordb_socket_timeout_ms)

      start_application_pool()

      assert_receive {:constructed_falkordb, {:remote, _options}, 60.0, _max_connections}
    end
  end

  describe "when the remote runtime starts > while a positive `:remote_falkordb_socket_timeout_ms` is configured" do
    test "then the remote connection uses that timeout" do
      put_env_restored(:remote_falkordb_socket_timeout_ms, 90_000)

      start_application_pool()

      assert_receive {:constructed_falkordb, {:remote, _options}, 90.0, _max_connections}
    end
  end

  describe "when the remote runtime starts > while no remote FalkorDB connection cap is configured" do
    test "then the remote connections are capped at one hundred" do
      delete_env_restored(:remote_falkordb_max_connections)

      start_application_pool()

      assert_receive {:constructed_falkordb, {:remote, _options}, _socket_timeout, 100}
    end
  end

  describe "when the remote runtime starts > while a positive `:remote_falkordb_max_connections` is configured" do
    test "then the remote connections are capped at that number" do
      put_env_restored(:remote_falkordb_max_connections, 7)

      start_application_pool()

      assert_receive {:constructed_falkordb, {:remote, _options}, _socket_timeout, 7}
    end
  end

  describe "if `:remote_falkordb_socket_timeout_ms` is not a positive integer" do
    test "then application startup raises naming the setting and its offending value" do
      use_remote_application_backend()

      Enum.each([0, -1, "60000"], fn invalid ->
        put_env_restored(:remote_falkordb_socket_timeout_ms, invalid)

        assert_raise ArgumentError,
                     ~r/remote_falkordb_socket_timeout_ms.*#{Regex.escape(inspect(invalid))}/,
                     fn -> Gralkor.Application.children() end
      end)
    end
  end

  describe "if `:remote_falkordb_max_connections` is not a positive integer" do
    test "then application startup raises naming the setting and its offending value" do
      use_remote_application_backend()

      Enum.each([0, -1, "100"], fn invalid ->
        put_env_restored(:remote_falkordb_max_connections, invalid)

        assert_raise ArgumentError,
                     ~r/remote_falkordb_max_connections.*#{Regex.escape(inspect(invalid))}/,
                     fn -> Gralkor.Application.children() end
      end)
    end
  end

  describe "when the runtime starts > while no graph operation deadline is configured" do
    test "then graph operations use a thirty-minute deadline" do
      use_remote_application_backend()
      delete_env_restored(:graph_operation_deadline_ms)

      assert Keyword.fetch!(application_pool_opts(), :graph_operation_deadline_ms) == 1_800_000
    end
  end

  describe "if `:graph_operation_deadline_ms` is not a positive integer" do
    test "then application startup raises naming the setting and its offending value" do
      use_remote_application_backend()

      Enum.each([0, -1, "1800000"], fn invalid ->
        put_env_restored(:graph_operation_deadline_ms, invalid)

        assert_raise ArgumentError,
                     ~r/graph_operation_deadline_ms.*#{Regex.escape(inspect(invalid))}/,
                     fn -> Gralkor.Application.children() end
      end)
    end
  end

  describe "when a remote FalkorDB accepts a connection and never replies" do
    test "then an episode write returns `{:error, :timeout}`" do
      pool = start_silent_remote_pool()

      assert {:error, :timeout} = write(pool)
    end

    test "and runtime-targeted Lens ingestion returns `{:error, :timeout}`" do
      start_silent_remote_pool()
      runtime = start_runtime()

      assert {:error, :timeout} =
               Client.ingest(runtime, %Gralkor.Ingest{
                 id: "deadline-ingestion",
                 operator_id: "operator-one",
                 lens: "personal-chat",
                 source_kind: :document,
                 content: "A write the graph never answers.",
                 source_description: "notes"
               })
    end

    test "and the timeout is logged with the stage it hit" do
      pool = start_silent_remote_pool()

      assert capture_log(fn -> write(pool) end) =~ "stage:add_episode"
    end

    test "and the write's graph query is sent once" do
      pool = start_silent_remote_pool()

      assert {:error, :timeout} = write(pool)
      assert_received {:graph_command, _query}
      Process.sleep(500)
      refute_received {:graph_command, _query}
    end
  end

  describe "when an episode write's graph query runs past the socket timeout on the embedded FalkorDB" do
    setup [:start_slow_embedded_pool]

    test "then the write returns `{:error, :timeout}`", %{pool: pool} do
      assert {:error, :timeout} = write(pool)
    end

    test "and the query reaches FalkorDB once", %{pool: pool, database: database} do
      assert {:error, :timeout} = write(pool)
      assert slow_queries_on_server(database) == 1
    end
  end

  describe "when a memory search's graph query runs past the socket timeout on the embedded FalkorDB" do
    setup [:start_slow_embedded_pool]

    test "then the search returns `{:error, :timeout}`", %{pool: pool} do
      assert {:error, :timeout} = search(pool)
    end

    test "and the query reaches FalkorDB once", %{pool: pool, database: database} do
      assert {:error, :timeout} = search(pool)
      assert slow_queries_on_server(database) == 1
    end
  end

  describe "if the embedded FalkorDB connection is closed while an episode write's graph query runs" do
    setup [:start_slow_embedded_pool]

    test "then the write returns an error naming the closed connection", %{
      pool: pool,
      database: database
    } do
      assert {:error, {:python, message}} = write_while_closing(pool, database)
      assert message =~ "ConnectionError"
    end

    test "and the query reaches FalkorDB once", %{pool: pool, database: database} do
      assert {:error, {:python, _message}} = write_while_closing(pool, database)
      assert slow_queries_on_server(database) == 1
    end
  end

  @slow_query "MATCH (a:Slow), (b:Slow), (c:Slow), (d:Slow) RETURN count(*) AS slow"

  # An embedded FalkorDB with a one-second socket timeout whose graph instance
  # runs one slow query for every episode write and search. FalkorDB itself
  # stops that query after eight seconds, so it outlasts the socket timeout and
  # is still running when the operation returns.
  defp start_slow_embedded_pool(_context) do
    data_dir =
      Path.join(System.tmp_dir!(), "gralkor_slow_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(data_dir) end)
    parent = self()

    pool =
      start_pool(
        falkordb_spec: {:embedded, data_dir},
        embedded_falkordb_socket_timeout_ms: 1_000,
        graph_operation_deadline_ms: 60_000,
        construct_instance: fn database, _shared, group_id ->
          send(parent, {:slow_database, database})
          slow_graph(database, group_id)
        end
      )

    GraphitiPool.for(pool, "deadlines")
    assert_received {:slow_database, database}

    Gralkor.Python.run_coroutine(
      "database.select_graph('slow').query('UNWIND range(1, 400) AS i CREATE (:Slow {i: i})')",
      %{"database" => database}
    )

    %{pool: pool, database: database}
  end

  defp slow_graph(database, group_id) do
    {graph, _} =
      Pythonx.eval(
        """
        from types import SimpleNamespace

        class _SlowGraphiti:
            def __init__(self):
                self.driver = None
                self.graph = database.select_graph('slow')

            async def slow(self):
                await self.graph.query(slow_query.decode('utf-8'), timeout=8000)

            async def add_episode(self, **kwargs):
                await self.slow()

            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                await self.slow()
                return SimpleNamespace(edges=[], nodes=[], episodes=[])

        _SlowGraphiti()
        """,
        %{"database" => database, "group_id" => group_id, "slow_query" => @slow_query}
      )

    graph
  end

  defp search(pool) do
    GraphitiPool.search_memory(pool, "deadlines", "backups", Gralkor.Search.limits())
  end

  # Closes, from another connection, the connection that is running the slow
  # query, once FalkorDB reports it running.
  defp write_while_closing(pool, database) do
    writer = Task.async(fn -> write(pool) end)
    assert_eventually(fn -> slow_queries_on_server(database) == 1 end)

    Gralkor.Python.run_coroutine(
      """
      async def close_running():
          for client in await database.connection.client_list():
              if client.get('cmd', '').lower() == 'graph.query':
                  await database.connection.client_kill_filter(_id=client['id'])
      close_running()
      """,
      %{"database" => database}
    )

    Task.await(writer, 30_000)
  end

  # How many copies of the slow query FalkorDB is running or holding in its
  # queue.
  defp slow_queries_on_server(database) do
    Gralkor.Python.run_coroutine(
      "database.connection.execute_command('GRAPH.INFO')",
      %{"database" => database}
    )
    |> Pythonx.decode()
    |> then(fn ["# Running queries", running, "# Waiting queries", waiting | _] ->
      Enum.count(running ++ waiting, &(inspect(&1) =~ "MATCH (a:Slow)"))
    end)
  end

  describe "when a graph operation outlasts `:graph_operation_deadline_ms`" do
    test "then the episode write returns `{:error, :timeout}` within the deadline" do
      %{pool: pool} = start_hanging_pool(200)

      {elapsed_us, result} = :timer.tc(fn -> write(pool) end)

      assert result == {:error, :timeout}
      assert elapsed_us >= 200_000
      assert elapsed_us < 5_000_000
    end

    test "and the outstanding graph work is cancelled" do
      %{graph: graph, pool: pool} = start_hanging_pool(200)

      assert {:error, :timeout} = write(pool)

      assert_eventually(fn -> graph_value(graph, "cancelled") end)
    end

    test "and the timeout is logged with the stage it hit" do
      %{pool: pool} = start_hanging_pool(200)

      assert capture_log(fn -> write(pool) end) =~ "stage:add_episode"
    end

    test "and the next graph operation still runs" do
      %{graph: graph, pool: pool} = start_hanging_pool(200)

      assert {:error, :timeout} = write(pool)

      Pythonx.eval("graph.hang = False", %{"graph" => graph})

      assert :ok = write(pool)
    end
  end

  describe "while more episode writes are waiting on the graph or a model provider than the virtual machine has dirty CPU schedulers" do
    test "then a memory search still returns its results without waiting for them" do
      %{pool: pool} = start_waiting_writes()

      assert {:ok, %{nodes: [%{name: "Ada"}]}} =
               promptly(fn ->
                 GraphitiPool.search_memory(pool, "deadlines", "backups", Gralkor.Search.limits())
               end)
    end

    test "and each waiting write returns once its wait ends" do
      %{graph: graph, writes: writes} = start_waiting_writes()

      release(graph)

      assert Task.await_many(writes, 5_000) == List.duplicate(:ok, length(writes))
    end
  end

  describe "while every remote FalkorDB connection is in use > when another graph operation needs a connection > when a connection is released within the socket timeout" do
    test "then the waiting operation completes with its result" do
      %{pool: pool, graph: graph, holder: holder} = start_connection_holding_pool(5_000)

      waiter = Task.async(fn -> write(pool) end)
      assert Task.yield(waiter, 300) == nil
      release(graph)

      assert Task.await(waiter, 5_000) == :ok
      assert Task.await(holder, 5_000) == :ok
    end
  end

  describe "while every remote FalkorDB connection is in use > when another graph operation needs a connection > if no connection is released within the socket timeout" do
    test "then the waiting operation returns `{:error, :timeout}`" do
      %{pool: pool} = start_connection_holding_pool(300)

      assert write(pool) == {:error, :timeout}
    end

    test "and the timeout is logged with the stage it hit" do
      %{pool: pool} = start_connection_holding_pool(300)

      assert capture_log(fn -> write(pool) end) =~ "stage:add_episode"
    end
  end

  describe "while every embedded FalkorDB connection is in use > when another graph operation needs a connection > when a connection is released within the socket timeout" do
    test "then the waiting operation completes with its result" do
      with_embedded_connections_held(5_000, fn pool, database ->
        waiter = Task.async(fn -> write(pool) end)
        assert Task.yield(waiter, 250) == nil

        release_embedded_connections(database, 1)
        assert Task.await(waiter, 5_000) == :ok
      end)
    end
  end

  describe "while every embedded FalkorDB connection is in use > when another graph operation needs a connection > if no connection is released within the socket timeout" do
    test "then the waiting operation returns `{:error, :timeout}`" do
      with_embedded_connections_held(350, fn pool, _database ->
        {elapsed_us, outcome} = :timer.tc(fn -> write(pool) end)
        assert outcome == {:error, :timeout}
        assert elapsed_us >= 350_000
      end)
    end
  end

  defp write(pool) do
    GraphitiPool.add_episode(pool, "deadlines", "A write.", "notes", nil, [])
  end

  defp start_waiting_writes do
    {graph, _} =
      Pythonx.eval(
        """
        import asyncio
        from types import SimpleNamespace

        class _GatedGraphiti:
            def __init__(self):
                self.gate = asyncio.Event()
                self.waiting = 0
                self.driver = None

            async def add_episode(self, **kwargs):
                self.waiting += 1
                await self.gate.wait()

            async def search_(self, query, config=None, search_filter=None):
                return SimpleNamespace(
                    edges=[],
                    nodes=[SimpleNamespace(name='Ada', summary='Ada keeps the backups.', attributes={})],
                    episodes=[],
                )

        _GatedGraphiti()
        """,
        %{}
      )

    on_exit(fn -> release(graph) end)

    pool =
      start_pool(
        falkordb_spec: @remote,
        construct_falkor_db: fn _spec, _socket_timeout -> :stub_falkor_db end,
        construct_instance: fn _database, _shared, _group_id -> graph end,
        graph_operation_deadline_ms: 60_000
      )

    waiting = :erlang.system_info(:dirty_cpu_schedulers) + 1
    writes = for _ <- 1..waiting, do: Task.async(fn -> write(pool) end)

    assert_eventually(fn -> promptly(fn -> graph_value(graph, "waiting") end) == waiting end)

    %{graph: graph, pool: pool, writes: writes}
  end

  defp release(graph) do
    Pythonx.eval("import asyncio\nasyncio._gralkor_loop.call_soon_threadsafe(graph.gate.set)", %{
      "graph" => graph
    })
  end

  defp promptly(operation) do
    task = Task.async(operation)

    case Task.yield(task, 2_000) do
      {:ok, result} -> result
      nil -> flunk("operation did not complete within 2s while writes were waiting")
    end
  end

  defp start_runtime do
    start_supervised!(
      {JidoGralkor.Runtime,
       owner: self(), configuration: %{destinations: [], lenses: [], reflections: []}}
    )

    self()
  end

  defp start_hanging_pool(deadline_ms) do
    {graph, _} =
      Pythonx.eval(
        """
        import asyncio

        class _HangingGraphiti:
            def __init__(self):
                self.hang = True
                self.cancelled = False

            async def add_episode(self, **kwargs):
                if not self.hang:
                    return
                try:
                    await asyncio.Event().wait()
                except asyncio.CancelledError:
                    self.cancelled = True
                    raise

        _HangingGraphiti()
        """,
        %{}
      )

    pool =
      start_pool(
        falkordb_spec: @remote,
        construct_falkor_db: fn _spec, _socket_timeout -> :stub_falkor_db end,
        construct_instance: fn _database, _shared, _group_id -> graph end,
        graph_operation_deadline_ms: deadline_ms
      )

    %{graph: graph, pool: pool}
  end

  # A real FalkorDB client over a real socket; only the server is silent.
  defp start_silent_remote_pool do
    start_pool(
      falkordb_spec: {:remote, host: "127.0.0.1", port: silent_server_port()},
      remote_falkordb_socket_timeout_ms: 100,
      graph_operation_deadline_ms: 60_000,
      construct_instance: &driver_backed_graph/3
    )
  end

  defp driver_backed_graph(database, _shared, group_id) do
    {graph, _} =
      Pythonx.eval(
        """
        from types import SimpleNamespace
        from graphiti_core.driver.falkordb_driver import FalkorDriver

        class _DriverBackedGraphiti:
            def __init__(self):
                self.driver = FalkorDriver(falkor_db=database, database=group_id.decode('utf-8'))

            async def add_episode(self, **kwargs):
                await self.driver.execute_query('RETURN 1')
                return SimpleNamespace(
                    episode=SimpleNamespace(uuid='deadline-probe'),
                    edges=[],
                    nodes=[],
                )

        _DriverBackedGraphiti()
        """,
        %{"database" => database, "group_id" => group_id}
      )

    graph
  end

  # A real FalkorDB client capped at one connection. The first write takes that
  # connection from the client's own pool and keeps it until the test releases
  # it; every later write needs a connection for a PING, which the server answers.
  defp start_connection_holding_pool(socket_timeout_ms) do
    parent = self()

    pool =
      start_pool(
        falkordb_spec: {:remote, host: "127.0.0.1", port: silent_server_port()},
        remote_falkordb_socket_timeout_ms: socket_timeout_ms,
        remote_falkordb_max_connections: 1,
        graph_operation_deadline_ms: 60_000,
        construct_instance: fn database, _shared, _group_id ->
          graph = connection_holding_graph(database)
          send(parent, {:connection_holding_graph, graph})
          graph
        end
      )

    holder = Task.async(fn -> write(pool) end)
    assert_receive {:connection_holding_graph, graph}, 5_000
    assert_eventually(fn -> graph_value(graph, "holding") end)

    on_exit(fn -> release(graph) end)

    %{pool: pool, graph: graph, holder: holder}
  end

  defp connection_holding_graph(database) do
    {graph, _} =
      Pythonx.eval(
        """
        import asyncio

        class _ConnectionHoldingGraphiti:
            def __init__(self):
                self.gate = asyncio.Event()
                self.holding = False
                self.connection = database.connection

            async def add_episode(self, **kwargs):
                if self.holding:
                    await self.connection.ping()
                    return
                pool = self.connection.connection_pool
                held = await pool.get_connection()
                self.holding = True
                try:
                    await self.gate.wait()
                finally:
                    await pool.release(held)

        _ConnectionHoldingGraphiti()
        """,
        %{"database" => database}
      )

    graph
  end

  defp with_embedded_connections_held(timeout_ms, check) do
    data_dir =
      Path.join(System.tmp_dir!(), "gralkor_full_pool_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(data_dir) end)
    parent = self()

    pool =
      start_pool(
        falkordb_spec: {:embedded, data_dir},
        embedded_falkordb_socket_timeout_ms: timeout_ms,
        graph_operation_deadline_ms: 60_000,
        construct_instance: fn database, shared, group_id ->
          send(parent, {:embedded_database, database})
          driver_backed_graph(database, shared, group_id)
        end
      )

    GraphitiPool.for(pool, "deadlines")
    assert_received {:embedded_database, database}

    Gralkor.Python.run_coroutine(
      """
      async def hold_all():
          pool = database.client._client.connection_pool
          database._test_held_connections = []
          for _ in range(pool.max_connections):
              database._test_held_connections.append(await pool.get_connection())
      hold_all()
      """,
      %{"database" => database}
    )

    try do
      check.(pool, database)
    after
      release_embedded_connections(database, nil)
    end
  end

  defp release_embedded_connections(database, limit) do
    Gralkor.Python.run_coroutine(
      """
      async def release():
          pool = database.client._client.connection_pool
          held = database._test_held_connections
          count = len(held) if limit is None else limit
          for _ in range(count):
              await pool.release(held.pop())
      release()
      """,
      %{"database" => database, "limit" => limit}
    )
  end

  # Answers the connection handshake as a live server would, then never replies
  # to a graph command, as a deadlocked FalkorDB does.
  # Tells the test process `{:graph_command, data}` for each graph command it
  # receives.
  defp silent_server_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    test_pid = self()

    start_supervised!(%{
      id: :silent_server,
      start: {Task, :start_link, [fn -> accept_connections(listener, test_pid) end]}
    })

    on_exit(fn -> :gen_tcp.close(listener) end)

    port
  end

  defp accept_connections(listener, test_pid) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        connection = spawn_link(fn -> receive_commands(socket, test_pid) end)
        :ok = :gen_tcp.controlling_process(socket, connection)
        accept_connections(listener, test_pid)

      {:error, _reason} ->
        :ok
    end
  end

  defp receive_commands(socket, test_pid) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        if String.contains?(data, "GRAPH."),
          do: send(test_pid, {:graph_command, data}),
          else: reply_to_handshake(socket, data)

        receive_commands(socket, test_pid)

      {:error, _reason} ->
        :ok
    end
  end

  defp reply_to_handshake(socket, data) do
    data
    |> String.split(~r/(?=\*\d+\r\n\$)/, trim: true)
    |> Enum.each(fn command ->
      reply = if command =~ ~r/\$4\r\ninfo\r\n/i, do: "$0\r\n\r\n", else: "+OK\r\n"
      :ok = :gen_tcp.send(socket, reply)
    end)
  end

  defp start_pool(opts) do
    pool_opts =
      [
        name: Gralkor.GraphitiPool,
        table: :gralkor_graphiti_instances,
        construct_shared_clients: fn _spec ->
          %{llm_client: nil, embedder: nil, cross_encoder: nil}
        end,
        initialise_instance: fn _instance -> :ok end,
        warmup: false
      ]
      |> Keyword.merge(opts)

    start_supervised!({GraphitiPool, pool_opts})
  end

  defp start_application_pool do
    use_remote_application_backend()
    parent = self()

    application_pool_opts()
    |> Keyword.put(:construct_falkor_db, fn spec, socket_timeout, max_connections ->
      send(parent, {:constructed_falkordb, spec, socket_timeout, max_connections})
      :stub_falkor_db
    end)
    |> Keyword.put(:construct_instance, fn _database, _shared, _group_id -> nil end)
    |> start_pool()
  end

  defp application_pool_opts do
    {GraphitiPool, opts} =
      Enum.find(Gralkor.Application.children(), &match?({GraphitiPool, _opts}, &1))

    opts
  end

  defp use_remote_application_backend do
    {:remote, options} = @remote
    put_env_restored(:falkordb, options)
  end

  defp graph_value(graph, attribute) do
    {value, _} =
      Pythonx.eval("getattr(graph, attribute.decode('utf-8'))", %{
        "graph" => graph,
        "attribute" => attribute
      })

    Pythonx.decode(value)
  end

  defp assert_eventually(condition, attempts \\ 50)

  defp assert_eventually(_condition, 0), do: flunk("condition never held")

  defp assert_eventually(condition, attempts) do
    unless condition.() do
      Process.sleep(20)
      assert_eventually(condition, attempts - 1)
    end
  end

  defp put_env_restored(key, value) do
    original = Application.get_env(:jido_gralkor, key, :missing)
    Application.put_env(:jido_gralkor, key, value)
    on_exit(fn -> restore_env(key, original) end)
  end

  defp delete_env_restored(key) do
    original = Application.get_env(:jido_gralkor, key, :missing)
    Application.delete_env(:jido_gralkor, key)
    on_exit(fn -> restore_env(key, original) end)
  end

  defp restore_env(key, :missing), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
