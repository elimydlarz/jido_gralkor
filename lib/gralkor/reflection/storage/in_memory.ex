defmodule Gralkor.Reflection.Storage.InMemory do
  @moduledoc false
  @behaviour Gralkor.Reflection.Store

  use Agent

  def start_link(opts \\ []),
    do: Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def put(reflection, operator_id, artefact) do
    put_destination(reflection.destination, reflection.name, operator_id, artefact)
  end

  def put_destination(destination, operator_id, artefact) do
    put_destination(destination, nil, operator_id, artefact)
  end

  def put_destination(destination, reflection_name, operator_id, artefact) do
    destination = Gralkor.Destination.graph_id(destination, operator_id)

    Agent.get_and_update(__MODULE__, fn state ->
      entries = Map.get(state, destination, [])

      case Enum.find(entries, &(entry_artefact(&1).id == artefact.id)) do
        nil ->
          entry = %{artefact: artefact, reflection: reflection_name}
          {:ok, Map.put(state, destination, entries ++ [entry])}

        entry ->
          if entry_artefact(entry) == artefact do
            {:ok, state}
          else
            {{:error, {:artefact_conflict, artefact.id}}, state}
          end
      end
    end)
  end

  @impl true
  def get(reflection, operator_id, artefact_id) do
    get_destination(reflection.destination, operator_id, artefact_id)
  end

  def get_destination(destination, operator_id, artefact_id) do
    destination = Gralkor.Destination.graph_id(destination, operator_id)

    Agent.get(__MODULE__, fn state ->
      case Enum.find(Map.get(state, destination, []), &(entry_artefact(&1).id == artefact_id)) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry_artefact(entry)}
      end
    end)
  end

  @doc false
  def search_destination(destination, operator_id, query, max_results, artefact_id \\ nil) do
    graph_id = Gralkor.Destination.graph_id(destination, operator_id)

    results =
      Agent.get(__MODULE__, &Map.get(&1, graph_id, []))
      |> Enum.map(&entry_artefact/1)
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

  def search_episodes(destination, operator_id, max_results) do
    graph_id = Gralkor.Destination.graph_id(destination, operator_id)

    __MODULE__
    |> Agent.get(&Map.get(&1, graph_id, []))
    |> Enum.take(max_results)
  end

  defp entry_artefact(%{artefact: artefact}), do: artefact
  defp entry_artefact(artefact), do: artefact
end
