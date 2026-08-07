defmodule Gralkor.Lens.Storage do
  @moduledoc false

  alias Gralkor.Lens.Store

  @callback add_episode(Store.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback replace_graph(Store.t(), Gralkor.Graph.t()) :: :ok | {:error, term()}
  @callback search(Store.t(), String.t(), pos_integer()) ::
              {:ok, [String.t()]} | {:error, term()}

  @optional_callbacks replace_graph: 2
end
