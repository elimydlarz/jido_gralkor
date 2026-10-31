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

`%Gralkor.Search{}` has exactly four optional fields besides `operator_id` and `query`:

```elixir
Gralkor.Client.search(agent_server, %Gralkor.Search{
  operator_id: operator_id,
  query: "what changed the parser",
  destinations: ["code"],                  # default: every accessible registered Destination
  lenses: ["commits"],                     # default: every writer
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

`Gralkor.Client.search/1,2` never applies model presentation or budgeting. Readable presentation is separate: call `JidoGralkor.MemorySearchPresentation.for_model/2` explicitly. `memory_search` and legacy `recall` both use it.

### Readable memory search

`memory_search` and `recall` present memory the same way. For example:

```text
Reflection: generalisations
- Prefer small, reversible changes to Payments migrations.

Reflection: erl
- approach: moved Vacuum to 04:00; lesson: Keep the jobs apart; success: true

Lens: jira
- Payment retries must use an idempotency key.
- Settlement retried failed requests twice. (invalidated at 2026-10-12)
- PAY-142: settlement retries double-charged a customer when the worker restarted.

Source: direct conversation
- user: Can we move the cutover? assistant: Sunday works.

Entities
- settlement worker: Retries failed requests three times.

3 more memories omitted (response limit).
```

Every memory is one line of plain text under the heading of whoever wrote it: `Lens: <name>`, `Reflection: <name>`, `Source: direct conversation`, `Source: direct document`, `Source: direct structured record`, `Source: direct` for a direct source without a recorded kind, or `Source: unknown`. A fact with several named sources appears under each distinct source, and the same text appears once under one heading. Entities have no single writer, so they come last under `Entities` with their name, summary, and attributes. An empty search produces `No matching memory.`

Whole Reflection artefacts come first, then facts, then episodes. That order sets both the heading order and which memories survive the response limits.

Reflection artefacts and structured-record episodes become readable text without any Reflection-specific code. An object with a `content` string shows only that text, which keeps `level` and `evolves_from` out of generalisations; an object with one field shows that field's value; any other object shows `key: value` pairs separated by semicolons; and each item of a top-level list is its own bullet.

A fact with an invalidation date, or failing that an expiry date, ends with `(invalidated at <date>)`. Any memory is cut only past 4,000 characters, and is then marked `… (truncated)`.

`JidoGralkor.MemorySearchPresentation.for_model(results, max_bytes)` is the explicit reusable formatter. It leaves the input unchanged and returns `{:ok, %{result: text}}`. Consumers can call the structured search API and choose their own formatter instead.

The action uses `tool_context[:memory_search_max_bytes]`, defaulting to 65,536 UTF-8 bytes for the complete serialized Jido success envelope. Independently, the entire text, including headings and notices, fits within 16,384 characters. These limits retain or omit whole memories; later fitting memories remain eligible. When memories are omitted, the text ends with `N more memories omitted (response limit).` Each fact counts once regardless of how many headings it would occupy. This is a response budget, not pagination.

If the byte budget cannot hold the required response notice, the formatter returns `{:error, {:memory_search_budget_too_small, %{max_bytes: limit, minimum_bytes: required}}}`. A non-positive or non-integer budget raises before search starts. The blank-query short circuit remains an explicit textual NON-RESULT, and errors remain `{:error, reason}`.

### Migrating from 11.x search

- `result_type` is gone: every search returns facts, nodes, and episodes per Destination. Replace `result.fact` / `result.node` / `result.episode` (one flat attributed list) with `result.facts` / `result.nodes` / `result.episodes` inside each Destination map.
- `lenses` was removed in 12.0.0 and returned in 13.0.0 with the same meaning: only what the selected Lenses wrote, filtered before ranking. It now restricts facts, nodes, and episodes together.
- `result_type: :artefacts` and `artefact_id` are gone: Reflection artefacts arrive whole in `episodes` as `artefact: %{id:, payload:}`; match the id there.
- `max_results` is gone: limits are fixed per Destination (`Gralkor.Search.limits/0`).
- Setting any removed field raises `ArgumentError` naming the field with this guidance.
- `memory_search` lost its `lenses` parameter; keep `destinations`. Treat `action_result.result` as readable text; never `Jason.decode!/1` it.

Jido AI 2.3.0 serializes the small action envelope containing the readable string. One decode of a model tool message yields `%{"ok" => true, "result" => %{"result" => text}}`. The formatter keeps that text below the released sanitizer's string limit, so nested payload depth, collection sizes, and domain-key redaction do not affect the presentation. No framework patch or fork is required.
