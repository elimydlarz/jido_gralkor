defmodule Gralkor.Search do
  @moduledoc """
  A search in either the Lens namespace or the Reflection namespace.

  With no named Reflections, the requesting operator's reserved `"operator"`
  Lens is included alongside entries in `lenses`. With entries in
  `reflections`, only those Reflection destinations are searched and results
  are Reflection artefacts rather than Lens-attributed facts. `artefact_id`
  optionally narrows that Reflection search to one exact artefact.
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
