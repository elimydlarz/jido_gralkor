defmodule JidoGralkor.Plugin do
  @moduledoc """
  Jido plugin that replaces `Jido.Memory.BasicPlugin` with Gralkor-backed
  memory. Claims the `:__memory__` slot so it is the only memory plugin
  attached to the agent.

  `session_id` is the current Jido thread id, read from
  `agent.state[:__thread__].id`. One Jido thread per Gralkor session —
  the capture buffer rotates naturally when the thread rotates, and
  concurrent agents for the same principal never collide on the buffer.
  `group_id` is `sanitize_group_id(agent.id)` since memory graph
  partitioning is per-principal.

  Recall fires on `ai.react.query`: if a thread is already committed in
  agent state, recall Gralkor for the current thread's session; inject
  the session id into the signal's `tool_context` so in-turn tool calls
  (e.g. `MemorySearch`) key on the same session. On the very first
  query of a fresh agent, `ThreadAgent.append` hasn't yet run (the
  ReAct strategy calls it inside `@start`, after the plugin hook), so
  there's nothing to recall against — the plugin passes the signal
  through unchanged and lets capture establish the session when the
  turn completes.

  Capture fires on `ai.request.completed` / `ai.request.failed`: the
  full request trace and assistant answer are bundled into a turn and
  sent to Gralkor, which keeps the rolling conversation buffer
  server-side keyed by `session_id`. Capture is skipped if the thread
  isn't present (first-turn failure with nothing committed).

  Gralkor errors raise — the caller sees the real error, per the
  project's fail-fast rule.
  """

  use Jido.Plugin,
    name: "gralkor",
    state_key: :__memory__,
    singleton: true,
    actions: [],
    signal_patterns: ["ai.react.query", "ai.request.completed", "ai.request.failed"],
    description: "Gralkor-backed long-term memory",
    capabilities: [:memory]

  alias Gralkor.Client
  alias Jido.AI.Request
  alias Jido.Signal

  @impl Jido.Plugin
  def mount(_agent, _config), do: {:ok, nil}

  @impl Jido.Plugin
  def handle_signal(%Signal{type: "ai.react.query", data: data} = signal, %{agent: agent}) do
    group_id = Client.sanitize_group_id(agent.id)
    query = Map.get(data, :query, "")

    case thread_id(agent) do
      nil ->
        {:ok, :continue}

      session_id ->
        signal_with_session = inject_session_id(signal, session_id)

        case Client.impl().recall(group_id, session_id, query) do
          {:ok, nil} ->
            {:ok, {:continue, signal_with_session}}

          {:ok, memory_block} when is_binary(memory_block) ->
            new_data = Map.put(signal_with_session.data, :query, memory_block <> "\n\n" <> query)
            {:ok, {:continue, %{signal_with_session | data: new_data}}}

          {:error, reason} ->
            raise "Gralkor recall failed: #{inspect(reason)}"
        end
    end
  end

  def handle_signal(%Signal{type: type, data: data}, %{agent: agent})
      when type in ["ai.request.completed", "ai.request.failed"] do
    capture_turn(agent, Map.get(data, :request_id), Map.get(data, :result, ""))
    {:ok, :continue}
  end

  def handle_signal(_signal, _context), do: {:ok, :continue}

  defp capture_turn(agent, request_id, assistant_answer) when is_binary(request_id) do
    events =
      agent.state
      |> Map.get(:__strategy__, %{})
      |> Map.get(:request_traces, %{})
      |> Map.get(request_id, %{events: []})
      |> Map.get(:events, [])

    cond do
      events == [] ->
        :ok

      is_nil(thread_id(agent)) ->
        :ok

      true ->
        user_query =
          case Request.get_request(agent, request_id) do
            %{query: q} when is_binary(q) -> q
            _ -> ""
          end

        group_id = Client.sanitize_group_id(agent.id)
        session_id = thread_id(agent)

        turn = %{
          user_query: user_query,
          assistant_answer: assistant_answer || "",
          events: events
        }

        case Client.impl().capture(session_id, group_id, turn) do
          :ok -> :ok
          {:error, reason} -> raise "Gralkor capture failed: #{inspect(reason)}"
        end
    end
  end

  defp capture_turn(_agent, _request_id, _answer), do: :ok

  defp thread_id(agent) do
    case Map.get(agent.state, :__thread__) do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp inject_session_id(%Signal{data: data} = signal, session_id) do
    existing_context = Map.get(data, :tool_context, %{}) || %{}
    new_context = Map.put(existing_context, :session_id, session_id)
    %{signal | data: Map.put(data, :tool_context, new_context)}
  end
end
