defmodule Gralkor.Lens.Storage do
  @moduledoc false

  alias Gralkor.Lens.Store

  @callback add_episode(Store.t(), String.t(), String.t()) :: :ok | {:error, term()}
end
