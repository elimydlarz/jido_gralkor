defmodule Gralkor.Search do
  @moduledoc false

  @enforce_keys [:operator_id, :query, :targets]
  defstruct [:operator_id, :query, :targets, max_results: 10]

  @type t :: %__MODULE__{
          operator_id: String.t(),
          query: String.t(),
          targets: [String.t()],
          max_results: pos_integer()
        }
end
