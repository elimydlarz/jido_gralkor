defmodule Gralkor.Destination.Storage.InMemory do
  @moduledoc false
  @behaviour Gralkor.Destination.Storage

  alias Gralkor.Destination
  alias Gralkor.Lens.Storage.InMemory

  @impl true
  def search(destination, operator_id, _query, :facts, max_results, _opts) do
    results =
      destination
      |> Destination.graph_id(operator_id)
      |> InMemory.episodes()
      |> Enum.take(max_results)
      |> Enum.map(& &1.content)

    {:ok, results}
  end

  def search(destination, operator_id, _query, :episodes, max_results, _opts) do
    results =
      destination
      |> Destination.graph_id(operator_id)
      |> InMemory.episodes()
      |> Enum.take(max_results)
      |> Enum.map(& &1.content)

    {:ok, results}
  end

  def search(destination, operator_id, _query, :nodes, max_results, opts) do
    selected_labels = Keyword.get(opts, :entity_types, [])

    nodes =
      destination
      |> Destination.graph_id(operator_id)
      |> InMemory.graph()
      |> Map.fetch!(:nodes)
      |> Enum.filter(fn node ->
        selected_labels == [] or Enum.any?(node.labels, &(&1 in selected_labels))
      end)
      |> Enum.take(max_results)

    {:ok, nodes}
  end

  def search(destination, operator_id, query, :artefacts, max_results, opts) do
    Gralkor.Reflection.Storage.InMemory.search_destination(
      destination,
      operator_id,
      query,
      max_results,
      Keyword.get(opts, :artefact_id)
    )
  end
end
