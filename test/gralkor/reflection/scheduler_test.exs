defmodule Gralkor.Reflection.SchedulerTest do
  use ExUnit.Case, async: false

  alias Gralkor.Destination
  alias Gralkor.Reflection
  alias Gralkor.Reflection.Artefact
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.Scheduler

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
          :succeed -> {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{}, [])}
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
  end

  describe "when a phase task cannot start" do
    test "then that phase is retried within the bounded schedule" do
      test_pid = self()
      attempts = :atomics.new(1, [])
      name = Module.concat(__MODULE__, "Scheduler#{System.unique_integer([:positive])}")

      start_task = fn supervisor, operation ->
        if :atomics.add_get(attempts, 1, 1) == 1 do
          {:error, :task_supervisor_busy}
        else
          Task.Supervisor.async_nolink(supervisor, operation)
        end
      end

      runner = fn reflection, _ingestion, opts ->
        send(test_pid, {:runner_after_start_retry, self()})
        {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{}, [])}
      end

      start_supervised!(
        {Scheduler,
         name: name,
         runner: runner,
         start_task: start_task,
         store_opts: [storage: EmptyStore],
         retry_delays: [0],
         notify: test_pid}
      )

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection("review")], ingestion(), server: name)

      assert_receive {:reflection_retrying, "review",
                      %{stage: :storage, reason: {:task_start, :task_supervisor_busy}}}

      assert_receive {:runner_after_start_retry, _runner}
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
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

  describe "when the same logical completion is scheduled concurrently" do
    test "then one Runner is active and duplicate admission is reported" do
      test_pid = self()
      name = scheduler_name()

      runner = fn reflection, _ingestion, opts ->
        send(test_pid, {:admitted_runner, self()})

        receive do
          :finish -> {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{}, [])}
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
      {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{"stored" => true}, [])}
    end

    {name, runner}
  end

  defp start_scheduler(name, opts) do
    start_supervised!({Scheduler, Keyword.put(opts, :name, name)})
  end

  defp scheduler_name,
    do: Module.concat(__MODULE__, "Scheduler#{System.unique_integer([:positive])}")
end
