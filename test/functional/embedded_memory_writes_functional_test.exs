defmodule Gralkor.EmbeddedMemoryWritesFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client.Native
  alias Gralkor.Config
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

  describe "when the embedded runtime starts" do
    test "while no embedded FalkorDB socket read timeout is configured then the embedded connection uses a sixty-second socket read timeout" do
      delete_env_restored(:embedded_falkordb_socket_timeout_ms)

      assert Config.embedded_falkordb_socket_timeout_ms() == 60_000
    end

    test "while a positive :embedded_falkordb_socket_timeout_ms is configured then the embedded connection uses that timeout" do
      put_env_restored(:embedded_falkordb_socket_timeout_ms, 90_000)
      parent = self()

      start_pool(:embedded,
        embedded_falkordb_socket_timeout_ms: Config.embedded_falkordb_socket_timeout_ms(),
        construct_falkor_db: fn spec, socket_timeout ->
          send(parent, {:constructed_falkordb, spec, socket_timeout})
          :stub_falkor_db
        end
      )

      assert_receive {:constructed_falkordb, {:embedded, "/tmp/never_used"}, 90.0}
    end
  end

  describe "if :embedded_falkordb_socket_timeout_ms is not a positive integer" do
    test "then application startup raises naming the setting and its offending value" do
      Enum.each([0, -1, "60000"], fn invalid ->
        put_env_restored(:embedded_falkordb_socket_timeout_ms, invalid)

        assert_raise ArgumentError,
                     ~r/embedded_falkordb_socket_timeout_ms.*#{Regex.escape(inspect(invalid))}/,
                     fn -> Config.embedded_falkordb_socket_timeout_ms() end
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

            async def add_episode(self, **kwargs):
                self.active_writes += 1
                self.max_active_writes = max(self.max_active_writes, self.active_writes)
                await asyncio.sleep(0.1)
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
        construct_shared_clients: fn _llm, _embedder ->
          %{llm_client: nil, embedder: nil, cross_encoder: nil}
        end,
        construct_instance: fn _database, _shared, _group_id -> graph end,
        initialise_instance: fn _instance -> :ok end,
        warmup: false,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      ]
      |> Keyword.merge(opts)

    {:ok, pool} = GraphitiPool.start_link(pool_opts)

    on_exit(fn -> if Process.alive?(pool), do: GenServer.stop(pool) end)

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
    write = Task.async(fn -> Native.memory_add("owner", "episode", "manual") end)
    assert_eventually(fn -> graph_value(graph, "active_writes") == 1 end)
    search_result = GraphitiPool.search(pool, "owner", "query", 10)
    %{search_result: search_result, write_result: Task.await(write, 5_000)}
  end

  defp assert_eventually(assertion, attempts \\ 100)

  defp assert_eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp assert_eventually(_assertion, 0), do: flunk("condition did not become true")

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
