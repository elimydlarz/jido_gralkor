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
        from graphiti_core.driver.falkordb_driver import FalkorDriver

        class _DriverBackedGraphiti:
            def __init__(self):
                self.driver = FalkorDriver(falkor_db=database, database=group_id.decode('utf-8'))

            async def add_episode(self, **kwargs):
                await self.driver.execute_query('RETURN 1')

        _DriverBackedGraphiti()
        """,
        %{"database" => database, "group_id" => group_id}
      )

    graph
  end

  # Answers the connection handshake as a live server would, then never replies
  # to a graph command, as a deadlocked FalkorDB does.
  defp silent_server_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    start_supervised!(%{
      id: :silent_server,
      start: {Task, :start_link, [fn -> accept_connections(listener) end]}
    })

    on_exit(fn -> :gen_tcp.close(listener) end)

    port
  end

  defp accept_connections(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        connection = spawn_link(fn -> receive_commands(socket) end)
        :ok = :gen_tcp.controlling_process(socket, connection)
        accept_connections(listener)

      {:error, _reason} ->
        :ok
    end
  end

  defp receive_commands(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        if String.contains?(data, "GRAPH."), do: :ok, else: reply_to_handshake(socket, data)
        receive_commands(socket)

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
