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
end
