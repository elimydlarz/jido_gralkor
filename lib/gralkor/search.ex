defmodule Gralkor.Search do
  @moduledoc """
  A search across the operator's reserved `"default"` Lens and additional Lenses.

  The requesting operator's reserved `"default"` Lens is always searched first.
  Each entry in `lenses` is another registered Lens name or the reserved
  `"global"` Lens. Every Lens resolves to the group its episodes live in, so
  naming a global Lens searches the whole shared global group; the originating
  Lens is attribution, not a search boundary. Results are combined in Lens
  order.
  """

  @enforce_keys [:operator_id, :query]
  defstruct [:operator_id, :query, lenses: [], max_results: 10]

  @type t :: %__MODULE__{
          operator_id: String.t(),
          query: String.t(),
          lenses: [String.t()],
          max_results: pos_integer()
        }
end
