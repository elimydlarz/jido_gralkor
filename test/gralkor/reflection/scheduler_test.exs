defmodule Gralkor.Reflection.SchedulerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.Destination
  alias Gralkor.Reflection
  alias Gralkor.Reflection.Artefact
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.Journal
  alias Gralkor.Reflection.Scheduler
  alias Gralkor.Reflection.Storage.InMemory

  defmodule EmptyStore do
    @behaviour Gralkor.Reflection.Store

    @impl true
    def get(_reflection, _operator_id, _artefact_id), do: {:error, :not_found}

    @impl true
    def put(_reflection, _operator_id, _artefact), do: :ok
  end

  defmodule ControlledStore do
    @behaviour Gralkor.Reflection.Store

    use Agent

    def start_link({test_pid, get_outcomes, put_outcomes}) do
      Agent.start_link(
        fn -> %{test_pid: test_pid, get: get_outcomes, put: put_outcomes} end,
        name: __MODULE__
      )
    end

    @impl true
    def get(_reflection, _operator_id, artefact_id) do
      {test_pid, outcome} = take(:get)
      send(test_pid, {:store_get, artefact_id, self()})
      perform(outcome)
    end

    @impl true
    def put(_reflection, _operator_id, artefact) do
      {test_pid, outcome} = take(:put)
      send(test_pid, {:store_put, artefact, self()})
      perform(outcome)
    end

    defp take(stage) do
      Agent.get_and_update(__MODULE__, fn state ->
        [outcome | remaining] = Map.fetch!(state, stage)
        {{state.test_pid, outcome}, Map.put(state, stage, remaining)}
      end)
    end

    defp perform(:ok), do: :ok
    defp perform({:ok, artefact}), do: {:ok, artefact}
    defp perform({:error, reason}), do: {:error, reason}
    defp perform(:crash), do: raise("storage crashed")

    defp perform(:hang) do
      receive do
        :release -> :ok
      end
    end
  end

  describe "when the Scheduler starts without execution overrides" do
    test "then it uses one-, two-, and four-second retries and a sixty-second timeout" do
      name = scheduler_name()
      start_scheduler(name, runner: elem(immediate_runner(self()), 1))

      defaults = :sys.get_state(name).defaults
      assert defaults[:retry_delays] == [1_000, 2_000, 4_000]
      assert defaults[:execution_timeout_ms] == 60_000
    end
  end

  describe "when completed ingestion schedules distinct Reflections" do
    test "then each logical completion receives a stable and distinct deterministic UUID" do
      id = Artefact.id_for("operator-one", "ingestion-one", "review")

      assert id == Artefact.id_for("operator-one", "ingestion-one", "review")
      assert id != Artefact.id_for("operator-two", "ingestion-one", "review")
      assert id != Artefact.id_for("operator-one", "ingestion-two", "review")
      assert id != Artefact.id_for("operator-one", "ingestion-one", "summary")
      assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end
  end

  describe "when several Reflections share one ingestion" do
    test "then a failed Runner retries independently with the same artefact identifier" do
      test_pid = self()
      name = Module.concat(__MODULE__, "Scheduler#{System.unique_integer([:positive])}")

      runner = fn reflection, _ingestion, opts ->
        send(test_pid, {:runner, reflection.name, opts[:artefact_id], self()})

        receive do
          :fail -> {:error, :temporary}
          :succeed -> {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{})}
        end
      end

      start_supervised!(
        {Scheduler,
         name: name,
         runner: runner,
         store_opts: [storage: EmptyStore],
         retry_delays: [0],
         notify: test_pid}
      )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review"), reflection("summary")], ingestion(),
                 server: name
               )

      runners = receive_runners(2, %{})
      {review_id, review_runner} = Map.fetch!(runners, "review")
      {summary_id, summary_runner} = Map.fetch!(runners, "summary")
      send(review_runner, :succeed)
      send(summary_runner, :fail)

      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
      assert_receive {:reflection_retrying, "summary", %{stage: :runner, reason: :temporary}}
      assert_receive {:runner, "summary", ^summary_id, retry_runner}
      refute_receive {:runner, "review", ^review_id, _runner}

      send(retry_runner, :succeed)
      assert_receive {:reflection_completed, "summary", {:ok, _artefact}}
    end

    test "then a newly added Reflection runs without disturbing a completed sibling" do
      start_supervised!(InMemory)
      {name, runner} = immediate_runner(self())
      start_scheduler(name, runner: runner, store_opts: [storage: InMemory], notify: self())

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:runner_invoked, review_id}
      assert_receive {:reflection_completed, "review", {:ok, %{id: ^review_id}}}

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review"), reflection("summary")], ingestion(),
                 server: name
               )

      assert_receive {:reflection_completed, "review", {:ok, %{id: ^review_id}}}
      assert_receive {:runner_invoked, summary_id}
      assert summary_id != review_id
      refute_receive {:runner_invoked, ^review_id}
      assert_receive {:reflection_completed, "summary", {:ok, %{id: ^summary_id}}}
    end
  end

  describe "when a Runner attempt crashes or exceeds its execution timeout" do
    test "then a crash retries the Runner with the same deterministic identifier" do
      attempts = :atomics.new(1, [])
      test_pid = self()
      name = scheduler_name()

      runner = fn reflection, _ingestion, opts ->
        attempt = :atomics.add_get(attempts, 1, 1)
        send(test_pid, {:runner_attempt, attempt, opts[:artefact_id]})

        if attempt == 1 do
          raise "runner crashed"
        else
          {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{"stored" => true})}
        end
      end

      start_scheduler(name,
        runner: runner,
        store_opts: [storage: EmptyStore],
        retry_delays: [0],
        notify: self()
      )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:runner_attempt, 1, artefact_id}
      assert_receive {:reflection_retrying, "review", %{stage: :runner}}
      assert_receive {:runner_attempt, 2, ^artefact_id}
      assert_receive {:reflection_completed, "review", {:ok, %{id: ^artefact_id}}}
    end

    test "then timeout waits for the expired Runner to exit before replacement begins" do
      attempts = :atomics.new(1, [])
      test_pid = self()
      name = scheduler_name()

      runner = fn reflection, _ingestion, opts ->
        attempt = :atomics.add_get(attempts, 1, 1)
        send(test_pid, {:timed_runner, attempt, self(), opts[:artefact_id]})

        if attempt == 1 do
          receive do
            :never -> {:error, :unexpected}
          end
        else
          {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{"stored" => true})}
        end
      end

      start_scheduler(name,
        runner: runner,
        store_opts: [storage: EmptyStore],
        retry_delays: [0],
        execution_timeout_ms: 25,
        notify: self()
      )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:timed_runner, 1, first_runner, artefact_id}
      monitor = Process.monitor(first_runner)
      assert_receive {:DOWN, ^monitor, :process, ^first_runner, :killed}
      assert_receive {:reflection_retrying, "review", %{reason: :timeout}}
      assert_receive {:timed_runner, 2, _replacement, ^artefact_id}
      assert_receive {:reflection_completed, "review", {:ok, %{id: ^artefact_id}}}
    end
  end

  describe "if a Runner returns an artefact whose identifier or Reflection name does not match the logical completion" do
    test "then the Runner phase retries boundedly without sending the mismatched artefact to storage" do
      for mismatch <- [:identifier, :reflection] do
        start_supervised!({ControlledStore, {self(), [{:error, :not_found}], []}})
        attempts = :atomics.new(1, [])
        test_pid = self()
        name = scheduler_name()

        runner = fn reflection, _ingestion, opts ->
          attempt = :atomics.add_get(attempts, 1, 1)
          expected_id = opts[:artefact_id]

          artefact =
            case mismatch do
              :identifier -> Artefact.new("another-id", reflection.name, %{})
              :reflection -> Artefact.new(expected_id, "another-reflection", %{})
            end

          send(test_pid, {:mismatched_runner, mismatch, attempt, expected_id})
          {:ok, artefact}
        end

        start_scheduler(name,
          runner: runner,
          store_opts: [storage: ControlledStore],
          retry_delays: [0],
          notify: test_pid
        )

        assert {:ok, :scheduled} =
                 Scheduler.schedule([reflection("review")], ingestion(), server: name)

        assert_receive {:mismatched_runner, ^mismatch, 1, expected_id}

        assert_receive {:reflection_retrying, "review",
                        %{
                          stage: :runner,
                          attempts: 1,
                          reason:
                            {:artefact_identity_mismatch,
                             %{
                               expected: %{id: ^expected_id, reflection: "review"},
                               actual: actual
                             }}
                        }}

        assert actual != %{id: expected_id, reflection: "review"}
        assert_receive {:mismatched_runner, ^mismatch, 2, ^expected_id}

        assert_receive {:reflection_completed, "review",
                        {:error,
                         %{
                           stage: :runner,
                           attempts: 2,
                           reason: {:artefact_identity_mismatch, _identity}
                         }}}

        refute_receive {:store_put, _artefact, _task}
        assert :ok = stop_supervised(name)
        assert :ok = stop_supervised(ControlledStore)
      end
    end
  end

  describe "when a Runner, lookup, or storage task cannot start" do
    test "then that phase consumes one attempt and follows the bounded retry schedule" do
      test_pid = self()

      for {phase, fail_on, expected_stage} <- [
            {:lookup, 1, :storage},
            {:runner, 2, :runner},
            {:storage, 3, :storage}
          ] do
        starts = :atomics.new(1, [])
        name = scheduler_name()

        start_task = fn supervisor, operation ->
          if :atomics.add_get(starts, 1, 1) == fail_on do
            {:error, {:task_supervisor_busy, phase}}
          else
            Task.Supervisor.async_nolink(supervisor, operation)
          end
        end

        runner = fn reflection, _ingestion, opts ->
          send(test_pid, {:runner_after_start_retry, phase})
          {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{})}
        end

        start_scheduler(name,
          runner: runner,
          start_task: start_task,
          store_opts: [storage: EmptyStore],
          retry_delays: [0],
          notify: test_pid
        )

        assert {:ok, :scheduled} =
                 Scheduler.schedule([reflection("review")], ingestion(), server: name)

        assert_receive {:reflection_retrying, "review",
                        %{
                          stage: ^expected_stage,
                          attempts: 1,
                          reason: {:task_start, {:task_supervisor_busy, ^phase}}
                        }}

        assert_receive {:runner_after_start_retry, ^phase}
        assert_receive {:reflection_completed, "review", {:ok, _artefact}}
      end
    end
  end

  describe "when canonical lookup returns an error, crashes, or exceeds its execution timeout" do
    test "then lookup follows the bounded storage retry schedule" do
      for {outcome, expected_reason} <- [
            {{:error, :lookup_unavailable}, :lookup_unavailable},
            {:crash, :task_exit},
            {:hang, :timeout}
          ] do
        start_supervised!({ControlledStore, {self(), [outcome, {:error, :not_found}], [:ok]}})

        {name, runner} = immediate_runner(self())

        start_scheduler(name,
          runner: runner,
          store_opts: [storage: ControlledStore],
          retry_delays: [0],
          execution_timeout_ms: 25,
          notify: self()
        )

        assert {:ok, :scheduled} =
                 Scheduler.schedule([reflection("review")], ingestion(), server: name)

        assert_receive {:store_get, _artefact_id, _lookup_task}

        assert_receive {:reflection_retrying, "review", %{stage: :storage, reason: reason}}

        case expected_reason do
          :task_exit -> assert match?({:task_exit, _}, reason)
          expected -> assert reason == expected
        end

        assert_receive {:store_get, _artefact_id, _lookup_task}
        assert_receive {:runner_invoked, artefact_id}
        assert_receive {:reflection_completed, "review", {:ok, %{id: ^artefact_id}}}

        assert :ok = stop_supervised(name)
        assert :ok = stop_supervised(ControlledStore)
      end
    end

    test "then an immutable-content conflict ends without retry" do
      start_supervised!(
        {ControlledStore, {self(), [{:error, {:artefact_conflict, "stable-id"}}], []}}
      )

      {name, runner} = immediate_runner(self())

      start_scheduler(name,
        runner: runner,
        store_opts: [storage: ControlledStore],
        retry_delays: [0, 0],
        notify: self()
      )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:reflection_completed, "review",
                      {:error,
                       %{
                         stage: :storage,
                         attempts: 1,
                         reason: {:artefact_conflict, "stable-id"}
                       }}}

      refute_receive {:reflection_retrying, "review", _failure}
      refute_receive {:runner_invoked, _artefact_id}
    end
  end

  describe "when canonical storage fails after a successful Runner" do
    test "then storage retry receives the exact retained artefact without rerunning the Runner" do
      start_supervised!(
        {ControlledStore, {self(), [{:error, :not_found}], [{:error, :temporary}, :ok]}}
      )

      {name, runner} = immediate_runner(self())

      start_scheduler(name,
        runner: runner,
        store_opts: [storage: ControlledStore],
        retry_delays: [0],
        notify: self()
      )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:runner_invoked, artefact_id}
      assert_receive {:store_put, first, _store_task}
      assert_receive {:reflection_retrying, "review", %{stage: :storage, reason: :temporary}}
      assert_receive {:store_put, second, _store_task}
      assert second == first
      refute_receive {:runner_invoked, _artefact_id}
      assert_receive {:reflection_completed, "review", {:ok, %{id: ^artefact_id}}}
    end

    test "then a storage task crash is retried in storage phase" do
      start_supervised!({ControlledStore, {self(), [{:error, :not_found}], [:crash, :ok]}})
      {name, runner} = immediate_runner(self())

      start_scheduler(name,
        runner: runner,
        store_opts: [storage: ControlledStore],
        retry_delays: [0],
        notify: self()
      )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:store_put, artefact, _store_task}

      assert_receive {:reflection_retrying, "review",
                      %{stage: :storage, reason: {:task_exit, _reason}}}

      assert_receive {:store_put, ^artefact, _store_task}
      assert_receive {:reflection_completed, "review", {:ok, ^artefact}}
    end

    test "then a storage timeout stops the attempt before retry" do
      start_supervised!({ControlledStore, {self(), [{:error, :not_found}], [:hang, :ok]}})
      {name, runner} = immediate_runner(self())

      start_scheduler(name,
        runner: runner,
        store_opts: [storage: ControlledStore],
        retry_delays: [0],
        execution_timeout_ms: 25,
        notify: self()
      )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:store_put, artefact, first_store_task}
      monitor = Process.monitor(first_store_task)
      assert_receive {:DOWN, ^monitor, :process, ^first_store_task, :killed}
      assert_receive {:reflection_retrying, "review", %{stage: :storage, reason: :timeout}}
      assert_receive {:store_put, ^artefact, _second_store_task}
      assert_receive {:reflection_completed, "review", {:ok, ^artefact}}
    end
  end

  describe "when canonical storage reports an artefact conflict" do
    test "then the conflict is terminal without retry" do
      start_supervised!(
        {ControlledStore,
         {self(), [{:error, :not_found}], [{:error, {:artefact_conflict, "stable"}}]}}
      )

      {name, runner} = immediate_runner(self())

      start_scheduler(name,
        runner: runner,
        store_opts: [storage: ControlledStore],
        retry_delays: [0, 0],
        notify: self()
      )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:reflection_completed, "review",
                      {:error,
                       %{stage: :storage, attempts: 1, reason: {:artefact_conflict, "stable"}}}}

      refute_receive {:reflection_retrying, "review", _failure}
    end
  end

  describe "when a retryable phase consumes every configured retry" do
    test "then terminal failure is logged and durable admission is deleted" do
      start_supervised!(
        {ControlledStore, {self(), [{:error, :not_found}], [{:error, :first}, {:error, :final}]}}
      )

      {name, runner} = immediate_runner(self())
      path = journal_path()
      on_exit(fn -> File.rm(path) end)
      journal_name = journal_name()

      start_scheduler(name,
        runner: runner,
        store_opts: [storage: ControlledStore],
        retry_delays: [0],
        notify: self(),
        journal_path: path,
        journal_name: journal_name
      )

      log =
        capture_log(fn ->
          assert {:ok, :scheduled} =
                   Scheduler.schedule([reflection("review")], ingestion(), server: name)

          assert_receive {:reflection_completed, "review",
                          {:error, %{stage: :storage, attempts: 2, reason: :final}}}
        end)

      assert log =~ "Reflection failed"
      assert log =~ "reflection:review"
      assert log =~ "stage:storage"

      assert :ok = stop_supervised(name)
      reopened = journal_name()
      assert {:ok, ^reopened} = Journal.open(path, reopened)
      assert Journal.all(reopened) == []
      assert :ok = Journal.close(reopened)
      File.rm(path)
    end
  end

  describe "when the Scheduler process starts with durable unfinished work" do
    test "then retained storage resumes with the exact artefact and retry state" do
      start_supervised!(
        {ControlledStore, {self(), [{:error, :not_found}, {:error, :not_found}], [:hang, :ok]}}
      )

      {name, runner} = immediate_runner(self())
      path = journal_path()
      on_exit(fn -> File.rm(path) end)

      scheduler =
        start_scheduler(name,
          runner: runner,
          store_opts: [storage: ControlledStore],
          retry_delays: [0],
          notify: self(),
          journal_path: path,
          journal_name: journal_name()
        )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:store_put, artefact, _first_store_task}
      Process.exit(scheduler, :kill)
      assert eventually(fn -> Process.whereis(name) not in [nil, scheduler] end)
      assert_receive {:reflection_retrying, "review", %{reason: :scheduler_restart}}
      assert_receive {:store_put, ^artefact, _resumed_store_task}
      assert_receive {:reflection_completed, "review", {:ok, ^artefact}}
    end

    test "then an interrupted active attempt consumes the durable retry budget" do
      test_pid = self()
      name = scheduler_name()
      path = journal_path()
      on_exit(fn -> File.rm(path) end)

      runner = fn _reflection, _ingestion, _opts ->
        send(test_pid, {:active_runner, self()})

        receive do
          :never -> {:error, :unexpected}
        end
      end

      scheduler =
        start_scheduler(name,
          runner: runner,
          store_opts: [storage: EmptyStore],
          retry_delays: [],
          notify: self(),
          journal_path: path,
          journal_name: journal_name()
        )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:active_runner, active_runner}
      Process.exit(scheduler, :kill)
      ref = Process.monitor(active_runner)
      assert_receive {:DOWN, ^ref, :process, ^active_runner, _reason}
      assert eventually(fn -> Process.whereis(name) not in [nil, scheduler] end)

      assert_receive {:reflection_completed, "review",
                      {:error, %{stage: :runner, attempts: 1, reason: :scheduler_restart}}}

      refute_receive {:active_runner, _runner}
    end

    test "then an uncertain final storage attempt is confirmed before retry exhaustion" do
      artefact_id = Artefact.id_for("operator-one", "ingestion-one", "review")
      artefact = Artefact.new(artefact_id, "review", %{"stored" => true})

      start_supervised!(
        {ControlledStore, {self(), [{:error, :not_found}, {:ok, artefact}], [:hang]}}
      )

      {name, runner} = immediate_runner(self())
      path = journal_path()
      on_exit(fn -> File.rm(path) end)

      scheduler =
        start_scheduler(name,
          runner: runner,
          store_opts: [storage: ControlledStore],
          retry_delays: [],
          notify: self(),
          journal_path: path,
          journal_name: journal_name()
        )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:runner_invoked, ^artefact_id}
      assert_receive {:store_put, ^artefact, _storage_task}
      Process.exit(scheduler, :kill)
      assert eventually(fn -> Process.whereis(name) not in [nil, scheduler] end)
      assert_receive {:store_get, ^artefact_id, _confirmation_task}
      assert_receive {:reflection_completed, "review", {:ok, ^artefact}}
      refute_receive {:runner_invoked, _artefact_id}
      refute_receive {:store_put, _artefact, _storage_task}
    end

    test "then a replacement crash during storage confirmation confirms again without consuming retry budget" do
      artefact_id = Artefact.id_for("operator-one", "ingestion-one", "review")
      artefact = Artefact.new(artefact_id, "review", %{"stored" => true})

      start_supervised!(
        {ControlledStore, {self(), [{:error, :not_found}, :hang, {:ok, artefact}], [:hang]}}
      )

      {name, runner} = immediate_runner(self())
      path = journal_path()
      on_exit(fn -> File.rm(path) end)

      first_scheduler =
        start_scheduler(name,
          runner: runner,
          store_opts: [storage: ControlledStore],
          retry_delays: [],
          notify: self(),
          journal_path: path,
          journal_name: journal_name()
        )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:runner_invoked, ^artefact_id}
      assert_receive {:store_put, ^artefact, _storage_task}
      Process.exit(first_scheduler, :kill)
      assert eventually(fn -> Process.whereis(name) not in [nil, first_scheduler] end)
      second_scheduler = Process.whereis(name)
      assert_receive {:store_get, ^artefact_id, _first_confirmation_task}

      Process.exit(second_scheduler, :kill)
      assert eventually(fn -> Process.whereis(name) not in [nil, second_scheduler] end)
      assert_receive {:store_get, ^artefact_id, _second_confirmation_task}
      assert_receive {:reflection_completed, "review", {:ok, ^artefact}}
      refute_receive {:runner_invoked, _artefact_id}
      refute_receive {:store_put, _artefact, _storage_task}
      refute_receive {:reflection_retrying, "review", _failure}
    end

    test "then a newly started Scheduler reopens and resumes retained storage work" do
      start_supervised!(
        {ControlledStore, {self(), [{:error, :not_found}, {:error, :not_found}], [:hang, :ok]}}
      )

      {name, runner} = immediate_runner(self())
      path = journal_path()
      first_journal = journal_name()
      on_exit(fn -> File.rm(path) end)

      start_scheduler(name,
        runner: runner,
        store_opts: [storage: ControlledStore],
        retry_delays: [0],
        notify: self(),
        journal_path: path,
        journal_name: first_journal
      )

      admitted_ingestion =
        Map.merge(ingestion(), %{tools: [:runtime_tool], tool_context: %{request: "runtime"}})

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], admitted_ingestion, server: name)

      assert_receive {:runner_invoked, artefact_id}
      assert_receive {:store_put, artefact, _storage_task}
      assert artefact.id == artefact_id

      [durable] = Journal.all(first_journal)
      assert durable.opts[:runner_opts] == []
      assert durable.opts[:store_opts] == [storage: ControlledStore]
      refute Map.has_key?(durable.ingestion, :tools)
      refute Map.has_key?(durable.ingestion, :tool_context)

      assert :ok = stop_supervised(name)

      start_scheduler(name,
        runner: runner,
        store_opts: [storage: ControlledStore],
        retry_delays: [0],
        notify: self(),
        journal_path: path,
        journal_name: journal_name()
      )

      assert_receive {:store_get, ^artefact_id, _confirmation_task}
      assert_receive {:reflection_retrying, "review", %{reason: :scheduler_restart}}
      assert_receive {:store_put, ^artefact, _resumed_storage_task}
      refute_receive {:runner_invoked, ^artefact_id}
      assert_receive {:reflection_completed, "review", {:ok, ^artefact}}
    end
  end

  describe "when scheduling supplies request-specific Runner or store options" do
    test "then first admission composes them with configured runtime dependencies" do
      test_pid = self()
      name = scheduler_name()

      runner = fn _reflection, _ingestion, opts ->
        send(test_pid, {:composed_runner_opts, opts, self()})

        receive do
          :finish -> {:error, :expected_stop}
        end
      end

      start_scheduler(name,
        runner: runner,
        runner_opts: [inference: :configured_inference, tool_executor: :configured_executor],
        store_opts: [storage: EmptyStore, namespace: "configured"],
        retry_delays: []
      )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(),
                 server: name,
                 runner_opts: [tools: [:request_tool]],
                 store_opts: [tenant: "request-tenant"]
               )

      assert_receive {:composed_runner_opts, runner_opts, runner_task}
      assert runner_opts[:inference] == :configured_inference
      assert runner_opts[:tool_executor] == :configured_executor
      assert runner_opts[:tools] == [:request_tool]

      [job] = name |> :sys.get_state() |> Map.fetch!(:jobs) |> Map.values()

      assert job.opts[:store_opts] == [
               storage: EmptyStore,
               namespace: "configured",
               tenant: "request-tenant"
             ]

      send(runner_task, :finish)
    end

    test "then restart restores durable request data and replacement runtime dependencies" do
      test_pid = self()
      name = scheduler_name()
      path = journal_path()
      on_exit(fn -> File.rm(path) end)

      first_runner = fn _reflection, _ingestion, opts ->
        send(test_pid, {:first_runtime_opts, opts, self()})

        receive do
          :never -> {:error, :unexpected}
        end
      end

      start_scheduler(name,
        runner: first_runner,
        runner_opts: [inference: :first_inference, tool_executor: :first_executor],
        store_opts: [storage: EmptyStore, namespace: "admitted"],
        retry_delays: [0],
        journal_path: path,
        journal_name: journal_name()
      )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(),
                 server: name,
                 runner_opts: [tools: [:request_tool], tool_context: %{request: "context"}],
                 store_opts: [tenant: "request-tenant"]
               )

      assert_receive {:first_runtime_opts, first_opts, first_task}
      assert first_opts[:inference] == :first_inference
      assert first_opts[:tool_executor] == :first_executor
      assert first_opts[:tools] == [:request_tool]
      assert first_opts[:tool_context] == %{request: "context"}

      assert :ok = stop_supervised(name)
      ref = Process.monitor(first_task)
      assert_receive {:DOWN, ^ref, :process, ^first_task, _reason}

      replacement_runner = fn reflection, _ingestion, opts ->
        send(test_pid, {:replacement_runtime_opts, opts, self()})

        receive do
          :finish -> {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{})}
        end
      end

      start_scheduler(name,
        runner: replacement_runner,
        runner_opts: [
          inference: :replacement_inference,
          tool_executor: :replacement_executor
        ],
        store_opts: [storage: EmptyStore, namespace: "replacement-default"],
        notify: test_pid,
        journal_path: path,
        journal_name: journal_name()
      )

      assert_receive {:replacement_runtime_opts, replacement_opts, replacement_task}
      assert replacement_opts[:inference] == :replacement_inference
      assert replacement_opts[:tool_executor] == :replacement_executor
      assert replacement_opts[:tools] == [:request_tool]
      assert replacement_opts[:tool_context] == %{request: "context"}

      [job] = name |> :sys.get_state() |> Map.fetch!(:jobs) |> Map.values()

      assert job.opts[:store_opts] == [
               storage: EmptyStore,
               namespace: "admitted",
               tenant: "request-tenant"
             ]

      send(replacement_task, :finish)
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}, 1_000
    end
  end

  describe "when the Scheduler stops during a configured retry delay" do
    test "then the durable deadline prevents an early replacement attempt" do
      attempts = :atomics.new(1, [])
      test_pid = self()
      name = scheduler_name()
      path = journal_path()
      on_exit(fn -> File.rm(path) end)

      runner = fn reflection, _ingestion, opts ->
        attempt = :atomics.add_get(attempts, 1, 1)
        send(test_pid, {:delayed_runner, attempt, System.monotonic_time(:millisecond)})

        if attempt == 1 do
          {:error, :temporary}
        else
          {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{})}
        end
      end

      scheduler =
        start_scheduler(name,
          runner: runner,
          store_opts: [storage: EmptyStore],
          retry_delays: [500],
          notify: self(),
          journal_path: path,
          journal_name: journal_name()
        )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:delayed_runner, 1, first_at}
      assert_receive {:reflection_retrying, "review", %{reason: :temporary}}
      Process.exit(scheduler, :kill)
      assert eventually(fn -> Process.whereis(name) not in [nil, scheduler] end)
      refute_receive {:delayed_runner, 2, _second_at}, 250
      assert_receive {:delayed_runner, 2, second_at}, 500
      assert second_at - first_at >= 450
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
    end
  end

  describe "when the same logical completion is scheduled concurrently" do
    test "then one Runner is active and duplicate admission is reported" do
      test_pid = self()
      name = scheduler_name()

      runner = fn reflection, _ingestion, opts ->
        send(test_pid, {:admitted_runner, self()})

        receive do
          :finish -> {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{})}
        end
      end

      start_scheduler(name, runner: runner, store_opts: [storage: EmptyStore])

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert {:ok, :already_scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:admitted_runner, runner_task}
      refute_receive {:admitted_runner, _runner_task}
      send(runner_task, :finish)
    end
  end

  describe "if scheduling input is invalid" do
    test "then it fails before Runner execution and empty work drains immediately" do
      test_pid = self()
      name = scheduler_name()
      runner = fn _, _, _ -> send(test_pid, :runner_started) end
      start_scheduler(name, runner: runner, store_opts: [storage: EmptyStore])

      assert {:error, {:invalid_ingestion_id, " "}} =
               Scheduler.schedule([reflection("review")], %{ingestion() | id: " "}, server: name)

      assert {:error, {:duplicate_reflection, "review"}} =
               Scheduler.schedule([reflection("review"), reflection("review")], ingestion(),
                 server: name
               )

      assert {:ok, :scheduled} = Scheduler.schedule([], ingestion(), server: name)
      assert :ok = Scheduler.drain(name)
      refute_receive :runner_started
    end

    test "then missing operator, missing ingestion, and incomplete ingestion are identified" do
      name = scheduler_name()
      test_pid = self()
      runner = fn _, _, _ -> send(test_pid, :runner_started) end
      start_scheduler(name, runner: runner, store_opts: [storage: EmptyStore])

      assert {:error, {:invalid_operator_id, nil}} =
               Scheduler.schedule([reflection("review")], %{ingestion() | operator_id: nil},
                 server: name
               )

      assert {:error, {:invalid_operator_id, " "}} =
               Scheduler.schedule([reflection("review")], %{ingestion() | operator_id: " "},
                 server: name
               )

      assert {:error, {:invalid_ingestion_id, nil}} =
               Scheduler.schedule([reflection("review")], %{ingestion() | id: nil}, server: name)

      incomplete = %{ingestion() | completed_lenses: [], representations: []}

      assert {:error, {:incomplete_ingestion, "ingestion-one"}} =
               Scheduler.schedule([reflection("review")], incomplete, server: name)

      refute_receive :runner_started
    end
  end

  describe "when the Scheduler is asked to drain" do
    test "then every waiting caller is released after admitted work ends" do
      test_pid = self()
      name = scheduler_name()

      runner = fn reflection, _ingestion, opts ->
        send(test_pid, {:drain_runner, self()})

        receive do
          :finish ->
            {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{"stored" => true})}
        end
      end

      start_scheduler(name, runner: runner, store_opts: [storage: EmptyStore])

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:drain_runner, runner_task}
      drainers = for _ <- 1..2, do: Task.async(fn -> Scheduler.drain(name) end)
      assert eventually(fn -> :sys.get_state(name).draining end)

      assert {:error, :scheduler_draining} =
               Scheduler.schedule([reflection("summary")], ingestion(), server: name)

      assert Enum.all?(drainers, &(Task.yield(&1, 10) == nil))
      send(runner_task, :finish)
      assert Task.await_many(drainers) == [:ok, :ok]
    end
  end

  describe "if boundedness configuration is invalid" do
    test "then Scheduler startup or scheduling rejects it" do
      for invalid <- ["not-a-list", [-1], [1.5]] do
        name = scheduler_name()

        assert {:error, {:invalid_retry_delays, ^invalid}} =
                 Task.async(fn ->
                   Process.flag(:trap_exit, true)
                   Scheduler.start_link(name: name, retry_delays: invalid)
                 end)
                 |> Task.await()
      end

      name = scheduler_name()
      start_scheduler(name, runner: elem(immediate_runner(self()), 1))

      too_large = 4_294_967_296

      assert {:error, {:invalid_retry_delays, [^too_large]}} =
               Scheduler.schedule([reflection("review")], ingestion(),
                 server: name,
                 retry_delays: [too_large]
               )

      assert {:error, {:invalid_execution_timeout_ms, 0}} =
               Scheduler.schedule([reflection("review")], ingestion(),
                 server: name,
                 execution_timeout_ms: 0
               )

      assert {:error, {:invalid_execution_timeout_ms, ^too_large}} =
               Scheduler.schedule([reflection("review")], ingestion(),
                 server: name,
                 execution_timeout_ms: too_large
               )

      assert {:error, :restart_unsafe_execution_data} =
               Scheduler.schedule([reflection("review")], ingestion(),
                 server: name,
                 runner_opts: [tool_context: %{pid: self()}]
               )

      assert {:error, :restart_unsafe_work} =
               Scheduler.schedule(
                 [reflection("review")],
                 put_in(ingestion(), [:representations, Access.at(0), :runtime], self()),
                 server: name
               )

      refute_receive {:runner_invoked, _artefact_id}
    end
  end

  defp reflection(name) do
    %Reflection{
      name: name,
      destination: %Destination{name: "observations"},
      ontology: Gralkor.DefaultOntology,
      chain_of_thought: %ChainOfThought{path: "test", steps: []}
    }
  end

  defp ingestion do
    %{
      id: "ingestion-one",
      operator_id: "operator-one",
      intended_lenses: ["observations"],
      completed_lenses: ["observations"],
      representations: [%{lens: "observations", result: :ok}]
    }
  end

  defp receive_runners(0, runners), do: runners

  defp receive_runners(remaining, runners) do
    assert_receive {:runner, name, id, runner}
    receive_runners(remaining - 1, Map.put(runners, name, {id, runner}))
  end

  defp immediate_runner(test_pid) do
    name = scheduler_name()

    runner = fn reflection, _ingestion, opts ->
      send(test_pid, {:runner_invoked, opts[:artefact_id]})
      {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{"stored" => true})}
    end

    {name, runner}
  end

  defp start_scheduler(name, opts) do
    start_supervised!({Scheduler, Keyword.put(opts, :name, name)})
  end

  defp scheduler_name,
    do: Module.concat(__MODULE__, "Scheduler#{System.unique_integer([:positive])}")

  defp journal_name,
    do: Module.concat(__MODULE__, "Journal#{System.unique_integer([:positive])}")

  defp journal_path,
    do:
      Path.join(
        System.tmp_dir!(),
        "scheduler-unit-#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}.dets"
      )

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
