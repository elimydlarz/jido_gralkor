defmodule Gralkor.Lens.Storage do
  @moduledoc false

  alias Gralkor.Lens.Store

  @callback add_episode(Store.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback add_episode(Store.t(), String.t(), String.t(), keyword()) ::
              :ok | {:error, term()}
  @callback remove_episode(Store.t(), String.t()) :: :ok | {:error, term()}
  @callback search(Store.t(), String.t(), pos_integer()) ::
              {:ok, [String.t()]} | {:error, term()}

  @optional_callbacks add_episode: 4
end
