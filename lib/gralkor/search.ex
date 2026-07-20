defmodule Gralkor.Search do
  @moduledoc """
  A search across explicitly selected Lens destinations.

  Each target is either a registered operator-local Lens name or the reserved
  `"global"` target. `"global"` searches the whole shared global pool without
  filtering by originating Lens; global Lens names are provenance and cannot
  be used as search targets. Results are combined in target order.
  """

  @enforce_keys [:operator_id, :query]
  defstruct [:operator_id, :query, targets: [], max_results: 10]

  @type t :: %__MODULE__{
          operator_id: String.t(),
          query: String.t(),
          targets: [String.t()],
          max_results: pos_integer()
        }
end
