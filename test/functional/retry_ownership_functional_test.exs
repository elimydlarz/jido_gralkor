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
  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.GraphitiPool
  alias Gralkor.Message
  alias JidoGralkor.Runtime

  @moduletag :functional
  @moduletag timeout: 120_000

  defmodule ReflectionConsumerAgent do
    use Jido.Agent,
      name: "retry_ownership_reflection_consumer",
      default_plugins: false,
      plugins: [
        {JidoGralkor.Plugin,
         %{
           agent_name: "Retry Ownership Reflection Consumer",
           runtime_config: %{destinations: [], lenses: [], reflections: []}
         }}
      ]
  end

  defmodule ProbeStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_, _, _, _, _, _), do: {:ok, []}

    @impl true
    def put_artefact(output, reflection, operator, artefact) do
      send(test_pid(), {:destination_delivery, output, reflection, operator, artefact})
      :ok
    end

    @impl true
    def get_artefact(_, _, _, _), do: {:error, :not_found}

    defp test_pid,
      do: Application.fetch_env!(:jido_gralkor, :retry_ownership_reflection_test_pid)
  end

  defmodule RetryableStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_, _, _, _, _, _), do: {:ok, []}

    @impl true
    def put_artefact(_, _, _, artefact) do
      counter = Application.fetch_env!(:jido_gralkor, :retry_ownership_counter)
      :counters.add(counter, 1, 1)
      attempt = :counters.get(counter, 1)
      send(test_pid(), {:retryable_delivery, attempt, artefact})
      if attempt < 3, do: {:error, %{status: 503}}, else: :ok
    end

    @impl true
    def get_artefact(_, _, _, _), do: {:error, :not_found}

    defp test_pid,
      do: Application.fetch_env!(:jido_gralkor, :retry_ownership_reflection_test_pid)
  end

  defmodule AlwaysRetryableStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_, _, _, _, _, _), do: {:ok, []}

    @impl true
    def put_artefact(_, _, _, artefact) do
      send(test_pid(), {:retryable_delivery, artefact})
      {:error, %{status: 503, reason: :temporarily_unavailable}}
    end

    @impl true
    def get_artefact(_, _, _, _), do: {:error, :not_found}

    defp test_pid,
      do: Application.fetch_env!(:jido_gralkor, :retry_ownership_reflection_test_pid)
  end

  defmodule NonRetryableStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_, _, _, _, _, _), do: {:ok, []}

    @impl true
    def put_artefact(_, _, _, artefact) do
      send(test_pid(), {:non_retryable_delivery, artefact})
      {:error, %{status: 422, reason: :invalid_output}}
    end

    @impl true
    def get_artefact(_, _, _, _), do: {:error, :not_found}

    defp test_pid,
      do: Application.fetch_env!(:jido_gralkor, :retry_ownership_reflection_test_pid)
  end

  defmodule RelatedMemoryStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, _, _, _, _, _) do
      if destination.name == "global" do
        counter = Application.fetch_env!(:jido_gralkor, :retry_ownership_counter)
        :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        send(test_pid(), {:related_memory_attempt, attempt})
        if attempt == 1, do: {:error, %{status: 503}}, else: {:ok, []}
      else
        {:ok, []}
      end
    end

    @impl true
    def put_artefact(_, _, _, artefact) do
      send(test_pid(), {:generalisation_delivery, artefact})
      :ok
    end

    @impl true
    def get_artefact(_, _, _, _), do: {:error, :not_found}

    defp test_pid,
      do: Application.fetch_env!(:jido_gralkor, :retry_ownership_reflection_test_pid)
  end

  setup do
    # graphiti_core's own modules import each other; letting the first import
    # happen inside the shared loop thread surfaces as a circular-import error
    # rather than as the failure under test.
    :ok = Gralkor.Python.smoke_import_graphiti()

    original_client = Application.get_env(:jido_gralkor, :client)
    original_destination_storage = Application.get_env(:jido_gralkor, :destination_storage)
    original_test_pid = Application.get_env(:jido_gralkor, :retry_ownership_reflection_test_pid)
    original_counter = Application.get_env(:jido_gralkor, :retry_ownership_counter)
    Application.put_env(:jido_gralkor, :client, Native)
    Application.put_env(:jido_gralkor, :retry_ownership_reflection_test_pid, self())

    on_exit(fn ->
      case original_client do
        nil -> Application.delete_env(:jido_gralkor, :client)
        mod -> Application.put_env(:jido_gralkor, :client, mod)
      end

      restore_env(:retry_ownership_reflection_test_pid, original_test_pid)
      restore_env(:retry_ownership_counter, original_counter)
      restore_env(:destination_storage, original_destination_storage)
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

  describe "when Reflection production, packaged generalisation related-memory retrieval, or Destination delivery reports a retryable server failure" do
    test "then the failing boundary retries with exponential backoff" do
      assert_retryable_production()
      assert_retryable_related_memory()
      assert_retryable_delivery()
    end

    test "and another Reflection invocation continues independently" do
      agent = start_reflection_agent("independent-retry")
      assert :ok = Runtime.replace(agent, reflection_configuration())
      test_pid = self()
      attempts = :counters.new(1, [])

      slow_inference = fn _request ->
        :counters.add(attempts, 1, 1)

        if :counters.get(attempts, 1) == 1,
          do: {:error, %{status: 503}},
          else: {:ok, %{output: %{"summary" => "recovered"}}}
      end

      slow_sleep = fn delay ->
        send(test_pid, {:slow_retry_waiting, self(), delay})

        receive do
          :continue_retry -> :ok
        end
      end

      assert {:ok, "slow-retry"} =
               submit(agent, "review", invocation("slow-retry"),
                 inference: slow_inference,
                 storage: ProbeStorage,
                 sleep: slow_sleep
               )

      assert_receive {:slow_retry_waiting, slow_process, 1_000}

      assert {:ok, "independent"} =
               submit(agent, "review", invocation("independent"),
                 inference: fn _ -> {:ok, %{output: %{"summary" => "independent"}}} end,
                 storage: ProbeStorage
               )

      assert_receive {:reflection_callback, %{invocation_id: "independent", outcome: :delivered}}

      refute_receive {:reflection_callback, %{invocation_id: "slow-retry"}}
      send(slow_process, :continue_retry)

      assert_receive {:reflection_callback, %{invocation_id: "slow-retry", outcome: :delivered}}
    end
  end

  describe "when Reflection production, packaged generalisation related-memory retrieval, or Destination delivery reports a retryable server failure > while a later attempt succeeds" do
    test "then the invocation completes normally" do
      assert %{outcome: :delivered} = assert_retryable_delivery()
    end
  end

  describe "when Reflection production, packaged generalisation related-memory retrieval, or Destination delivery reports a retryable server failure > while no attempt succeeds within twenty-four hours of the first failure" do
    test "then the invocation abandons the failed work" do
      {_artefact, result} = retryable_delivery_abandonment("retryable-abandoned")
      assert {:abandoned, %{stage: :delivery}} = result.outcome
    end

    test "and no error artefact is written to the Reflection's Destination" do
      {artefact, _result} = retryable_delivery_abandonment("retryable-no-error-artefact")
      assert artefact.payload == %{"summary" => "complete"}
      refute_receive {:retryable_delivery, _}
    end

    test "and its callback receives the produced artefact, when one exists, and the abandonment outcome" do
      {artefact, result} = retryable_delivery_abandonment("retryable-callback")
      assert result.artefact == artefact
      assert {:abandoned, %{stage: :delivery, reason: %{status: 503}}} = result.outcome
    end
  end

  describe "when Reflection production or Destination delivery reports a non-retryable client failure" do
    test "then the invocation abandons the failed work without retry" do
      production = non_retryable_production("non-retryable-production")
      assert {:abandoned, %{stage: :production}} = production.outcome

      {_artefact, delivery} = non_retryable_delivery("non-retryable-delivery")
      assert {:abandoned, %{stage: :delivery}} = delivery.outcome
      refute_receive {:unexpected_retry_sleep, _}
    end

    test "and no error artefact is written to the Reflection's Destination" do
      {artefact, _result} = non_retryable_delivery("non-retryable-no-error-artefact")
      assert artefact.payload == %{"summary" => "complete"}
      refute_receive {:non_retryable_delivery, _}
    end

    test "and its callback receives the produced artefact, when one exists, and the abandonment outcome" do
      {artefact, result} = non_retryable_delivery("non-retryable-callback")
      assert result.artefact == artefact
      assert {:abandoned, %{stage: :delivery, reason: %{status: 422}}} = result.outcome
    end
  end

  describe "when a consuming agent terminates during Reflection work" do
    test "then that agent's unfinished work terminates with its Gralkor runtime" do
      %{worker_down?: worker_down?} = terminate_reflection_work("termination-owner")
      assert worker_down?
    end

    test "and the invocation callback is not invoked" do
      %{callback_received?: callback_received?} =
        terminate_reflection_work("termination-callback")

      refute callback_received?
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

  defp assert_retryable_production do
    agent = start_reflection_agent("retryable-production")
    assert :ok = Runtime.replace(agent, reflection_configuration())
    counter = :counters.new(1, [])
    test_pid = self()

    inference = fn _request ->
      :counters.add(counter, 1, 1)
      attempt = :counters.get(counter, 1)
      send(test_pid, {:production_attempt, attempt})

      if attempt < 3,
        do: {:error, %{status: 503}},
        else: {:ok, %{output: %{"summary" => "complete"}}}
    end

    assert {:ok, "retryable-production"} =
             submit(agent, "review", invocation("retryable-production"),
               inference: inference,
               storage: ProbeStorage,
               sleep: &send(test_pid, {:retry_backoff, &1})
             )

    assert_receive {:production_attempt, 1}
    assert_receive {:retry_backoff, 1_000}
    assert_receive {:production_attempt, 2}
    assert_receive {:retry_backoff, 2_000}
    assert_receive {:production_attempt, 3}

    assert_receive {:reflection_callback,
                    %{invocation_id: "retryable-production", outcome: :delivered}}
  end

  defp assert_retryable_related_memory do
    Application.put_env(:jido_gralkor, :destination_storage, RelatedMemoryStorage)
    Application.put_env(:jido_gralkor, :retry_ownership_counter, :counters.new(1, []))
    agent = start_reflection_agent("retryable-related-memory")
    test_pid = self()

    inference = fn
      %{step: %{label: "inspect-world"}} ->
        {:ok, %{output: %{"inspection" => "reviewed"}}}

      %{step: %{label: "evolve-generalisations"}} ->
        {:ok, %{output: %{"generalisations" => []}}}
    end

    assert {:ok, "retryable-related-memory"} =
             submit(agent, "generalisations", invocation("retryable-related-memory"),
               inference: inference,
               storage: RelatedMemoryStorage,
               sleep: &send(test_pid, {:retry_backoff, &1})
             )

    assert_receive {:related_memory_attempt, 1}
    assert_receive {:retry_backoff, 1_000}
    assert_receive {:related_memory_attempt, 2}

    assert_receive {:reflection_callback,
                    %{invocation_id: "retryable-related-memory", outcome: :delivered}}
  end

  defp assert_retryable_delivery do
    Application.put_env(:jido_gralkor, :retry_ownership_counter, :counters.new(1, []))
    agent = start_reflection_agent("retryable-delivery-#{System.unique_integer([:positive])}")
    assert :ok = Runtime.replace(agent, reflection_configuration())
    test_pid = self()
    invocation_id = "retryable-delivery-#{System.unique_integer([:positive])}"

    assert {:ok, ^invocation_id} =
             submit(agent, "review", invocation(invocation_id),
               inference: fn _ -> {:ok, %{output: %{"summary" => "complete"}}} end,
               storage: RetryableStorage,
               sleep: &send(test_pid, {:retry_backoff, &1})
             )

    assert_receive {:retryable_delivery, 1, artefact}
    assert_receive {:retry_backoff, 1_000}
    assert_receive {:retryable_delivery, 2, ^artefact}
    assert_receive {:retry_backoff, 2_000}
    assert_receive {:retryable_delivery, 3, ^artefact}
    assert_receive {:reflection_callback, %{invocation_id: ^invocation_id} = result}
    result
  end

  defp retryable_delivery_abandonment(invocation_id) do
    agent = start_reflection_agent(invocation_id)
    assert :ok = Runtime.replace(agent, reflection_configuration())
    clock = :atomics.new(1, [])

    assert {:ok, ^invocation_id} =
             submit(agent, "review", invocation(invocation_id),
               inference: fn _ -> {:ok, %{output: %{"summary" => "complete"}}} end,
               storage: AlwaysRetryableStorage,
               clock: fn -> :atomics.get(clock, 1) end,
               sleep: fn _ -> :atomics.put(clock, 1, 86_400_000) end
             )

    assert_receive {:retryable_delivery, artefact}
    assert_receive {:reflection_callback, %{invocation_id: ^invocation_id} = result}
    refute_receive {:retryable_delivery, _}
    {artefact, result}
  end

  defp non_retryable_production(invocation_id) do
    agent = start_reflection_agent(invocation_id)
    assert :ok = Runtime.replace(agent, reflection_configuration())
    test_pid = self()

    assert {:ok, ^invocation_id} =
             submit(agent, "review", invocation(invocation_id),
               inference: fn _ -> {:error, %{status: 422, reason: :invalid_request}} end,
               storage: ProbeStorage,
               sleep: &send(test_pid, {:unexpected_retry_sleep, &1})
             )

    assert_receive {:reflection_callback, %{invocation_id: ^invocation_id} = result}
    refute_receive {:destination_delivery, _, _, _, _}
    result
  end

  defp non_retryable_delivery(invocation_id) do
    agent = start_reflection_agent(invocation_id)
    assert :ok = Runtime.replace(agent, reflection_configuration())
    test_pid = self()

    assert {:ok, ^invocation_id} =
             submit(agent, "review", invocation(invocation_id),
               inference: fn _ -> {:ok, %{output: %{"summary" => "complete"}}} end,
               storage: NonRetryableStorage,
               sleep: &send(test_pid, {:unexpected_retry_sleep, &1})
             )

    assert_receive {:non_retryable_delivery, artefact}
    assert_receive {:reflection_callback, %{invocation_id: ^invocation_id} = result}
    {artefact, result}
  end

  defp terminate_reflection_work(id) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      {:ok, agent} =
        Jido.AgentServer.start_link(
          agent: ReflectionConsumerAgent,
          id: id,
          register_global: false
        )

      assert :ok = Runtime.replace(agent, reflection_configuration())
      test_pid = self()

      inference = fn _request ->
        send(test_pid, {:unfinished_reflection, self()})

        receive do
          :never -> {:ok, %{output: %{"summary" => "impossible"}}}
        end
      end

      assert {:ok, ^id} =
               submit(agent, "review", invocation(id),
                 inference: inference,
                 storage: ProbeStorage
               )

      assert_receive {:unfinished_reflection, worker}
      monitor = Process.monitor(worker)
      Process.exit(agent, :shutdown)

      worker_down? =
        receive do: ({:DOWN, ^monitor, :process, ^worker, _} -> true), after: (500 -> false)

      callback_received? =
        receive do: ({:reflection_callback, %{invocation_id: ^id}} -> true), after: (50 -> false)

      %{worker_down?: worker_down?, callback_received?: callback_received?}
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp start_reflection_agent(id) do
    start_supervised!(
      Supervisor.child_spec(
        {Jido.AgentServer, agent: ReflectionConsumerAgent, id: id, register_global: false},
        id: {:retry_ownership_agent, id}
      )
    )
  end

  defp submit(agent, name, invocation, opts) do
    test_pid = self()
    Client.reflect(agent, name, invocation, &send(test_pid, {:reflection_callback, &1}), opts)
  end

  defp reflection_configuration do
    %{
      destinations: [%{name: "reviews"}],
      lenses: [],
      reflections: [
        %{
          name: "review",
          outputs: [%{kind: :destination, destination: "reviews"}],
          chain_of_thought: %{
            steps: [
              %{
                label: "review",
                directions: "Review.",
                output: %{"summary" => "string"}
              }
            ]
          }
        }
      ]
    }
  end

  defp invocation(id) do
    %{id: id, operator_id: "operator-one", invocation_context: %{}, representations: []}
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
