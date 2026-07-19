defmodule Gralkor.Lens.Storage do
  @moduledoc false

  alias Gralkor.Lens.Store

  @callback add_episode(Store.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback remove_episode(Store.t(), String.t()) :: :ok | {:error, term()}
  @callback search(Store.t(), String.t(), pos_integer()) ::
              {:ok, [String.t()]} | {:error, term()}
end
