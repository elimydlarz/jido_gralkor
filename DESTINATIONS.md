# Destinations

A Destination is one logically named graph:

```elixir
%Gralkor.Destination{name: "global"}
```

Lenses and Reflection Destination outputs reference registered Destinations by name. Multiple writers may save information to the same graph.

## Graph identity

The package registers three Destinations:

- `global` is the single shared global graph. Its logical graph ID is exactly `global` for every operator.
- `personal` is private to one operator. Its logical graph ID is `personal/<same operator id>`.
- `generalisations` is the shared graph the packaged generalisation Reflection writes to and reads its prior generalisations from. Its logical graph ID is exactly `generalisations` for every operator.

An application cannot register a Destination named `personal`, `global`, or `generalisations`; configuration naming one is rejected rather than replacing the packaged Destination. Only the packaged generalisation Reflection writes to `generalisations`: a consumer Lens, a consumer Reflection Destination output, or a plugin `capture_destination` naming it is rejected (`{:exclusive_destination, collection, name, "generalisations"}` in runtime configuration). Every operator reads it through any search that includes it, including selector-free search.

An agent may register another Destination with only a name in its complete runtime configuration:

```elixir
runtime_config = %{
  destinations: [%{name: "product-knowledge"}],
  lenses: [],
  reflections: []
}
```

Its logical graph ID is exactly `product-knowledge`, shared by every operator. There is no address or scope syntax: `global/x` is just another literal Destination name, not part of the `global` graph. Names beginning `personal/` or `operator/` are reserved for private or retired logical IDs and cannot be registered as application Destinations.

At the Graphiti boundary, Gralkor encodes each logical ID exactly once as `g_` followed by the lowercase hexadecimal encoding of every original byte. This replaces the former lossy `-` and `/` to `_` normalisation, so old physical graphs are not discovered or migrated automatically. Migrate only from known logical IDs, or re-ingest the source content; an underscore cannot reveal which original logical ID produced it.

Most shared application memory should target the packaged `global` Destination. Register another Destination only when the application needs a separate graph.

## Ontologies belong to writers

Destinations do not own extraction ontologies. Each appending Lens and Reflection Destination output selects the ontology for the information it writes, defaulting to `Gralkor.DefaultOntology`:

```elixir
runtime_config = %{
  destinations: [],
  lenses: [
    %{
      name: "support-cases",
      destination: "global",
      ontology: MyApp.SupportOntology,
      ingestion: MyApp.SupportIngestion
    }
  ],
  reflections: [
    %{
      name: "release-review",
      outputs: [
        %{
          kind: :destination,
          destination: "global",
          ontology: MyApp.ReleaseOntology
        }
      ],
      chain_of_thought: %{
        steps: [
          %{
            label: "review",
            directions: "Review the supplied release evidence.",
            output: %{"assessment" => "string"}
          }
        ]
      }
    }
  ]
}
```

The packaged `personal-chat` Lens writes with `Gralkor.DefaultOntology`. The packaged generalisation Reflection has a `generalisations` Destination output with `Gralkor.DefaultOntology`; packaged ERL has a `personal` Destination output with `Gralkor.Reflection.ERLOntology`.

Direct capture uses the built-in ontology without Lens authorship. `personal-chat` runs only when explicitly selected and uses the existing Store ingestion process for every supported source kind. Storage marks new direct writes with a terminal ` [gralkor: direct]` marker, then removes that marker from the public source description. User descriptions cannot override the actual writer. Lens and Reflection names reserve both writer delimiters.

Historical ` [lens: operator]` provenance stays intact, and older unmarked episodes remain readable without invented authorship. Destination-only or selector-free search includes these records; a `personal-chat` Lens filter does not relabel or include them. Incomplete Reflection artefacts still require their durable completion marker.

The retired `operator` Destination never falls through to shared-name resolution. Moving `operator/<identifier>` to `personal/<same identifier>` requires the [explicit graph migration](PERSONAL_MEMORY_MIGRATION.md), which preserves stored history and changes physical and stored group identities together. Current public configuration rejects retired names; archival consumer routing must translate separately from immutable snapshots and hashes.

## Search

Search reads registered Destinations and returns everything relevant in one call. With only a query it searches every accessible registered Destination:

```elixir
Gralkor.Client.search(agent_server, %Gralkor.Search{
  operator_id: operator_id,
  query: "What should I remember?"
})
```

That includes the packaged `personal`, `global`, and `generalisations` Destinations and every application Destination. Only the current operator's logical `personal/<operator id>` graph is searched; other registered Destinations retain their shared logical graph identity.

`%Gralkor.Search{}` has exactly five optional fields besides `operator_id` and `query`:

```elixir
Gralkor.Client.search(agent_server, %Gralkor.Search{
  operator_id: operator_id,
  query: "what changed the parser",
  destinations: ["code"],                  # default: every accessible registered Destination
  lenses: ["commits"],                     # default: every writer
  # excluded_lenses: ["commits"],          # default: none; cannot be combined with lenses
  entity_types: ["Commit", "Function"],    # default: no filter
  edge_types: ["CHANGES"]                  # default: no filter
})
```

Each distinct Destination is searched once, concurrently, through one Graphiti `search_` call that ranks edges, nodes, and episodes together (Graphiti's `COMBINED_HYBRID_SEARCH_RRF` recipe without its community layer: edges and nodes by BM25 plus cosine similarity with reciprocal rank fusion, episodes by BM25; the query is embedded once). The result is one map per Destination, in selected order:

```elixir
{:ok,
 [
   %{
     destination: "code",
     facts: [
       %{
         fact: "Commit 1a2b changes parse/1",
         relationship: "CHANGES",
         source_node: %{uuid: "...", name: "Commit 1a2b"},
         target_node: %{uuid: "...", name: "parse/1"},
         created_at: "...", valid_at: "...", invalid_at: nil, expired_at: nil,
         sources: [%{id: "...", source_kind: "document", source_description: "git log [lens: commits]", lens: "commits"}]
       }
     ],
     nodes: [%{name: "parse/1", summary: "...", attributes: %{"arity" => "1"}}],
     episodes: [%{content: "...", source_description: "git log", lens: "commits"}]
   }
 ]}
```

Facts, nodes, and episodes each keep Graphiti's relevance order. Every Destination contributes at most twenty facts, twenty nodes, and five episodes (`Gralkor.Search.limits/0`); episodes are whole source documents, so fewer are returned. `entity_types` restricts nodes to those labels and restricts facts to edges whose source *and* target entities both carry one of them (Graphiti applies its label filter to both edge endpoints). `edge_types` restricts facts to those relationship names. Neither filter restricts episodes.

### Lens selection

`lenses` names registered Lenses (ORed) and narrows what each selected Destination returns to what those Lenses wrote there; it never adds or removes Destinations, so a Lens selector without `destinations` still searches every accessible registered Destination. Within each Destination:

- episodes: only those whose source description ends with a selected Lens's ` [lens: <name>]` marker (a durable direct write never matches);
- facts: only edges drawn from such an episode; each fact's `sources` keep only selected-Lens episodes;
- nodes: only entities mentioned (`MENTIONS`) by such an episode.

Direct writes, other Lenses, Reflection artefacts, and historical `operator`-labelled episodes never contribute (the retired `operator` Lens cannot be selected). `entity_types` and `edge_types` restrict the Lens's results further. On FalkorDB every restriction is part of the graph queries, applied before ranking and the per-Destination caps, so other writers cannot consume a Lens's twenty facts, twenty nodes, or five episodes: facts through graphiti-core's `SearchFilters.edge_uuids`; nodes and episodes through filters Gralkor adds to graphiti-core 0.31.2's node searches and FalkorDB episode full-text query, which have none of their own. A Lens that has written nothing to a Destination returns empty facts, nodes, and episodes there without a Graphiti search. An unknown, blank, or non-list Lens selection raises `ArgumentError` before any Destination is searched; runtime-targeted search resolves Lens names from the agent's runtime snapshot.

### Lens exclusion

`excluded_lenses` names registered Lenses whose writes to leave out while keeping everything else. Like `lenses`, it never adds or removes Destinations: every selected Destination is still searched, including each excluded Lens's own. Within each Destination:

- episodes: those whose source description ends with an excluded Lens's ` [lens: <name>]` marker are left out;
- facts: an edge is left out only when every episode it was drawn from is such an episode; an edge another writer's episode also produced stays, and its `sources` omit the excluded episodes;
- nodes: an entity is left out only when every episode mentioning it is such an episode; an entity another writer's episode also mentions stays, so cross-source relationships survive.

Direct writes and capture, other Lenses, Reflection artefacts, and historical unmarked episodes all remain. On FalkorDB the exclusions are `NOT … IN` filters inside the same graph queries, applied before ranking and the per-Destination caps, so an excluded Lens's volume cannot take any of the twenty facts, twenty nodes, or five episodes. `entity_types` and `edge_types` restrict what remains. Supplying both `lenses` and `excluded_lenses` raises `ArgumentError` before any Destination is searched: a selection already leaves out every other writer. An unknown, blank, or non-list exclusion raises `ArgumentError` naming the excluded Lens; runtime-targeted search resolves excluded names from the agent's runtime snapshot.

```elixir
# General recall without the high-volume commit history the "code-changes" Lens writes to global.
Gralkor.Client.search(agent_server, %Gralkor.Search{
  operator_id: operator_id,
  query: "who owns the settlement worker",
  excluded_lenses: ["code-changes"]
})
```

### Facts

A fact record contains its `fact` text, `created_at`, `valid_at`, `invalid_at`, `expired_at`, the edge's `relationship` name, its `source_node` and `target_node` as `%{uuid:, name:}` (so a consumer can render "Commit X CHANGES Function Y"), and `sources`. Each source retains `id`, `source_kind`, and `source_description`, plus `lens`, `reflection`, or `writer: :direct` when its writer is identifiable. Lens and Reflection source descriptions retain their stored provenance markers. Direct source descriptions return the original caller text with the storage-owned terminal marker removed. Missing timestamps remain `nil`. In-memory storage is a deterministic test backend: it wraps stored episode text as a fact record with Lens and source-description attribution rather than performing extraction, so its `relationship`, `source_node`, and `target_node` are `nil`.

### Episodes

Episodes identify their writer where provenance is recorded; historical unmarked episodes remain unattributed. Lens episodes suffix their source description with ` [lens: <Lens name>]`; Reflection episodes use the exact source description `reflection:<Reflection name>`. Lens and Reflection names containing the Lens delimiter are rejected so attribution stays unambiguous. A Lens-written episode:

```elixir
%{content: "...", source_description: "support transcript", lens: "support-cases"}
```

A Reflection-written episode carries its whole artefact as structured fields instead of `content`:

```elixir
%{
  reflection: "generalisations",
  source_description: "reflection:generalisations",
  artefact: %{
    id: "<stable artefact UUID>",
    payload: %{
      "generalisations" => [
        %{"content" => "Use reversible rollouts", "level" => 1, "evolves_from" => []}
      ]
    }
  }
}
```

A Reflection episode appears only once its extraction has durably completed. Reflection payload keys and values retain their stored shape; Graphiti JSON object keys are strings. Only Reflection-provenanced episode bodies are decoded. Lens-authored documents, Jira records, and even text that happens to look like an artefact remain text in `content`. A malformed completed Reflection body returns `{:error, {:invalid_reflection_artefact, reflection_name}}`; search does not return a manufactured partial response. Private graph identities still require the explicit namespace migration described above.

`Gralkor.Client.search/1,2` never applies model presentation or budgeting. Readable presentation is separate: call `JidoGralkor.MemorySearchPresentation.sections/1` explicitly. `memory_search`, legacy `recall`, and the packaged generalisation Reflection's built-in inference prompt all use it; a consumer `:inference` function still receives the structured results.

### Readable memory search

`memory_search` returns memory as sections, one string each; `recall` and the generalisation prompt join the same sections into one text. For example:

```text
Lens: jira
- Payment retries must use an idempotency key. (valid from 2026-10-30; source: PAY-142)
- Settlement retried failed requests twice. (valid from 2026-10-02 to 2026-10-12; source: incident review)
- PAY-142: settlement retries double-charged a customer when the worker restarted. (valid from 2026-10-30; source: PAY-142)

Reflection: generalisations
- Prefer small, reversible changes to Payments migrations. (valid from 2026-10-29)
  level: 2
  evolves_from:
  - Prefer reversible changes to Payments schema migrations.
    level: 1

Reflection: erl
- approach: moved Vacuum to 04:00 (valid from 2026-10-27)
  lesson: Keep the jobs apart
  success: true

Source: direct conversation
- user: Can we move the cutover? assistant: Sunday works. (valid from 2026-10-31; source: planning call)

Entities in global memory
- settlement worker: Retries failed requests three times.
```

Every memory is one bullet under the heading of whoever wrote it: `Lens: <name>`, `Reflection: <name>`, `Source: direct conversation`, `Source: direct document`, `Source: direct structured record`, `Source: direct` for a direct source without a recorded kind, or `Source: unknown`. A fact with several named sources appears under each distinct source, and the same text appears once under one heading; a memory that is only another memory's first line under that heading, such as the fact extracted from a generalisation, is left out beside it. Entities have no single writer, so they follow every writer section in one `Entities in <Destination> memory` section for each Destination that returned entities: the first line is `name: summary`, or only the name, and each attribute follows on its own indented `key: value` line. An empty search produces one `Memory` section saying `No matching memory.`

`Lens:` sections come first, then `Reflection:`, then `Source:`, each kind in first-appearance order. Inside a section, whole Reflection artefacts come first, then facts, then episodes.

Reflection artefacts and structured-record episodes become readable text without any Reflection-specific code, and keep every field they carry. A payload object with exactly one key, such as `generalisations`, is presented as that key's value, once and only at the outer level, and each item of a top-level list is its own bullet. A bullet's first line is an object's `content` string, or else its first field in alphabetical order as `key: value`. Every other field follows on its own line, two spaces further in: fields that fit on one line (a plain value, or a comma-separated list of plain values) first, in alphabetical order, then nested fields in alphabetical order. A list containing an object becomes `key:` followed by one nested bullet per item, laid out the same way, and a nested object becomes `key:` followed by its own fields. Null, empty strings, empty lists, empty objects, and fields containing only those are left out. Record metadata such as uuids, artefact identifiers, and Destinations never appears. The lineage in `evolves_from` repeats each earlier generalisation's text; the formatter presents what the payload carries.

The first line of a fact or episode ends with when it was true and where it came from: `(valid from <date>)`, or `(valid from <date> to <date>)` once it was invalidated or expired, then `; source: <description>`. The start is when it became true, or when it was recorded if that is missing, and an invalidated fact with no start shows `(valid until <date>)`. A fact drawn from several episodes lists each distinct source description once. A source description never repeats its Lens marker, and one that only names a Reflection is left out because the heading already says so. Any memory is cut only past 4,000 characters, counting all of its lines with their indentation, and `… (truncated)` then ends the last line kept; the dates and source still follow on the first line and do not count toward the cut.

`JidoGralkor.MemorySearchPresentation.sections(results)` is the explicit reusable formatter. It leaves the input unchanged and returns `[%{heading:, text:}]`; `text(sections)` joins them, each heading over its text, separated by blank lines. The `memory_search` action returns `{:ok, %{sections: sections}}`. Consumers can call the structured search API and choose their own formatter instead.

Each section has its own character limit, and no limit applies across sections: a `Lens:` section's text stays within 12,000 characters, a `Reflection:` section's within 8,000, a `Source:` section's within 6,000, and an `Entities in … memory` section's within 4,000, so every section fits Jido AI's 16,384-character string limit. A section over its limit keeps its memories in order while they fit together with its omission notice, omits the rest whole (a later memory that still fits is kept), and ends with `N more memories omitted (section limit).` One section filling up never removes a memory from another. This is a per-section budget, not pagination. The blank-query short circuit remains an explicit textual NON-RESULT, and errors remain `{:error, reason}`.

### Migrating from 11.x search

- `result_type` is gone: every search returns facts, nodes, and episodes per Destination. Replace `result.fact` / `result.node` / `result.episode` (one flat attributed list) with `result.facts` / `result.nodes` / `result.episodes` inside each Destination map.
- `lenses` was removed in 12.0.0 and returned in 13.0.0 with the same meaning: only what the selected Lenses wrote, filtered before ranking. It now restricts facts, nodes, and episodes together.
- `result_type: :artefacts` and `artefact_id` are gone: Reflection artefacts arrive whole in `episodes` as `artefact: %{id:, payload:}`; match the id there.
- `max_results` is gone: limits are fixed per Destination (`Gralkor.Search.limits/0`).
- Setting any removed field raises `ArgumentError` naming the field with this guidance.
- `memory_search` lost its `lenses` parameter; keep `destinations`. Read `action_result.sections`, each `%{heading:, text:}`; treat each `text` as readable text and never `Jason.decode!/1` it.

Jido AI 2.3.0 serializes the small action envelope containing the sections. One decode of a model tool message yields `%{"ok" => true, "result" => %{"sections" => [%{"heading" => heading, "text" => text}]}}`. Every section's text stays below the released sanitizer's 16,384-character string limit, so nested payload depth, collection sizes, and domain-key redaction do not affect the presentation. No framework patch or fork is required.
