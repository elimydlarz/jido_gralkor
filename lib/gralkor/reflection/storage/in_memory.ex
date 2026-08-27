defmodule Gralkor.Reflection.Storage.InMemory do
  @moduledoc false
  @behaviour Gralkor.Reflection.Store

  use Agent

  alias Gralkor.Reflection.Store

  def start_link(opts \\ []),
    do: Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def put(reflection, operator_id, artefact) do
    destination = Store.destination(reflection, operator_id)

    Agent.update(
      __MODULE__,
      &Map.update(&1, destination, [artefact], fn values -> values ++ [artefact] end)
    )
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
