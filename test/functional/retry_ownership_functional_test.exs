defmodule Gralkor.RetryOwnershipFunctionalTest do
  @moduledoc """
  Where each failure class is retried, proved at the seams Gralkor owns.

  Gralkor does not retry returned upstream failures. The capture buffer is the
  one layer that retries a raised write, and a call outside a capture chain
  gets exactly one attempt.

  Reifies the `retry-ownership` tree.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client.Native
  alias Gralkor.Destination
  alias Gralkor.GraphitiPool
  alias Gralkor.Message
  alias Gralkor.Reflection
  alias Gralkor.Artefact
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.Scheduler

  @moduletag :functional
  @moduletag timeout: 120_000

  defmodule FailOnceReflectionStore do
    use Agent

    def start_link(test_pid), do: Agent.start_link(fn -> {test_pid, 0} end, name: __MODULE__)

    def get_artefact(_output, _reflection_name, _operator_id, _artefact_id),
      do: {:error, :not_found}

    def put_artefact(_output, _reflection_name, _operator_id, artefact) do
      Agent.get_and_update(__MODULE__, fn {test_pid, attempts} ->
        attempt = attempts + 1
        send(test_pid, {:reflection_store_attempt, attempt, artefact})

        outcome = if attempt == 1, do: {:error, :temporary_store_failure}, else: :ok
        {outcome, {test_pid, attempt}}
      end)
    end
  end

  setup do
    # graphiti_core's own modules import each other; letting the first import
    # happen inside the shared loop thread surfaces as a circular-import error
    # rather than as the failure under test.
    :ok = Gralkor.Python.smoke_import_graphiti()

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
        import asyncio

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
    {raw, _} =
      Pythonx.eval(
        "g.attempts[key.decode('utf-8') if isinstance(key, bytes) else key]",
        %{"g" => g, "key" => key}
      )

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

    start_supervised!({CaptureBuffer, flush_callback: callback})

    counter
  end

  describe "when a capture callback returns an upstream rate-limit failure" do
    test "then the capture buffer does not retry the returned failure and logs it" do
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

  describe "when a capture callback returns another upstream failure" do
    test "then the capture buffer does not retry it and returns it unchanged" do
      counter = counting_buffer(fn _n -> {:error, {:upstream_llm, :bad_request}} end)

      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      assert {:error, {:upstream_llm, :bad_request}} = Native.flush_and_await("s1", 2_000)
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "when a graph write raises inside a capture chain" do
    test "then the capture buffer retries with its default one-second and two-second backoffs" do
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

    test "and a returned write failure is not retried by a second layer" do
      counter = counting_buffer(fn _n -> {:error, :capture_client_4xx} end)

      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      capture_log(fn ->
        assert {:error, :capture_client_4xx} = Native.flush_and_await("s1", 2_000)
      end)

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "when a graph write fails outside a capture chain" do
    test "then the direct caller receives the failure after one attempt" do
      %{g: g} = start_pool()

      assert {:error, {:python, reason}} = Native.memory_add("g1", "content", "manual")
      assert reason =~ "graph refused the write"

      assert attempts(g, "add") == 1
    end
  end

  describe "when a Reflection Runner or Destination output write fails after completed Lens ingestion" do
    test "then only the Reflection Scheduler retries those phases" do
      test_pid = self()
      runner_attempts = :atomics.new(1, [])
      lens_attempts = :atomics.new(1, [])

      reflection = %Reflection{
        name: "retry-owner",
        triggers: [{:lens_ingestion, :any}],
        outputs: [
          %{
            kind: :destination,
            destination: %Destination{name: "observations"},
            ontology: Gralkor.DefaultOntology
          }
        ],
        chain_of_thought: %ChainOfThought{path: "test", steps: []}
      }

      runner = fn _reflection, _ingestion, opts ->
        attempt = :atomics.add_get(runner_attempts, 1, 1)
        send(test_pid, {:reflection_runner_attempt, attempt})

        if attempt == 1 do
          {:error, :temporary_runner_failure}
        else
          {:ok,
           Artefact.new(
             opts[:artefact_id],
             %{"summary" => "stored"}
           )}
        end
      end

      start_supervised!({FailOnceReflectionStore, test_pid})

      start_supervised!(
        {Scheduler,
         runner: runner,
         store_opts: [storage: FailOnceReflectionStore],
         notify: test_pid,
         retry_delays: [0]}
      )

      lens_flush_callback = fn _operator, _agent, _user, lens, _turns, _ingestion_id ->
        attempt = :atomics.add_get(lens_attempts, 1, 1)
        send(test_pid, {:lens_ingestion_attempt, attempt})
        {:ok, %{id: "representation-one", lens: lens, result: :ok}}
      end

      start_supervised!(
        {CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: lens_flush_callback,
         reflections: [reflection],
         retries: []}
      )

      assert :ok =
               CaptureBuffer.append_lens(
                 "reflection-retry-owner",
                 "operator-one",
                 "Susu",
                 "Eli",
                 "observations",
                 [Message.new("user", "remember")]
               )

      assert :ok = CaptureBuffer.flush_and_await("reflection-retry-owner", 2_000)
      assert_receive {:lens_ingestion_attempt, 1}
      assert_receive {:reflection_runner_attempt, 1}
      assert_receive {:reflection_runner_attempt, 2}
      assert_receive {:reflection_store_attempt, 1, artefact}
      assert_receive {:reflection_store_attempt, 2, ^artefact}
      assert_receive {:reflection_completed, "retry-owner", {:ok, ^artefact}}

      assert :atomics.get(lens_attempts, 1) == 1
      assert :atomics.get(runner_attempts, 1) == 2
    end
  end

  describe "when recall's outermost deadline expires" do
    test "then recall returns without retrying and logs the expiry as a warning" do
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
