defmodule Gralkor.Destination.Storage.InMemory do
  @moduledoc false
  @behaviour Gralkor.Destination.Storage

  alias Gralkor.Destination
  alias Gralkor.Lens.Storage.InMemory, as: LensStorage
  alias Gralkor.Reflection.Storage.InMemory, as: ReflectionStorage

  @impl true
  def put_artefact(output, _reflection_name, operator_id, artefact) do
    ReflectionStorage.put_destination(
      output.destination,
      _reflection_name,
      operator_id,
      artefact
    )
  end

  @impl true
  def get_artefact(output, _reflection_name, operator_id, artefact_id) do
    ReflectionStorage.get_destination(output.destination, operator_id, artefact_id)
  end

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

  def search(destination, operator_id, _query, :episodes, max_results, opts) do
    lenses = Keyword.get(opts, :lenses, [])

    lens_episodes =
      destination
      |> Destination.graph_id(operator_id)
      |> LensStorage.episodes()
      |> Enum.filter(&(lenses == [] or &1.lens in lenses))
      |> Enum.take(max_results)
      |> Enum.map(&Map.take(&1, [:content, :lens]))

    reflection_episodes =
      if lenses == [] and Process.whereis(ReflectionStorage) do
        destination
        |> ReflectionStorage.search_episodes(operator_id, max_results)
        |> Enum.map(fn %{artefact: artefact, reflection: reflection} ->
          %{
            content: Jason.encode!(Map.from_struct(artefact)),
            reflection: reflection
          }
        end)
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
