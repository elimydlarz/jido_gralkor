defmodule Gralkor.RetryOwnershipFunctionalTest do
  @moduledoc """
  Where each failure class is retried, proved at the seams Gralkor owns.

  Two of the retries named in the tree belong to dependencies rather than to
  this package — ReqLLM absorbs a rate-limited provider response, and
  graphiti-core re-prompts its own extractor on unparseable output. What
  Gralkor guarantees, and what this suite proves, is that no layer of its own
  adds a second retry on top of either, that the capture buffer is the one
  layer that does retry a write, and that a call outside a capture chain gets
  exactly one attempt.

  Reifies the `retry-ownership` tree.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client.Native
  alias Gralkor.GraphitiPool
  alias Gralkor.Interpret
  alias Gralkor.InterpretParseFailed
  alias Gralkor.Message

  @moduletag :functional
  @moduletag timeout: 120_000

  setup do
    original_client = Application.get_env(:jido_gralkor, :client)
    Application.put_env(:jido_gralkor, :client, Native)

    on_exit(fn ->
      case original_client do
        nil -> Application.delete_env(:jido_gralkor, :client)
        mod -> Application.put_env(:jido_gralkor, :client, mod)
      end
    end)

    :ok
  end

  defp start_pool do
    {g, _} =
      Pythonx.eval(
        """
        class _Results:
            def __init__(self):
                self.nodes = []
                self.episodes = []

        class _FakeGraphiti:
            def __init__(self):
                self.attempts = {"add": 0, "search": 0}

            async def add_episode(self, **kwargs):
                self.attempts["add"] += 1
                raise RuntimeError("graph refused the write")

            async def build_indices_and_constraints(self):
                pass

            async def search(self, query, num_results=10, search_filter=None):
                self.attempts["search"] += 1
                import asyncio
                await asyncio.sleep(0.3)
                return []

            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                return _Results()

        _FakeGraphiti()
        """,
        %{}
      )

    {:ok, pool} =
      GraphitiPool.start_link(
        name: Gralkor.GraphitiPool,
        table: :gralkor_graphiti_instances,
        falkordb_spec: {:embedded, "/tmp/never_used"},
        construct_falkor_db: fn _spec -> :stub_falkor_db end,
        construct_shared_clients: fn _llm, _embedder ->
          %{llm_client: nil, embedder: nil, cross_encoder: nil}
        end,
        construct_instance: fn _db, _shared, _group_id -> g end,
        warmup: false,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      )

    on_exit(fn -> if Process.alive?(pool), do: GenServer.stop(pool) end)

    %{g: g, pool: pool}
  end

  defp attempts(g, key) do
    {raw, _} = Pythonx.eval("g.attempts[key]", %{"g" => g, "key" => key})
    Pythonx.decode(raw)
  end

  defp counting_buffer(result_fn) do
    counter = :counters.new(1, [])
    test_pid = self()

    callback = fn _group, _agent, _user, _ontology, _turns ->
      :counters.add(counter, 1, 1)
      send(test_pid, {:attempt, :counters.get(counter, 1), System.monotonic_time(:millisecond)})
      result_fn.(:counters.get(counter, 1))
    end

    start_supervised!({CaptureBuffer, flush_callback: callback, retries: [1_000, 2_000, 4_000]})

    counter
  end

  describe "retry-ownership > when the configured inference provider rejects a call as rate-limited" do
    test "then no memory endpoint or call site retries it a second time, and it surfaces immediately" do
      counter = counting_buffer(fn _n -> {:error, {:upstream_llm, :rate_limited}} end)

      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      logs =
        capture_log(fn ->
          :ok = Native.flush("s1")
          assert_receive {:attempt, 1, _}, 1_000
          refute_receive {:attempt, 2, _}, 1_500
        end)

      assert :counters.get(counter, 1) == 1
      assert logs =~ "upstream error"
    end
  end

  describe "retry-ownership > when the configured inference provider fails a call for a reason other than rate-limiting" do
    test "then no layer retries it and the failure surfaces as it was returned" do
      counter = counting_buffer(fn _n -> {:error, {:upstream_llm, :bad_request}} end)

      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      assert {:error, {:upstream_llm, :bad_request}} = Native.flush_and_await("s1", 2_000)
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "retry-ownership > when the inference provider returns output that cannot be parsed into the requested structure" do
    test "then no layer above the parse retries it, the failure being raised at the boundary that saw it" do
      counter = :counters.new(1, [])

      interpret_fn = fn _prompt, _budget ->
        :counters.add(counter, 1, 1)
        {:ok, %{not: "a list of strings"}}
      end

      assert_raise InterpretParseFailed, fn ->
        Interpret.interpret_facts([], "what do we know", "- a fact", interpret_fn, "Susu")
      end

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "retry-ownership > when a write to the graph fails inside a capture chain" do
    test "then the capture buffer owns the retry and backs off across one, two, and four seconds" do
      counter = counting_buffer(fn n -> if n < 3, do: raise("graph unavailable"), else: :ok end)

      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      capture_log(fn ->
        :ok = Native.flush("s1")

        assert_receive {:attempt, 1, first}, 1_000
        assert_receive {:attempt, 2, second}, 3_000
        assert_receive {:attempt, 3, third}, 5_000

        assert second - first >= 900
        assert third - second >= 1_900
      end)

      assert :counters.get(counter, 1) == 3
    end

    test "and no layer above the capture buffer retries it" do
      counter = counting_buffer(fn _n -> {:error, :capture_client_4xx} end)

      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      capture_log(fn ->
        assert {:error, :capture_client_4xx} = Native.flush_and_await("s1", 2_000)
      end)

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "retry-ownership > when a write to the graph fails outside a capture chain" do
    test "then no layer retries it and the failure surfaces to the caller immediately" do
      %{g: g} = start_pool()

      assert {:error, {:python, reason}} = Native.memory_add("g1", "content", "manual")
      assert reason =~ "graph refused the write"

      assert attempts(g, "add") == 1
    end
  end

  describe "retry-ownership > when the consumer's own outermost budget expires" do
    test "then the consumer returns without retrying, and the expiry is logged as a warning" do
      %{g: g} = start_pool()

      original = Application.get_env(:jido_gralkor, :recall_deadline_ms)
      Application.put_env(:jido_gralkor, :recall_deadline_ms, 50)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_gralkor, :recall_deadline_ms)
          v -> Application.put_env(:jido_gralkor, :recall_deadline_ms, v)
        end
      end)

      logs =
        capture_log(fn ->
          assert {:error, :recall_deadline_expired} =
                   Native.recall("g1", "TestAgent", nil, "what do we know")
        end)

      assert logs =~ "recall deadline expired"

      Process.sleep(500)
      assert attempts(g, "search") == 1
    end
  end
end
