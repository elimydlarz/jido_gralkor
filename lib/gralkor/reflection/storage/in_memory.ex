defmodule Gralkor.Reflection.Storage.InMemory do
  @moduledoc false
  @behaviour Gralkor.Reflection.Store

  use Agent

  def start_link(opts \\ []),
    do: Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def put(reflection, operator_id, artefact) do
    put_destination(reflection.destination, operator_id, artefact)
  end

  def put_destination(destination, operator_id, artefact) do
    destination = Gralkor.Destination.graph_id(destination, operator_id)

    Agent.get_and_update(__MODULE__, fn state ->
      artefacts = Map.get(state, destination, [])

      case Enum.find(artefacts, &(&1.id == artefact.id)) do
        ^artefact ->
          {:ok, state}

        nil ->
          {:ok, Map.put(state, destination, artefacts ++ [artefact])}

        _conflicting ->
          {{:error, {:artefact_conflict, artefact.id}}, state}
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
      case Enum.find(Map.get(state, destination, []), &(&1.id == artefact_id)) do
        nil -> {:error, :not_found}
        artefact -> {:ok, artefact}
      end
    end)
  end

  @doc false
  def search_destination(destination, operator_id, query, max_results, artefact_id \\ nil) do
    graph_id = Gralkor.Destination.graph_id(destination, operator_id)

    results =
      Agent.get(__MODULE__, &Map.get(&1, graph_id, []))
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
end
