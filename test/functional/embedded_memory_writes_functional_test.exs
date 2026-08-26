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

  defp start_pool(backend) do
    {graph, _} =
      Pythonx.eval(
        """
        import asyncio

        class _FakeGraphiti:
            def __init__(self):
                self.active_writes = 0
                self.max_active_writes = 0

            async def add_episode(self, **kwargs):
                self.active_writes += 1
                self.max_active_writes = max(self.max_active_writes, self.active_writes)
                await asyncio.sleep(0.1)
                self.active_writes -= 1

            async def build_indices_and_constraints(self):
                pass

        _FakeGraphiti()
        """,
        %{}
      )

    {:ok, pool} =
      GraphitiPool.start_link(
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
      )

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

  defp graph_value(graph, key) do
    {value, _} =
      Pythonx.eval(
        "getattr(graph, key.decode('utf-8') if isinstance(key, bytes) else key)",
        %{"graph" => graph, "key" => key}
      )

    Pythonx.decode(value)
  end
end
