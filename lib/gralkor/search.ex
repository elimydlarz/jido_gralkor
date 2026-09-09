defmodule Gralkor.Search do
  @moduledoc """
  A search across registered memory Destinations.

  With empty `destinations` and `lenses`, search reads episodes from every
  accessible registered Destination and from every Lens and Reflection writer.
  The packaged `operator` Destination resolves only to the current
  `operator_id`'s graph.

  `destinations` selects graphs and `lenses` filters episode writers. Names are
  ORed within either list and the two dimensions are ANDed together. Lens
  filtering is valid only for episode results. A Lens-written episode exposes
  `content`, `source_description`, and `lens`; a Reflection-written episode
  exposes `artefact: %{id: id, payload: payload}`, `source_description`, and
  its writer as `reflection`. Reflection episodes have no encoded `content`.
  Naturally textual Lens content remains text, including JSON-looking source
  records. Facts retain their text, timestamps, and structured `sources`; use
  `Gralkor.Format.format_fact/1` explicitly for readable fact presentation.

  Episodes are the default result type. Facts, nodes, and Reflection artefacts
  remain available by explicitly setting `result_type` to `:facts`, `:nodes`,
  or `:artefacts`.
  """

  @type lens_episode :: %{content: String.t(), source_description: String.t(), lens: String.t()}
  @type reflection_episode :: %{
          artefact: %{id: String.t(), payload: map()},
          source_description: String.t(),
          reflection: String.t()
        }
  @type result ::
          %{destination: String.t(), episode: lens_episode() | reflection_episode()}
          | %{destination: String.t(), fact: map()}
          | %{destination: String.t(), node: map()}
          | %{destination: String.t(), artefact: Gralkor.Artefact.t()}

  @enforce_keys [:operator_id, :query]
  defstruct [
    :operator_id,
    :query,
    destinations: [],
    lenses: [],
    result_type: :episodes,
    entity_types: [],
    edge_types: [],
    artefact_id: nil,
    max_results: 20
  ]

  @typedoc "The requested representation; episodes are the public default."
  @type result_type :: :facts | :nodes | :episodes | :artefacts

  @typedoc """
  One search request.

  Empty selector lists mean all accessible Destinations and all episode
  writers. `entity_types`, `edge_types`, and `artefact_id` apply only to their
  corresponding explicit advanced result types. `max_results` applies
  independently to each selected Destination.
  """
  @type t :: %__MODULE__{
          operator_id: String.t(),
          query: String.t(),
          destinations: [String.t()],
          lenses: [String.t()],
          result_type: result_type(),
          entity_types: [String.t()],
          edge_types: [String.t()],
          artefact_id: String.t() | nil,
          max_results: pos_integer()
        }
end
