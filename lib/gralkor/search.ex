defmodule Gralkor.Search do
  @moduledoc """
  A search across the reserved `"operator"` Lens and additional Lenses.

  The requesting operator's reserved `"operator"` Lens is always included. Each
  entry in `lenses` is another registered Lens name or the reserved `"global"`
  Lens. Distinct names resolving to the shared global group cause one physical
  search. Resolved destinations are searched concurrently, and attributed
  results retain Lens order.
  """

  @enforce_keys [:operator_id, :query]
  defstruct [:operator_id, :query, lenses: [], reflections: [], artefact_id: nil, max_results: 20]

  @type t :: %__MODULE__{
          operator_id: String.t(),
          query: String.t(),
          lenses: [String.t()],
          reflections: [String.t()],
          artefact_id: String.t() | nil,
          max_results: pos_integer()
        }
end
