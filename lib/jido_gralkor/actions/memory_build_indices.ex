defmodule JidoGralkor.Actions.MemoryBuildIndices do
  @moduledoc """
  Admin tool that rebuilds Gralkor's graph search indices.

  The `:description` is deliberately worded as a hard "DO NOT CALL" to
  the LLM. This is operator-maintenance — calling it unprompted wastes
  time and adds nothing the user will notice. The action is only useful
  when the operator (not the agent) has decided the indices need
  rebuilding, typically after a schema change or when search results
  look stale.

  No arguments: the operation runs across the whole graph, not a
  specific group.
  """

  use Jido.Action,
    name: "memory_build_indices",
    description:
      "ADMIN — DO NOT CALL unless the user has explicitly asked you to rebuild Gralkor's graph search indices. " <>
        "This is an operator-maintenance action; calling it unprompted wastes time without improving anything " <>
        "the user will notice. Idempotent rebuild of the graph search indices.",
    schema: []

  alias Gralkor.Client

  @impl true
  def run(_params, _context) do
    case Client.impl().build_indices() do
      {:ok, %{status: status}} -> {:ok, %{result: "Indices rebuilt (#{status})."}}
      {:error, reason} -> {:error, reason}
    end
  end
end
