defmodule Gralkor.Search do
  @moduledoc """
  One search across registered memory Destinations.

  A search names the operator, the query, and optionally the Destinations to
  read (`destinations`, default every accessible registered Destination), the
  Lenses whose writes to read (`lenses`, default every writer), and ontology
  filters (`entity_types`, `edge_types`, default no filter). The packaged
  `personal` Destination resolves only to the current `operator_id`'s graph.

  Every search returns everything relevant: one Graphiti search per selected
  Destination ranks that Destination's facts, nodes, and episodes together.
  `Gralkor.Client.search/1,2` returns one result per Destination in selected
  order:

      %{destination: name, facts: [fact], nodes: [node], episodes: [episode]}

  Each kind keeps Graphiti's relevance order and is capped per Destination by
  `limits/0`: twenty facts, twenty nodes, and five episodes (episodes are whole
  source documents, so fewer are returned).

  * A fact carries `fact`, its `created_at`, `valid_at`, `invalid_at`, and
    `expired_at` timestamps, its `relationship` name, its `source_node` and
    `target_node` as `%{uuid:, name:}`, and `sources`: originating episodes with
    `id`, `source_kind`, `source_description`, and named `lens` or `reflection`
    provenance (or `writer: :direct`) where known.
  * A node carries `name`, `summary`, and `attributes`.
  * A direct episode carries `content`, `source_description`, `source_kind`, and
    `writer: :direct`; a Lens episode carries `content`, `source_description`,
    and `lens`; a Reflection episode carries `artefact: %{id:, payload:}`,
    `source_description`, and its writer as `reflection`. Historical unmarked
    episodes remain available without invented authorship, and naturally
    textual Lens content remains text. A Reflection episode appears only once
    its extraction has durably completed.

  `entity_types` restricts nodes to those labels and restricts facts to edges
  whose source and target entities both carry one of them. `edge_types`
  restricts facts to those relationship names. Neither filter restricts
  episodes. Use `Gralkor.Format.format_fact/1` explicitly for readable fact
  presentation.

  ## Lens selection

  `lenses` names registered Lenses (ORed). It neither adds nor narrows
  Destinations: every selected Destination is still searched, and each returns
  only what the selected Lenses wrote there:

  * episodes whose writer is a selected Lens;
  * facts drawn from such an episode, or written by a selected replaceable
    Lens's graph replacement; each fact's `sources` keep only selected-Lens
    episodes;
  * nodes mentioned by such an episode, or owned by a selected Lens's graph
    replacement.

  Direct writes, other Lenses, and Reflection artefacts never contribute. On
  Graphiti every restriction is applied inside the graph queries, before
  ranking and the per-Destination limits, so other writers cannot crowd a
  Lens's results out. `entity_types` and `edge_types` restrict the Lens's
  results further. An unknown, blank, or non-list Lens selection raises
  `ArgumentError` before any Destination is searched.

  ## Removed in 12.0.0

  `result_type`, `artefact_id`, and `max_results` remain struct keys only so
  that supplying one fails loudly: `Gralkor.Client.search/1,2` raises
  `ArgumentError` with migration guidance when any of them is set. (`lenses`,
  removed in 12.0.0, returned in 13.0.0.)
  """

  @limits %{facts: 20, nodes: 20, episodes: 5}

  @removed_fields [:result_type, :artefact_id, :max_results]

  @type fact :: %{
          required(:fact) => String.t(),
          required(:relationship) => String.t() | nil,
          required(:source_node) => %{uuid: String.t(), name: String.t() | nil} | nil,
          required(:target_node) => %{uuid: String.t(), name: String.t() | nil} | nil,
          optional(:sources) => [map()],
          optional(atom()) => term()
        }
  @type direct_episode :: %{
          required(:content) => String.t(),
          required(:source_description) => String.t(),
          optional(:source_kind) => String.t(),
          optional(:writer) => :direct
        }
  @type lens_episode :: %{content: String.t(), source_description: String.t(), lens: String.t()}
  @type reflection_episode :: %{
          artefact: %{id: String.t(), payload: map()},
          source_description: String.t(),
          reflection: String.t()
        }
  @type episode :: direct_episode() | lens_episode() | reflection_episode()
  @type result :: %{
          destination: String.t(),
          facts: [fact()],
          nodes: [map()],
          episodes: [episode()]
        }

  @enforce_keys [:operator_id, :query]
  defstruct [
    :operator_id,
    :query,
    destinations: [],
    lenses: [],
    entity_types: [],
    edge_types: [],
    result_type: nil,
    artefact_id: nil,
    max_results: nil
  ]

  @typedoc """
  One search request. Empty `destinations` means every accessible registered
  Destination; empty `lenses` means every writer; empty `entity_types` and
  `edge_types` mean no filter. The removed keys must stay `nil`.
  """
  @type t :: %__MODULE__{
          operator_id: String.t(),
          query: String.t(),
          destinations: [String.t()],
          lenses: [String.t()],
          entity_types: [String.t()],
          edge_types: [String.t()],
          result_type: nil,
          artefact_id: nil,
          max_results: nil
        }

  @doc "The fixed per-Destination result limits: twenty facts, twenty nodes, five episodes."
  @spec limits() :: %{facts: pos_integer(), nodes: pos_integer(), episodes: pos_integer()}
  def limits, do: @limits

  @doc false
  def removed_fields, do: @removed_fields
end
