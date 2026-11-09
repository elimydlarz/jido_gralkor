defmodule Gralkor.Search do
  @moduledoc """
  One search across registered memory Destinations.

  A search names the operator, the query, and optionally the Destinations to
  read (`destinations`, default every accessible registered Destination), the
  writers whose memory to read (`writers`, default every writer) or to leave
  out (`excluded_writers`, default none), and ontology filters (`entity_types`,
  `edge_types`, default no filter). The packaged `personal` Destination
  resolves only to the current `operator_id`'s graph.

  Every search returns everything relevant: one Graphiti search per selected
  Destination ranks that Destination's facts, nodes, and episodes together.
  `Gralkor.Client.search/1,2` returns one result per Destination in selected
  order:

      %{destination: name, facts: [fact], nodes: [node], episodes: [episode]}

  Each kind keeps Graphiti's relevance order and is capped per Destination by
  `limits/0`: fifty facts, twenty nodes, and fifteen episodes.

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
  episodes. Use `JidoGralkor.MemorySearchPresentation.sections/1` explicitly
  for readable presentation.

  ## Writers

  Every episode is written by exactly one writer, every fact is produced by
  the writers of every episode it was drawn from, and every entity by the
  writers of every episode that mentions it. A writer is named as:

  * `"lens:<name>"` — the Lens of that name;
  * `"reflection:<name>"` — the Reflection of that name, whose output is stored
    in memory;
  * `"direct"` — direct capture and direct memory addition;
  * `"unknown"` — memory whose writer could not be determined;
  * `"lens:*"` — every Lens;
  * `"reflection:*"` — every Reflection.

  Writers neither add nor narrow Destinations: every selected Destination is
  still searched.

  `writers` keeps only what an included writer produced: episodes it wrote,
  facts drawn from such an episode (each fact's `sources` keep only included
  writers' episodes), and entities such an episode mentions.

  `excluded_writers` leaves out episodes an excluded writer wrote, and facts
  and entities produced only by excluded writers; a fact or entity another
  writer also produced stays, and fact `sources` omit excluded writers'
  episodes. Supplied together, a result is returned only when an included
  writer produced it and a writer that is not excluded produced it.

  On Graphiti every writer restriction is decided from the writers recorded on
  each episode, fact, and entity, inside the graph queries before ranking and
  the per-Destination limits, so other writers cannot crowd a writer's results
  out and a filtered search takes about as long as an unfiltered one. Memory
  written before writers were recorded is given its writers, from its
  episodes' provenance, the first time its Destination is used.

  Each writer must be `"direct"`, `"unknown"`, `"lens:*"`, `"reflection:*"`,
  `"lens:"` naming a registered Lens, or `"reflection:"` with a non-blank name;
  anything else raises `ArgumentError`, naming whether it was included or
  excluded and the value, before any Destination is searched.

  ## Removed fields

  `result_type`, `artefact_id`, and `max_results` (removed in 12.0.0) and
  `lenses`, `excluded_lenses`, and `limits` (removed in 17.0.0) remain struct
  keys only so that supplying one fails loudly: `Gralkor.Client.search/1,2`
  raises `ArgumentError` with migration guidance when any of them is set.
  """

  @limits %{facts: 50, nodes: 20, episodes: 15}

  @removed_fields %{
    result_type: "12.0.0",
    artefact_id: "12.0.0",
    max_results: "12.0.0",
    lenses: "17.0.0",
    excluded_lenses: "17.0.0",
    limits: "17.0.0"
  }

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
    writers: [],
    excluded_writers: [],
    entity_types: [],
    edge_types: [],
    result_type: nil,
    artefact_id: nil,
    max_results: nil,
    lenses: nil,
    excluded_lenses: nil,
    limits: nil
  ]

  @typedoc """
  One search request. Empty `destinations` means every accessible registered
  Destination; empty `writers` means every writer; empty `excluded_writers`
  means nothing is excluded; empty `entity_types` and `edge_types` mean no
  filter. The removed keys must stay `nil`.
  """
  @type t :: %__MODULE__{
          operator_id: String.t(),
          query: String.t(),
          destinations: [String.t()],
          writers: [String.t()],
          excluded_writers: [String.t()],
          entity_types: [String.t()],
          edge_types: [String.t()],
          result_type: nil,
          artefact_id: nil,
          max_results: nil,
          lenses: nil,
          excluded_lenses: nil,
          limits: nil
        }

  @typedoc "The most facts, nodes, and episodes one Destination returns."
  @type limits :: %{facts: pos_integer(), nodes: pos_integer(), episodes: pos_integer()}

  @doc "The per-Destination result limits: fifty facts, twenty nodes, fifteen episodes."
  @spec limits() :: limits()
  def limits, do: @limits

  @doc false
  def removed_fields, do: @removed_fields

  @doc false
  @spec admitted?([String.t()], [String.t()], [String.t()]) :: boolean()
  def admitted?(produced_by, included, excluded) do
    (included == [] or Enum.any?(produced_by, &named?(&1, included))) and
      (excluded == [] or Enum.any?(produced_by, &(not named?(&1, excluded))))
  end

  defp named?(writer, selectors) do
    Enum.any?(selectors, fn
      "lens:*" -> String.starts_with?(writer, "lens:")
      "reflection:*" -> String.starts_with?(writer, "reflection:")
      selector -> selector == writer
    end)
  end
end
