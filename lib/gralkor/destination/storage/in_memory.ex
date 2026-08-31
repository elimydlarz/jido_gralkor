defmodule Gralkor.Destination.Storage.InMemory do
  @moduledoc false
  @behaviour Gralkor.Destination.Storage

  alias Gralkor.Destination
  alias Gralkor.Lens.Storage.InMemory, as: LensStorage
  alias Gralkor.Reflection.Storage.InMemory, as: ReflectionStorage

  @impl true
  def search(destination, operator_id, _query, :facts, max_results, _opts) do
    results =
      destination
      |> Destination.graph_id(operator_id)
      |> LensStorage.episodes()
      |> Enum.take(max_results)
      |> Enum.map(& &1.content)

    {:ok, results}
  end

  def search(destination, operator_id, _query, :episodes, max_results, _opts) do
    lens_episodes =
      destination
      |> Destination.graph_id(operator_id)
      |> LensStorage.episodes()
      |> Enum.map(& &1.content)

    reflection_episodes =
      if Process.whereis(ReflectionStorage) do
        {:ok, artefacts} =
          ReflectionStorage.search_destination(destination, operator_id, nil, max_results)

        Enum.map(artefacts, &(Jason.encode!(Map.from_struct(&1))))
      else
        []
      end

    {:ok, Enum.take(reflection_episodes ++ lens_episodes, max_results)}
  end

  def search(destination, operator_id, _query, :nodes, max_results, opts) do
    selected_labels = Keyword.get(opts, :entity_types, [])

    nodes =
      destination
      |> Destination.graph_id(operator_id)
      |> LensStorage.graph()
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
