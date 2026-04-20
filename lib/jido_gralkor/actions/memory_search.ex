defmodule JidoGralkor.Actions.MemorySearch do
  @moduledoc """
  ReAct tool the LLM can call to search long-term memory.

  Calls `Gralkor.Client.memory_search/3` with `group_id` sanitized
  from `context[:agent_id]` and `session_id` read from `context[:session_id]`
  (planted by `JidoGralkor.Plugin` on `ai.react.query` — the Jido thread id).

  If `session_id` is absent or blank (the LLM called the tool on the very
  first query of a fresh agent, before the ReAct strategy committed a
  thread to agent state) the action short-circuits with an explicit
  non-result message — there is no session buffer to interpret against
  yet, and Gralkor requires a real session id. The message tells the LLM
  the search did not run, so it doesn't read an empty payload as "no
  memory exists" and confidently lie to the user. Errors from the client
  propagate.
  """

  use Jido.Action,
    name: "memory_search",
    description: "Search long-term memory for relevant context. Use specific, focused queries.",
    schema: [
      query: [type: :string, required: true, doc: "The search query"]
    ]

  alias Gralkor.Client

  @no_session_result "Memory search did not run: this conversation's session has not been established yet. This is a NON-RESULT, not an empty result — long-term memory was NOT queried. Do not claim you have no memory of prior interactions; either tell the user you cannot check memory right now, or answer without relying on prior context."

  @impl true
  def run(%{query: query}, context) do
    case Map.get(context, :session_id) do
      blank when blank in [nil, ""] ->
        {:ok, %{result: @no_session_result}}

      session_id ->
        group_id = context |> Map.get(:agent_id, "") |> Client.sanitize_group_id()

        case Client.impl().memory_search(group_id, session_id, query) do
          {:ok, text} -> {:ok, %{result: text}}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
