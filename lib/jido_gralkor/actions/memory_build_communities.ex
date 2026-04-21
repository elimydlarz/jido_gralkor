defmodule JidoGralkor.Actions.MemoryBuildCommunities do
  @moduledoc """
  Admin tool that runs Graphiti's community detection over this agent's
  memory partition.

  The `:description` is deliberately worded as a hard "DO NOT CALL" to
  the LLM. This is expensive operator-maintenance — calling it unprompted
  wastes time. Only useful when the operator (not the agent) has decided
  community detection should run, typically after significant ingestion.

  `group_id` is derived from `context[:agent_id]` via
  `Gralkor.Client.sanitize_group_id/1` — the community build is scoped to
  this agent's graph partition.
  """

  use Jido.Action,
    name: "memory_build_communities",
    description:
      "ADMIN — DO NOT CALL unless the user has explicitly asked you to build Gralkor communities. " <>
        "This is an expensive operator-maintenance action; calling it unprompted wastes time. " <>
        "Runs Graphiti community detection over this agent's memory partition.",
    schema: []

  alias Gralkor.Client

  @impl true
  def run(_params, context) do
    group_id = context |> Map.fetch!(:agent_id) |> Client.sanitize_group_id()

    case Client.impl().build_communities(group_id) do
      {:ok, %{communities: communities, edges: edges}} ->
        {:ok,
         %{result: "Built #{communities} community/ies across #{edges} edges in #{group_id}."}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
