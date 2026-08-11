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
end
