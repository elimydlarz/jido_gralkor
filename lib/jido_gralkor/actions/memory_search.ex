defmodule JidoGralkor.Actions.MemorySearch do
  @moduledoc """
  ReAct tool the LLM can call to search long-term memory.

  Calls `Gralkor.Client.recall/3`. `group_id` is sanitized from
  `context[:agent_id]` and `session_id` is read from
  `context[:session_id]` (planted by `JidoGralkor.Plugin` on
  `ai.react.query`).

  Short-circuits with an explicit non-result message when:

    * `session_id` is absent or blank (first query of a fresh agent,
      before the ReAct strategy committed a thread), or
    * `query` is blank — defensive against forced-tool-call paths
      (`tool_choice: memory_search`) where the LLM is required to
      invoke the tool but has nothing meaningful to search for.

  Otherwise returns the memory block the server produced. Errors
  propagate.
  """

  use Jido.Action,
    name: "memory_search",
    description: "Search long-term memory for relevant context. Use specific, focused queries.",
    schema: [
      query: [type: :string, default: "", doc: "The search query"]
    ]

  require Logger

  alias Gralkor.Client

  @no_session_result "Memory search did not run: this conversation's session has not been established yet. This is a NON-RESULT, not an empty result — long-term memory was NOT queried. Do not claim you have no memory of prior interactions; either tell the user you cannot check memory right now, or answer without relying on prior context."

  @no_query_result "Memory search did not run: no query was provided. Pick a focused query (a concrete episode, behaviour, or topic) and call memory_search again. This is a NON-RESULT, not an empty result — long-term memory was NOT queried."

  @no_session_warning_hint "jido_ai commits state.thread on :request_completed, not at :ai.react.query — see susu-2 JIDO_CHANGE_SUGGESTIONS.md §2"

  @impl true
  def run(params, context) do
    query = params |> Map.get(:query, "") |> to_string() |> String.trim()
    session_id = Map.get(context, :session_id)

    cond do
      query == "" ->
        Logger.warning(
          "[jido_gralkor] memory_search short-circuited — blank query for agent #{inspect(Map.get(context, :agent_id))}"
        )

        {:ok, %{result: @no_query_result}}

      session_id in [nil, ""] ->
        Logger.warning(
          "[jido_gralkor] memory_search short-circuited — no session_id in ReAct tool context for agent #{inspect(Map.get(context, :agent_id))} (#{@no_session_warning_hint})"
        )

        {:ok, %{result: @no_session_result}}

      true ->
        group_id = context |> Map.fetch!(:agent_id) |> Client.sanitize_group_id()
        agent_name = Map.fetch!(context, :agent_name)

        case Client.impl().recall(group_id, agent_name, session_id, query) do
          {:ok, memory_block} -> {:ok, %{result: memory_block}}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
