defmodule Gralkor.Search do
  @moduledoc "A search across one or more registered memory Destinations."

  @enforce_keys [:operator_id, :query]
  defstruct [
    :operator_id,
    :query,
    destinations: [],
    result_type: :facts,
    entity_types: [],
    edge_types: [],
    artefact_id: nil,
    max_results: 20
  ]

  @type result_type :: :facts | :nodes | :episodes | :artefacts

  @type t :: %__MODULE__{
          operator_id: String.t(),
          query: String.t(),
          destinations: [String.t()],
          result_type: result_type(),
          entity_types: [String.t()],
          edge_types: [String.t()],
          artefact_id: String.t() | nil,
          max_results: pos_integer()
        }
end
