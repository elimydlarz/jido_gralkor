defmodule JidoGralkor.Plugin do
  @moduledoc """
  Jido plugin that replaces `Jido.Memory.BasicPlugin` with Gralkor-backed
  memory. Claims the `:__memory__` slot so it is the only memory plugin
  attached to the agent.

  On `ai.react.query` the plugin plants two values on the signal's
  `tool_context` so the `MemorySearch` ReAct tool can find them:

    * `:session_id` — the current Jido thread id (read from
      `agent.state[:__thread__].id`). Absent when no thread is
      committed yet (first query of a fresh agent, before the ReAct
      strategy's `ThreadAgent.append` runs inside `@start`); on that
      turn `MemorySearch` short-circuits with a non-result message.
    * `:agent_name` — the value supplied at mount.

  The plugin does **not** call `Gralkor.Client.recall/3` on its own.
  Recall is the LLM's job, invoked through the `MemorySearch` tool.
  Consumers force it on the first ReAct iteration via
  `JidoGralkor.ReAct.maybe_force_memory_search/2` from their
  `Jido.AI.Reasoning.ReAct.RequestTransformer`.

  Capture fires on `ai.request.completed` / `ai.request.failed`: the
  full request trace and assistant answer are normalised via
  `JidoGralkor.Canonical.to_messages/3` into Gralkor's canonical
  `[%Gralkor.Message{role, content}]` shape and shipped to the server,
  which keeps the rolling conversation buffer keyed by `session_id`.
  Capture is skipped if the thread isn't present (first-turn failure
  with nothing committed) or if the canonical message list is empty.
  Capture failures raise (Gralkor capture is server-side buffered and
  its retry lives in the capture buffer, not here — a raise from
  `capture/3` means the server is unreachable).
  """

  use Jido.Plugin,
    name: "gralkor",
    state_key: :__memory__,
    singleton: true,
    actions: [
      JidoGralkor.Actions.MemorySearch,
      JidoGralkor.Actions.MemoryAdd,
      JidoGralkor.Actions.MemoryBuildIndices,
      JidoGralkor.Actions.MemoryBuildCommunities
    ],
    description: "Gralkor-backed long-term memory",
    capabilities: [:memory]

  require Logger

  alias Gralkor.Client
  alias JidoGralkor.Canonical
  alias Jido.AI.Request
  alias Jido.Signal

  @no_thread_warning_hint "jido_ai commits state.thread on :request_completed, not at :ai.react.query — see susu-2 JIDO_CHANGE_SUGGESTIONS.md §2"

  @impl Jido.Plugin
  def mount(_agent, opts) do
    agent_name = fetch_agent_name(opts)

    unless is_binary(agent_name) and String.trim(agent_name) != "" do
      raise ArgumentError,
            "JidoGralkor.Plugin requires :agent_name (non-blank string), got #{inspect(agent_name)}"
    end

    {:ok, %{agent_name: agent_name}}
  end

  defp fetch_agent_name(opts) when is_list(opts), do: Keyword.get(opts, :agent_name)
  defp fetch_agent_name(opts) when is_map(opts), do: Map.get(opts, :agent_name)
  defp fetch_agent_name(_), do: nil

  @impl Jido.Plugin
  def handle_signal(%Signal{type: "ai.react.query"} = signal, %{agent: agent}) do
    agent_name = agent_name(agent)

    extras =
      case thread_id(agent) do
        nil -> %{agent_name: agent_name}
        id -> %{session_id: id, agent_name: agent_name}
      end

    {:ok, {:continue, merge_tool_context(signal, extras)}}
  end

  def handle_signal(
        %Signal{
          type: "ai.request.completed",
          data: %{request_id: request_id, result: result}
        },
        %{agent: agent}
      )
      when is_binary(request_id) and is_binary(result) do
    capture_turn(agent, request_id, {:completed, result})
    {:ok, :continue}
  end

  def handle_signal(
        %Signal{
          type: "ai.request.failed",
          data: %{request_id: request_id, error: error}
        },
        %{agent: agent}
      )
      when is_binary(request_id) do
    capture_turn(agent, request_id, {:failed, error})
    {:ok, :continue}
  end

  def handle_signal(_signal, _context), do: {:ok, :continue}

  defp capture_turn(agent, request_id, outcome) do
    events =
      agent.state
      |> Map.get(:__strategy__, %{})
      |> Map.get(:request_traces, %{})
      |> Map.get(request_id, %{events: []})
      |> Map.get(:events, [])

    session_id = thread_id(agent)

    cond do
      events == [] ->
        :ok

      is_nil(session_id) ->
        Logger.warning(
          "[jido_gralkor] skipping capture — no thread committed yet for agent #{inspect(agent.id)} (#{@no_thread_warning_hint})"
        )

        :ok

      true ->
        user_query =
          case Request.get_request(agent, request_id) do
            %{query: q} when is_binary(q) -> q
            _ -> ""
          end

        case Canonical.to_messages(user_query, events, outcome) do
          [] ->
            :ok

          messages ->
            group_id = Client.sanitize_group_id(agent.id)
            user_name = user_name!(agent)

            case Client.impl().capture(
                   session_id,
                   group_id,
                   agent_name(agent),
                   user_name,
                   messages
                 ) do
              :ok -> :ok
              {:error, reason} -> raise "Gralkor capture failed: #{inspect(reason)}"
            end
        end
    end
  end

  defp user_name!(agent) do
    case Map.get(agent.state, :user_name) do
      name when is_binary(name) ->
        if String.trim(name) == "" do
          raise ArgumentError,
                "JidoGralkor.Plugin: agent.state[:user_name] is blank — the consumer must populate it (e.g. from `tool_context[:name]` in `on_before_cmd`) before any turn that captures"
        else
          name
        end

      other ->
        raise ArgumentError,
              "JidoGralkor.Plugin: agent.state[:user_name] missing (got #{inspect(other)}) — the consumer must populate it (e.g. from `tool_context[:name]` in `on_before_cmd`) before any turn that captures"
    end
  end

  defp agent_name(agent) do
    case Map.get(agent.state, :__memory__) do
      %{agent_name: name} when is_binary(name) -> name
      _ -> raise "JidoGralkor.Plugin state missing — mount/2 must run before recall/capture"
    end
  end

  defp thread_id(agent) do
    case Map.get(agent.state, :__thread__) do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp merge_tool_context(%Signal{data: data} = signal, extras) when is_map(extras) do
    existing_context = Map.get(data, :tool_context, %{})
    new_context = Map.merge(existing_context, extras)
    %{signal | data: Map.put(data, :tool_context, new_context)}
  end
end
