defmodule JidoGralkor.Actions.MemorySearch do
  @moduledoc """
  ReAct tool the LLM can call to search long-term memory.

  Calls runtime-targeted `Gralkor.Client.search/2` with the current operator and
  the optional Destination selector supplied for this invocation. A
  direct action invocation without a mounted runtime uses the compatibility
  `Gralkor.Client.search/1` boundary. Search does not depend on the ingestion
  Lens or on a committed conversation thread.

  Short-circuits with an explicit non-result message when:

    * `query` is blank — defensive against forced-tool-call paths
      (`tool_choice: memory_search`) where the LLM is required to
      invoke the tool but has nothing meaningful to search for.

  Results are `%{sections: [%{heading:, text:}]}`, one section for each Lens,
  Reflection, or direct source that wrote matching memory, then an
  `Entities in <Destination> memory` section for each Destination that returned
  entities (`JidoGralkor.MemorySearchPresentation.sections/1`). Each section has its
  own character limit, well under Jido's 16,384-character string limit, and counts
  the memories it omits; no limit applies across sections.
  The structured search API remains available for consumers that format their own data.
  Errors propagate.
  """

  use Jido.Action,
    name: "memory_search",
    description:
      "Search related stored observations and generalisations. Use the returned memories. Use a specific, focused query.",
    schema: [
      query: [type: :string, default: "", doc: "The search query"],
      destinations: [
        type: {:list, :string},
        default: [],
        doc: "Optional Destination names to search"
      ]
    ]

  require Logger

  alias Gralkor.Client
  alias Gralkor.Search
  alias JidoGralkor.MemorySearchPresentation

  @no_query_result "Memory search did not run: no query was provided. Pick a focused query (a concrete episode, behaviour, or topic) and call memory_search again. This is a NON-RESULT, not an empty result — long-term memory was NOT queried."

  @impl true
  def run(params, context) do
    max_bytes =
      context
      |> Map.get(:memory_search_max_bytes, MemorySearchPresentation.default_max_bytes())
      |> MemorySearchPresentation.validate_max_bytes!()

    query = params |> Map.get(:query, "") |> to_string()

    if String.trim(query) == "" do
      Logger.warning(
        "[jido_gralkor] memory_search short-circuited — blank query for agent #{inspect(Map.get(context, :agent_id))}"
      )

      {:ok, %{result: @no_query_result}}
    else
      request = %Search{
        operator_id: Map.fetch!(context, :agent_id),
        query: query,
        destinations: Map.get(params, :destinations, [])
      }

      result =
        case Map.get(context, :gralkor_runtime) do
          runtime_owner when not is_nil(runtime_owner) ->
            Client.search(runtime_owner, request)

          nil ->
            Client.search(request)
        end

      with {:ok, results} <- result,
           do: MemorySearchPresentation.for_model(results, max_bytes)
    end
  end
end
