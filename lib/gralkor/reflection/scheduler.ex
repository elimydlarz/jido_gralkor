defmodule Gralkor.Reflection.Scheduler do
  @moduledoc "Owns independent, bounded Reflection completion flows."

  use GenServer

  require Logger

  alias Gralkor.Reflection.Artefact
  alias Gralkor.Reflection.Journal
  alias Gralkor.Reflection.Runner
  alias Gralkor.Reflection.Store

  @default_retry_delays [1_000, 2_000, 4_000]
  @default_execution_timeout_ms 60_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: :infinity
    }
  end

  def schedule(reflections, ingestion, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:schedule, reflections, ingestion, opts})
  end

  def drain(server \\ __MODULE__, timeout \\ :infinity) do
    GenServer.call(server, :drain, timeout)
  end

  @impl true
  def init(opts) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    defaults =
      [
        retry_delays: @default_retry_delays,
        execution_timeout_ms: @default_execution_timeout_ms
      ]
      |> Keyword.merge(
        Keyword.take(opts, [
          :runner,
          :runner_opts,
          :start_task,
          :store_opts,
          :notify,
          :retry_delays,
          :execution_timeout_ms
        ])
      )

    with :ok <- validate_execution_options(defaults),
         journal_name = Keyword.get(opts, :journal_name, Journal),
         {:ok, journal} <- Journal.open(Keyword.get(opts, :journal_path), journal_name) do
      jobs =
        journal
        |> Journal.all()
        |> Map.new(fn durable ->
          job =
            durable
            |> Map.put(:opts, Keyword.merge(defaults, durable.opts))
            |> Map.put(:retry_timer, nil)
            |> Map.put_new(:retry_at_ms, nil)
            |> Map.put_new(:active, false)

          {job.key, job}
        end)

      if map_size(jobs) > 0, do: send(self(), :resume_unfinished)

      {:ok,
       %{
         task_supervisor: supervisor,
         defaults: defaults,
         jobs: jobs,
         tasks: %{},
         drainers: [],
         draining: false,
         journal: journal
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:schedule, _reflections, _ingestion, _opts}, _from, %{draining: true} = state) do
    {:reply, {:error, :scheduler_draining}, state}
  end

  def handle_call({:schedule, reflections, ingestion, opts}, _from, state) do
    opts = Keyword.merge(state.defaults, Keyword.drop(opts, [:server]))

    with :ok <- validate_ingestion(ingestion),
         :ok <- validate_reflections(reflections),
         :ok <- validate_execution_options(opts) do

      new_jobs =
        Enum.reduce(reflections, [], fn reflection, jobs ->
          key = completion_key(reflection, ingestion)

          if Map.has_key?(state.jobs, key) do
            jobs
          else
            [new_job(key, reflection, ingestion, opts) | jobs]
          end
        end)

      case Journal.put_all(state.journal, Enum.map(new_jobs, &durable_job/1)) do
        :ok ->
          state =
            Enum.reduce(new_jobs, state, fn job, current ->
              current = %{current | jobs: Map.put(current.jobs, job.key, job)}
              launch(current, job.key)
            end)

          reply =
            if new_jobs == [] and reflections != [], do: :already_scheduled, else: :scheduled

          {:reply, {:ok, reply}, state}

        {:error, reason} ->
          {:reply, {:error, {:journal_write_failed, reason}}, state}
      end
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:drain, _from, %{jobs: jobs} = state) when map_size(jobs) == 0 do
    {:reply, :ok, %{state | draining: true}}
  end

  def handle_call(:drain, from, state) do
    {:noreply, %{state | drainers: [from | state.drainers], draining: true}}
  end

  @impl true
  def handle_info({reference, {stage, outcome}}, state) when is_reference(reference) do
    case Map.fetch(state.tasks, reference) do
      {:ok, task} ->
        if task.active_timeout do
          {:noreply, state}
        else
          state = release_task(state, reference, task)
          {:noreply, handle_outcome(state, task.key, stage, outcome)}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case Map.fetch(state.tasks, reference) do
      {:ok, task} ->
        state = release_task(state, reference, task)
        failure_reason = if task.active_timeout, do: :timeout, else: {:task_exit, reason}
        {:noreply, retry_or_finish(state, task.key, failure_reason)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:attempt_timeout, reference}, state) do
    case Map.fetch(state.tasks, reference) do
      {:ok, task} ->
        Process.exit(task.pid, :kill)
        Process.cancel_timer(task.timeout_ref)
        task = %{task | timeout_ref: nil, active_timeout: true}
        {:noreply, %{state | tasks: Map.put(state.tasks, reference, task)}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:retry, key}, state) do
    case Map.fetch(state.jobs, key) do
      {:ok, job} ->
        job = %{job | retry_timer: nil, retry_at_ms: nil}
        {:noreply, launch(%{state | jobs: Map.put(state.jobs, key, job)}, key)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:resume_unfinished, state) do
    state =
      Enum.reduce(Map.keys(state.jobs), state, fn key, current ->
        resume_job(current, key)
      end)

    {:noreply, state}
  end

  defp new_job(key, reflection, ingestion, opts) do
    %{
      key: key,
      reflection: reflection,
      ingestion: ingestion,
      opts: opts,
      stage: :lookup,
      attempt: 1,
      artefact: nil,
      retry_timer: nil,
      retry_at_ms: nil,
      active: false
    }
  end

  defp launch(state, key) do
    job =
      state.jobs
      |> Map.fetch!(key)
      |> Map.put(:active, true)
      |> Map.put(:retry_at_ms, nil)
    :ok = Journal.put_all(state.journal, [durable_job(job)])
    state = %{state | jobs: Map.put(state.jobs, key, job)}
    operation = fn -> execute(job) end
    start_task = Keyword.get(job.opts, :start_task, &Task.Supervisor.async_nolink/2)

    case start_attempt(start_task, state.task_supervisor, operation) do
      {:ok, task} ->
        timeout = Keyword.fetch!(job.opts, :execution_timeout_ms)
        timeout_ref = Process.send_after(self(), {:attempt_timeout, task.ref}, timeout)
        task_state = %{key: key, pid: task.pid, timeout_ref: timeout_ref, active_timeout: false}
        %{state | tasks: Map.put(state.tasks, task.ref, task_state)}

      {:error, reason} ->
        retry_or_finish(state, key, {:task_start, reason})
    end
  end

  defp start_attempt(start_task, supervisor, operation) do
    case start_task.(supervisor, operation) do
      %Task{} = task -> {:ok, task}
      {:ok, %Task{} = task} -> {:ok, task}
      {:error, reason} -> {:error, reason}
      outcome -> {:error, {:invalid_start_response, outcome}}
    end
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute(%{stage: :lookup} = job) do
    outcome =
      Store.get(
        job.reflection,
        field(job.ingestion, :operator_id),
        artefact_id(job),
        Keyword.get(job.opts, :store_opts, [])
      )

    {:lookup, outcome}
  end

  defp execute(%{stage: :runner} = job) do
    runner = Keyword.get(job.opts, :runner, &Runner.run/3)

    runner_opts =
      job.opts
      |> Keyword.get(:runner_opts, [])
      |> Keyword.put(:artefact_id, artefact_id(job))

    {:runner, runner.(job.reflection, job.ingestion, runner_opts)}
  end

  defp execute(%{stage: :storage} = job) do
    outcome =
      Store.put(
        job.reflection,
        field(job.ingestion, :operator_id),
        job.artefact,
        Keyword.get(job.opts, :store_opts, [])
      )

    {:storage, outcome}
  end

  defp execute(%{stage: :storage_confirmation} = job) do
    outcome =
      Store.get(
        job.reflection,
        field(job.ingestion, :operator_id),
        artefact_id(job),
        Keyword.get(job.opts, :store_opts, [])
      )

    {:storage_confirmation, outcome}
  end

  defp handle_outcome(state, key, :lookup, {:ok, artefact}),
    do: finish_success(state, key, artefact)

  defp handle_outcome(state, key, :lookup, {:error, :not_found}) do
    transition(state, key, :runner, nil)
  end

  defp handle_outcome(
         state,
         key,
         :lookup,
         {:error, {:incomplete_artefact, %Artefact{} = artefact}}
       ) do
    transition(state, key, :storage, artefact)
  end

  defp handle_outcome(state, key, :lookup, {:error, {:artefact_conflict, _} = reason}),
    do: finish_failure(state, key, reason)

  defp handle_outcome(state, key, :runner, {:ok, %Artefact{} = artefact}) do
    transition(state, key, :storage, artefact)
  end

  defp handle_outcome(state, key, :storage, :ok),
    do: finish_success(state, key, Map.fetch!(state.jobs, key).artefact)

  defp handle_outcome(state, key, :storage_confirmation, {:ok, artefact}),
    do: finish_success(state, key, artefact)

  defp handle_outcome(
         state,
         key,
         :storage_confirmation,
         {:error, {:incomplete_artefact, %Artefact{} = artefact}}
       ),
       do: retry_storage_or_finish(state, key, :scheduler_restart, artefact)

  defp handle_outcome(state, key, :storage_confirmation, {:error, :not_found}),
    do: retry_storage_or_finish(state, key, :scheduler_restart)

  defp handle_outcome(
         state,
         key,
         :storage_confirmation,
         {:error, {:artefact_conflict, _} = reason}
       ),
       do: finish_failure(state, key, reason)

  defp handle_outcome(state, key, :storage, {:error, {:artefact_conflict, _} = reason}),
    do: finish_failure(state, key, reason)

  defp handle_outcome(state, key, _stage, {:error, reason}),
    do: retry_or_finish(state, key, reason)

  defp handle_outcome(state, key, _stage, outcome),
    do: retry_or_finish(state, key, {:invalid_phase_response, outcome})

  defp transition(state, key, stage, artefact) do
    job = Map.fetch!(state.jobs, key)
    job = %{job | stage: stage, attempt: 1, artefact: artefact, active: false}
    :ok = Journal.put_all(state.journal, [durable_job(job)])
    launch(%{state | jobs: Map.put(state.jobs, key, job)}, key)
  end

  defp retry_or_finish(state, key, reason) do
    job = Map.fetch!(state.jobs, key)
    delays = Keyword.fetch!(job.opts, :retry_delays)

    case Enum.at(delays, job.attempt - 1) do
      nil ->
        finish_failure(state, key, reason)

      delay ->
        notify(job, {:reflection_retrying, job.reflection.name, failure(job, reason)})
        timer = Process.send_after(self(), {:retry, key}, delay)

        job = %{
          job
          | attempt: job.attempt + 1,
            retry_timer: timer,
            retry_at_ms: System.system_time(:millisecond) + delay,
            active: false
        }

        :ok = Journal.put_all(state.journal, [durable_job(job)])
        %{state | jobs: Map.put(state.jobs, key, job)}
    end
  end

  defp retry_storage_or_finish(state, key, reason, artefact \\ nil) do
    job = Map.fetch!(state.jobs, key)
    job = %{job | stage: :storage, artefact: artefact || job.artefact, active: false}
    retry_or_finish(%{state | jobs: Map.put(state.jobs, key, job)}, key, reason)
  end

  defp finish_success(state, key, artefact) do
    job = Map.fetch!(state.jobs, key)
    notify(job, {:reflection_completed, job.reflection.name, {:ok, artefact}})
    release_job(state, key)
  end

  defp finish_failure(state, key, reason) do
    job = Map.fetch!(state.jobs, key)
    error = failure(job, reason)
    notify(job, {:reflection_completed, job.reflection.name, {:error, error}})
    release_job(state, key)
  end

  defp failure(job, reason) do
    %{
      reflection: job.reflection.name,
      destination: job.reflection.destination.name,
      stage: public_stage(job.stage),
      attempts: job.attempt,
      reason: reason
    }
  end

  defp public_stage(:lookup), do: :storage
  defp public_stage(:storage_confirmation), do: :storage
  defp public_stage(stage), do: stage

  defp release_task(state, reference, task) do
    if task.timeout_ref, do: Process.cancel_timer(task.timeout_ref)
    Process.demonitor(reference, [:flush])
    %{state | tasks: Map.delete(state.tasks, reference)}
  end

  defp release_job(state, key) do
    :ok = Journal.delete(state.journal, key)
    state = %{state | jobs: Map.delete(state.jobs, key)}

    if map_size(state.jobs) == 0 do
      Enum.each(state.drainers, &GenServer.reply(&1, :ok))
      %{state | drainers: []}
    else
      state
    end
  end

  defp notify(job, message) do
    log(message)

    case Keyword.get(job.opts, :notify) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp log({:reflection_retrying, name, failure}) do
    Logger.warning(
      "[gralkor] Reflection retrying — reflection:#{name} stage:#{failure.stage} " <>
        "attempt:#{failure.attempts} reason:#{inspect(failure.reason)}"
    )
  end

  defp log({:reflection_completed, name, {:error, failure}}) do
    Logger.error(
      "[gralkor] Reflection failed — reflection:#{name} stage:#{failure.stage} " <>
        "attempts:#{failure.attempts} reason:#{inspect(failure.reason)}"
    )
  end

  defp log({:reflection_completed, _name, {:ok, _artefact}}), do: :ok

  defp validate_ingestion(ingestion) do
    id = field(ingestion, :id)
    operator_id = field(ingestion, :operator_id)

    cond do
      not valid_identity?(operator_id) -> {:error, {:invalid_operator_id, operator_id}}
      not valid_identity?(id) -> {:error, {:invalid_ingestion_id, id}}
      not completed?(ingestion) -> {:error, {:incomplete_ingestion, id}}
      true -> :ok
    end
  end

  defp validate_reflections(reflections) when is_list(reflections) do
    duplicate =
      reflections
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.find_value(fn {name, count} -> if count > 1, do: name end)

    if duplicate, do: {:error, {:duplicate_reflection, duplicate}}, else: :ok
  end

  defp valid_identity?(value), do: is_binary(value) and String.trim(value) != ""

  defp completion_key(reflection, ingestion),
    do: {field(ingestion, :operator_id), field(ingestion, :id), reflection.name}

  defp artefact_id(job) do
    {operator_id, ingestion_id, reflection_name} = job.key
    Artefact.id_for(operator_id, ingestion_id, reflection_name)
  end

  defp durable_job(job) do
    %{
      key: job.key,
      reflection: job.reflection,
      ingestion: job.ingestion,
      opts:
        Keyword.take(job.opts, [
          :runner_opts,
          :store_opts,
          :retry_delays,
          :execution_timeout_ms
        ]),
      stage: job.stage,
      attempt: job.attempt,
      artefact: job.artefact,
      active: job.active
    }
  end

  defp completed?(ingestion) do
    representations = field(ingestion, :representations) || []
    intended = field(ingestion, :intended_lenses) || Enum.map(representations, &field(&1, :lens))

    completed =
      field(ingestion, :completed_lenses) || Enum.map(representations, &field(&1, :lens))

    representations != [] and
      Enum.all?(representations, &(field(&1, :result) in [nil, :ok])) and
      Enum.all?(intended, &(&1 in completed))
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  @impl true
  def terminate(_reason, state), do: Journal.close(state.journal)
end
