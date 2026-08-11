defmodule Gralkor.Destination.Storage.Graphiti do
  @moduledoc false
  @behaviour Gralkor.Destination.Storage

  alias Gralkor.Destination
  alias Gralkor.Format
  alias Gralkor.GraphitiPool

  @impl true
  def search(destination, operator_id, query, :facts, max_results, _opts) do
    case GraphitiPool.search(Destination.graph_id(destination, operator_id), query, max_results) do
      {:ok, facts} -> {:ok, Enum.map(facts, &Format.format_fact/1)}
      {:error, _} = error -> error
    end
  end
end
