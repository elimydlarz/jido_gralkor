defmodule Gralkor.EmbeddedMemoryWritesFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client.Native
  alias Gralkor.GraphitiPool

  @moduletag :functional
  @moduletag timeout: 120_000

  setup do
    :ok = Gralkor.Python.smoke_import_graphiti()

    original_client = Application.get_env(:jido_gralkor, :client)
    Application.put_env(:jido_gralkor, :client, Native)

    on_exit(fn ->
      case original_client do
        nil -> Application.delete_env(:jido_gralkor, :client)
        module -> Application.put_env(:jido_gralkor, :client, module)
      end
    end)

    :ok
  end

  describe "when several episode writes overlap through one embedded runtime > while the graph accepts every write" do
    test "then one episode write reaches the graph at a time" do
      %{graph: graph, pool: pool} = start_pool(:embedded)
      GraphitiPool.for(pool, "owner")

      overlapping_writes()

      assert graph_value(graph, "max_active_writes") == 1
    end

    test "and every caller receives success" do
      %{pool: pool} = start_pool(:embedded)
      GraphitiPool.for(pool, "owner")

      assert Enum.all?(overlapping_writes(), &(&1 == {:ok, :ok}))
    end
  end

  describe "when a memory search overlaps an episode write through one embedded runtime > while the graph accepts the search" do
    test "then the search reaches the graph without waiting for episode write admission" do
      %{graph: graph, pool: pool} = start_pool(:embedded)
      GraphitiPool.for(pool, "owner")

      overlap = overlap_search_with_write(pool, graph)

      assert overlap.write_result == :ok
      assert graph_value(graph, "searches_during_write") == 1
    end

    test "and the caller receives the search result" do
      %{graph: graph, pool: pool} = start_pool(:embedded)
      GraphitiPool.for(pool, "owner")

      overlap = overlap_search_with_write(pool, graph)

      assert overlap.search_result ==
               {:ok,
                [
                  %{
                    fact: "search completed",
                    created_at: nil,
                    valid_at: nil,
                    invalid_at: nil,
                    expired_at: nil
                  }
                ]}
    end
  end

  describe "when several episode writes overlap through one remote runtime > while the graph accepts every write" do
    test "then more than one episode write may reach the remote graph concurrently" do
      %{graph: graph, pool: pool} = start_pool(:remote)
      GraphitiPool.for(pool, "owner")

      overlapping_writes()

      assert graph_value(graph, "max_active_writes") > 1
    end

    test "and every caller receives success" do
      %{pool: pool} = start_pool(:remote)
      GraphitiPool.for(pool, "owner")

      assert Enum.all?(overlapping_writes(), &(&1 == {:ok, :ok}))
    end
  end

  describe "when the embedded runtime starts > while no embedded FalkorDB socket read timeout is configured" do
    test "then the embedded connection uses a sixty-second socket read timeout" do
      delete_env_restored(:embedded_falkordb_socket_timeout_ms)

      start_application_pool()

      assert_receive {:constructed_falkordb, {:embedded, _data_dir}, 60.0}
    end
  end

  describe "when the embedded runtime starts > while a positive `:embedded_falkordb_socket_timeout_ms` is configured" do
    test "then the embedded connection uses that timeout" do
      put_env_restored(:embedded_falkordb_socket_timeout_ms, 90_000)

      start_application_pool()

      assert_receive {:constructed_falkordb, {:embedded, _data_dir}, 90.0}
    end
  end

  describe "if `:embedded_falkordb_socket_timeout_ms` is not a positive integer" do
    test "then application startup raises naming the setting and its offending value" do
      use_embedded_application_backend()

      Enum.each([0, -1, "60000"], fn invalid ->
        put_env_restored(:embedded_falkordb_socket_timeout_ms, invalid)

        assert_raise ArgumentError,
                     ~r/embedded_falkordb_socket_timeout_ms.*#{Regex.escape(inspect(invalid))}/,
                     fn -> Gralkor.Application.children() end
      end)
    end
  end

  defp start_pool(backend, opts \\ []) do
    {graph, _} =
      Pythonx.eval(
        """
        import asyncio

        class _FakeGraphiti:
            def __init__(self):
                self.active_writes = 0
                self.max_active_writes = 0
                self.searches_during_write = 0
                self.write_started = asyncio.Event()
                self.release_write = asyncio.Event()
                self.hold_write = False

            async def add_episode(self, **kwargs):
                self.active_writes += 1
                self.max_active_writes = max(self.max_active_writes, self.active_writes)
                self.write_started.set()
                try:
                    if self.hold_write:
                        await self.release_write.wait()
                    else:
                        await asyncio.sleep(0.1)
                finally:
                    self.active_writes -= 1

            async def search(self, *args, **kwargs):
                if self.active_writes:
                    self.searches_during_write += 1
                edge = type('_Edge', (), {})()
                edge.fact = 'search completed'
                edge.created_at = None
                edge.valid_at = None
                edge.invalid_at = None
                edge.expired_at = None
                return [edge]

            async def build_indices_and_constraints(self):
                pass

        _FakeGraphiti()
        """,
        %{}
      )

    pool_opts =
      [
        name: Gralkor.GraphitiPool,
        table: :gralkor_graphiti_instances,
        falkordb_spec: backend_spec(backend),
        construct_falkor_db: fn _spec -> :stub_falkor_db end,
        construct_shared_clients: fn _spec ->
          %{llm_client: nil, embedder: nil, cross_encoder: nil}
        end,
        construct_instance: fn _database, _shared, _group_id -> graph end,
        initialise_instance: fn _instance -> :ok end,
        warmup: false,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      ]
      |> Keyword.merge(opts)

    pool = start_supervised!({GraphitiPool, pool_opts})

    %{graph: graph, pool: pool}
  end

  defp backend_spec(:embedded), do: {:embedded, "/tmp/never_used"}
  defp backend_spec(:remote), do: {:remote, host: "falkor.example", port: 6379}

  defp overlapping_writes do
    1..6
    |> Task.async_stream(
      fn index -> Native.memory_add("owner", "episode #{index}", "manual") end,
      max_concurrency: 6,
      ordered: false,
      timeout: 5_000
    )
    |> Enum.to_list()
  end

  defp overlap_search_with_write(pool, graph) do
    Pythonx.eval("graph.hold_write = True", %{"graph" => graph})
    write = Task.async(fn -> Native.memory_add("owner", "episode", "manual") end)

    try do
      Pythonx.eval(
        "import asyncio\nasyncio._gralkor_run(asyncio.wait_for(graph.write_started.wait(), 5))",
        %{
          "graph" => graph
        }
      )

      search = Task.async(fn -> GraphitiPool.search(pool, "owner", "query", 10) end)

      search_result =
        case Task.yield(search, 5_000) do
          {:ok, result} ->
            result

          nil ->
            Task.shutdown(search, :brutal_kill)
            flunk("search did not complete while episode write was active")
        end

      Pythonx.eval(
        "import asyncio\nasyncio._gralkor_loop.call_soon_threadsafe(graph.release_write.set)",
        %{
          "graph" => graph
        }
      )

      %{search_result: search_result, write_result: Task.await(write, 5_000)}
    after
      Pythonx.eval(
        "import asyncio\nasyncio._gralkor_loop.call_soon_threadsafe(graph.release_write.set)",
        %{
          "graph" => graph
        }
      )

      Task.shutdown(write, :brutal_kill)
    end
  end

  defp start_application_pool do
    use_embedded_application_backend()
    parent = self()

    {GraphitiPool, application_opts} =
      Enum.find(Gralkor.Application.children(), &match?({GraphitiPool, _opts}, &1))

    start_pool(
      :embedded,
      Keyword.put(application_opts, :construct_falkor_db, fn spec, socket_timeout ->
        send(parent, {:constructed_falkordb, spec, socket_timeout})
        :stub_falkor_db
      end)
    )
  end

  defp use_embedded_application_backend do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "embedded-writes-#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    original_data_dir = System.get_env("GRALKOR_DATA_DIR")
    System.put_env("GRALKOR_DATA_DIR", data_dir)

    on_exit(fn ->
      case original_data_dir do
        nil -> System.delete_env("GRALKOR_DATA_DIR")
        value -> System.put_env("GRALKOR_DATA_DIR", value)
      end

      File.rm_rf!(data_dir)
    end)

    delete_env_restored(:falkordb)
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

  defp graph_value(graph, key) do
    {value, _} =
      Pythonx.eval(
        "getattr(graph, key.decode('utf-8') if isinstance(key, bytes) else key)",
        %{"graph" => graph, "key" => key}
      )

    Pythonx.decode(value)
  end
end
