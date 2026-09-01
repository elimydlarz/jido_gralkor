defmodule Gralkor.Reflection.Schedule do
  @moduledoc false

  use GenServer

  alias Gralkor.Reflection.Artefact
  alias Gralkor.Reflection.Registry
  alias Gralkor.Reflection.Scheduler

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def invocation_id(reflection_name, operator_id, %NaiveDateTime{} = due_at) do
    {reflection_name, operator_id, NaiveDateTime.to_iso8601(due_at)}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  @impl true
  def init(opts) do
    state = %{
      scheduler: Keyword.get(opts, :scheduler, Scheduler),
      timers: %{}
    }

    reflections = Keyword.get_lazy(opts, :reflections, &Registry.configured!/0)
    {:ok, schedule_all(state, reflections, NaiveDateTime.utc_now())}
  end

  @impl true
  def handle_info({:due, reflection, trigger, due_at}, state) do
    invocation = %{
      id: invocation_id(reflection.name, trigger.operator_id, due_at),
      operator_id: trigger.operator_id,
      trigger: :schedule,
      trigger_context: %{scheduled_at: NaiveDateTime.to_iso8601(due_at)},
      representations: []
    }

    _ = Scheduler.schedule([reflection], invocation, server: state.scheduler)
    {:noreply, schedule_one(state, reflection, trigger, due_at)}
  end

  defp schedule_all(state, reflections, from) do
    Enum.reduce(reflections, state, fn reflection, current ->
      reflection.triggers
      |> Enum.filter(&match?(%{type: :schedule}, &1))
      |> Enum.reduce(current, &schedule_one(&2, reflection, &1, from))
    end)
  end

  defp schedule_one(state, reflection, trigger, from) do
    {:ok, cron} = parse(trigger.expression)
    {:ok, due_at} = Crontab.Scheduler.get_next_run_date(cron, from)
    delay = max(NaiveDateTime.diff(due_at, NaiveDateTime.utc_now(), :millisecond), 0)
    timer = Process.send_after(self(), {:due, reflection, trigger, due_at}, delay)
    key = {reflection.name, trigger.operator_id, trigger.expression}
    %{state | timers: Map.put(state.timers, key, timer)}
  end

  defp parse(expression) do
    extended = expression |> String.split(~r/\s+/, trim: true) |> length() |> Kernel.>(5)
    Crontab.CronExpression.Parser.parse(expression, extended)
  end
end
