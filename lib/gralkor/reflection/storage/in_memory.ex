defmodule Gralkor.Reflection.Storage.InMemory do
  @moduledoc false
  @behaviour Gralkor.Reflection.Store

  use Agent

  alias Gralkor.Reflection.Store

  def start_link(opts \\ []), do: Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def put(reflection, operator_id, artefact) do
    destination = Store.destination(reflection, operator_id)
    Agent.update(__MODULE__, &Map.update(&1, destination, [artefact], fn values -> values ++ [artefact] end))
  end

  @impl true
  def search(reflection, operator_id, query, max_results) do
    destination = Store.destination(reflection, operator_id)
    query = String.downcase(query || "")

    results =
      Agent.get(__MODULE__, &Map.get(&1, destination, []))
      |> Enum.filter(fn artefact -> query == "" or String.contains?(String.downcase(Jason.encode!(artefact.payload)), query) end)
      |> Enum.take(max_results)

    {:ok, results}
  end

  @impl true
  def get(reflection, operator_id, artefact_id) do
    destination = Store.destination(reflection, operator_id)
    {:ok, Agent.get(__MODULE__, &Enum.find(Map.get(&1, destination, []), fn artefact -> artefact.id == artefact_id end))}
  end
end
