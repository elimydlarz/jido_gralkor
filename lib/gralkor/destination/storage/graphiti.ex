defmodule Gralkor.Destination.Storage.Graphiti do
  @moduledoc false
  @behaviour Gralkor.Destination.Storage

  alias Gralkor.Destination
  alias Gralkor.Format
  alias Gralkor.GraphitiPool

  @impl true
  def search(destination, operator_id, query, :facts, max_results, opts) do
    graph_id = Destination.graph_id(destination, operator_id)
    search_opts = Keyword.take(opts, [:edge_types])

    case GraphitiPool.search(GraphitiPool, graph_id, query, max_results, search_opts) do
      {:ok, facts} -> {:ok, Enum.map(facts, &Format.format_fact/1)}
      {:error, _} = error -> error
    end
  end

  def search(destination, operator_id, query, :nodes, max_results, opts) do
    GraphitiPool.search_nodes(
      GraphitiPool,
      Destination.graph_id(destination, operator_id),
      query,
      max_results,
      node_labels: Keyword.get(opts, :entity_types)
    )
  end

  def search(destination, operator_id, query, :episodes, max_results, _opts) do
    GraphitiPool.search_episodes(
      GraphitiPool,
      Destination.graph_id(destination, operator_id),
      query,
      max_results
    )
  end

  def search(destination, operator_id, query, :artefacts, max_results, opts) do
    search_query = Keyword.get(opts, :artefact_id) || query

    case GraphitiPool.search_episodes(
           GraphitiPool,
           Destination.graph_id(destination, operator_id),
           search_query,
           max_results
         ) do
      {:ok, episodes} ->
        artefacts = Enum.flat_map(episodes, &Gralkor.Reflection.Storage.Graphiti.decode/1)

        case Keyword.get(opts, :artefact_id) do
          nil -> {:ok, artefacts}
          id -> {:ok, Enum.filter(artefacts, &(&1.id == id))}
        end

      {:error, _} = error ->
        error
    end
  end
end
