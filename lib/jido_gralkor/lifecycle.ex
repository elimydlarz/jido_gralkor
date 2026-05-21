defmodule JidoGralkor.Lifecycle do
  @moduledoc """
  `Jido.AgentServer.Lifecycle` implementation that flushes the active
  Gralkor session when an agent process terminates.

  Sole job: on `terminate/2`, read the committed Jido thread id from
  `state.agent.state[:__thread__].id` and fire-and-forget
  `Gralkor.Client.flush(thread_id)` so the buffered turns don't strand
  in `Gralkor.CaptureBuffer` state outliving the agent. Failures are
  logged but never block termination. First-turn agents (no thread
  committed yet) terminate without calling Gralkor.

  Memory consolidation while the agent is alive is owned by
  `JidoGralkor.ContextRotator`, not this module. The AgentServer's
  built-in `:idle_timeout` knob is unaffected — consumers can use it
  directly if they want a reaper, but this module no longer wires one
  on their behalf.
  """

  @behaviour Jido.AgentServer.Lifecycle

  require Logger

  alias Gralkor.Client

  @impl true
  def init(_opts, state), do: state

  @impl true
  def handle_event(_event, state), do: {:cont, state}

  @impl true
  def terminate(reason, state) do
    case state.agent.state[:__thread__] do
      %{id: id} when is_binary(id) -> fire_flush_async(id, reason)
      _ -> :ok
    end

    :ok
  end

  defp fire_flush_async(thread_id, reason) do
    client = Client.impl()

    Logger.info("[gralkor] flush — session:#{thread_id} reason:#{inspect(reason)}")

    Task.start(fn ->
      case client.flush(thread_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("[gralkor] flush failed: #{inspect(reason)}")
      end
    end)
  end
end
