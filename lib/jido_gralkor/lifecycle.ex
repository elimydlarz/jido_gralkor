defmodule JidoGralkor.Lifecycle do
  @moduledoc """
  `Jido.AgentServer.Lifecycle` implementation that turns AgentServer
  termination into a Gralkor session-end.

  Owns an idle timer (armed from `state.lifecycle.idle_timeout` when
  positive), cancels and re-arms on each `:touch` event the consumer
  casts on user activity, and on idle expiry returns
  `{:stop, {:shutdown, :idle_timeout}, state}`. `terminate/2` reads the
  committed Jido thread id from `state.agent.state[:__thread__].id` and
  fire-and-forgets `Gralkor.Client.end_session(thread_id)` via
  `Task.start`; failures are logged but never block termination.
  First-turn agents (no thread committed yet) terminate without
  calling Gralkor.

  Consumers decide policy (timeout duration, when to call `:touch`,
  when to issue `GenServer.stop`); this module owns the mechanism.
  """

  @behaviour Jido.AgentServer.Lifecycle

  require Logger

  alias Gralkor.Client

  @impl true
  def init(_opts, state), do: maybe_start_idle_timer(state)

  @impl true
  def handle_event(:touch, state) do
    state = cancel_idle_timer(state)
    {:cont, maybe_start_idle_timer(state)}
  end

  def handle_event(:idle_timeout, state) do
    {:stop, {:shutdown, :idle_timeout}, state}
  end

  def handle_event(_event, state), do: {:cont, state}

  @impl true
  def terminate(reason, state) do
    case state.agent.state[:__thread__] do
      %{id: id} when is_binary(id) -> fire_end_session_async(id, reason)
      _ -> :ok
    end

    :ok
  end

  defp maybe_start_idle_timer(state) do
    timeout = state.lifecycle.idle_timeout

    if is_integer(timeout) and timeout > 0 do
      timer_ref = :erlang.start_timer(timeout, self(), :lifecycle_idle_timeout)
      %{state | lifecycle: %{state.lifecycle | idle_timer: timer_ref}}
    else
      state
    end
  end

  defp cancel_idle_timer(state) do
    if state.lifecycle.idle_timer do
      :erlang.cancel_timer(state.lifecycle.idle_timer)
      %{state | lifecycle: %{state.lifecycle | idle_timer: nil}}
    else
      state
    end
  end

  defp fire_end_session_async(thread_id, reason) do
    client = Client.impl()

    Logger.info("[gralkor] end_session — session:#{thread_id} reason:#{inspect(reason)}")

    Task.start(fn ->
      case client.end_session(thread_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("[gralkor] end_session failed: #{inspect(reason)}")
      end
    end)
  end
end
