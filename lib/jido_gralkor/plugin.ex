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

  Recall fires on `ai.react.query`: Gralkor is always called with the
  agent's `group_id` and the current thread's session id (or `nil`
  when no thread has committed yet — first query of a fresh agent,
  before the ReAct strategy's `ThreadAgent.append` runs inside
  `@start`). When a thread is committed, its session id is planted on
  the signal's `tool_context` so in-turn tool calls (e.g.
  `MemorySearch`) key on the same session; when it isn't, no session
  id is planted. The returned memory block (when present) is stashed
  on `tool_context` under `:__gralkor_memory__` regardless of thread
  state. The plugin does not mutate `:query` — the recalled memory is
  delivered to the LLM by a request transformer at prompt-build time
  (see `Jido.AI.Reasoning.ReAct.RequestTransformer` and
  `Jido.AI.PromptBuilder`), keeping `:query` the user's actual words
  everywhere downstream (buffer, request store, capture).

  Capture fires on `ai.request.completed` / `ai.request.failed`: the
  full request trace and assistant answer are normalised via
  `JidoGralkor.Canonical.to_messages/3` into Gralkor's canonical
  `[%Gralkor.Message{role, content}]` shape and shipped to the server,
  which keeps the rolling conversation buffer keyed by `session_id`.
  Because nothing in the turn mutates `:query` to add harness context,
  canonicalisation doesn't strip envelopes — the user message it
  persists is the user's actual words. Capture is skipped if the
  thread isn't present (first-turn failure with nothing committed) or
  if the canonical message list is empty.

  Recall failures are best-effort under the retry-ownership doctrine
  (see `gralkor/TEST_TREES.md › Retry ownership`): if the Vertex-upstream
  retries at the google-genai SDK exhaust, `Client.recall/3` returns
  `{:error, _}` and the plugin logs a warning and continues the turn
  without `:__gralkor_memory__`. Retrying here would amplify load
  without a meaningful chance of success, and failing the turn would
  turn a memory outage into a user-facing outage. Capture failures still
  raise (Gralkor capture is server-side buffered and its retry lives in
  the capture buffer, not here — a raise from `capture/3` means the
  server is unreachable, which is a different failure class).
  """

  use Jido.Plugin,
    name: "gralkor",
    state_key: :__memory__,
    singleton: true,
    actions: [],
    signal_patterns: ["ai.react.query", "ai.request.completed", "ai.request.failed"],
    description: "Gralkor-backed long-term memory",
    capabilities: [:memory]

  require Logger

  alias Gralkor.Client
  alias JidoGralkor.Canonical
  alias Jido.AI.Request
  alias Jido.Signal

  @no_thread_warning_hint "jido_ai commits state.thread on :request_completed, not at :ai.react.query — see susu-2 JIDO_CHANGE_SUGGESTIONS.md §2"

  @impl Jido.Plugin
  def mount(_agent, _config), do: {:ok, nil}

  @impl Jido.Plugin
  def handle_signal(
        %Signal{type: "ai.react.query", data: %{query: query}} = signal,
        %{agent: agent}
      ) do
    group_id = Client.sanitize_group_id(agent.id)
    session_id = thread_id(agent)

    signal_with_session =
      case session_id do
        nil -> signal
        id -> merge_tool_context(signal, %{session_id: id})
      end

    case Client.impl().recall(group_id, session_id, query) do
      {:ok, nil} ->
        {:ok, {:continue, signal_with_session}}

      {:ok, memory_block} when is_binary(memory_block) ->
        {:ok,
         {:continue,
          merge_tool_context(signal_with_session, %{
            :__gralkor_memory__ => memory_block
          })}}

      {:error, reason} ->
        Logger.warning(
          "[jido_gralkor] recall failed — continuing turn without memory context: #{inspect(reason)}"
        )

        {:ok, {:continue, signal_with_session}}
    end
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

            case Client.impl().capture(session_id, group_id, messages) do
              :ok -> :ok
              {:error, reason} -> raise "Gralkor capture failed: #{inspect(reason)}"
            end
        end
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
