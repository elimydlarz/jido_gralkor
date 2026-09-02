defmodule Gralkor.Destination.Storage.InMemory do
  @moduledoc false
  @behaviour Gralkor.Destination.Storage

  use Agent

  alias Gralkor.Destination
  alias Gralkor.Lens.Storage.InMemory, as: LensStorage

  def start_link(opts \\ []),
    do: Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def put_artefact(output, reflection_name, operator_id, artefact) do
    graph_id = Destination.graph_id(output.destination, operator_id)

    Agent.get_and_update(__MODULE__, fn state ->
      entries = Map.get(state, graph_id, [])

      case Enum.find(entries, &(&1.artefact.id == artefact.id)) do
        nil ->
          entry = %{artefact: artefact, reflection: reflection_name}
          {:ok, Map.put(state, graph_id, entries ++ [entry])}

        %{artefact: ^artefact} ->
          {:ok, state}

        _entry ->
          {{:error, {:artefact_conflict, artefact.id}}, state}
      end
    end)
  end

  @impl true
  def get_artefact(output, _reflection_name, operator_id, artefact_id) do
    graph_id = Destination.graph_id(output.destination, operator_id)

    Agent.get(__MODULE__, fn state ->
      case Enum.find(Map.get(state, graph_id, []), &(&1.artefact.id == artefact_id)) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry.artefact}
      end
    end)
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
      if lenses == [] and Process.whereis(__MODULE__) do
        destination
        |> artefact_entries(operator_id)
        |> Enum.take(max_results)
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
    artefact_id = Keyword.get(opts, :artefact_id)

    results =
      destination
      |> artefact_entries(operator_id)
      |> Enum.map(& &1.artefact)
      |> Enum.filter(fn artefact ->
        (is_nil(artefact_id) or artefact.id == artefact_id) and
          (query in [nil, ""] or
             String.contains?(
               String.downcase(Jason.encode!(artefact.payload)),
               String.downcase(query)
             ))
      end)
      |> Enum.take(max_results)

    {:ok, results}
  end

  defp artefact_entries(destination, operator_id) do
    graph_id = Destination.graph_id(destination, operator_id)
    Agent.get(__MODULE__, &Map.get(&1, graph_id, []))
  end
end
