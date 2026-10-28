# Destinations

A Destination is one logically named graph:

```elixir
%Gralkor.Destination{name: "global"}
```

Lenses and Reflection Destination outputs reference registered Destinations by name. Multiple writers may save information to the same graph.

## Graph identity

The package registers two Destinations:

- `global` is the single shared global graph. Its logical graph ID is exactly `global` for every operator.
- `personal` is private to one operator. Its logical graph ID is `personal/<same operator id>`.

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
      write: :append,
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

The packaged `personal-chat` Lens writes with `Gralkor.DefaultOntology`. The packaged generalisation Reflection has a `global` Destination output with `Gralkor.DefaultOntology`; packaged ERL has a `personal` Destination output with `Gralkor.Reflection.ERLOntology`.

Direct capture uses the built-in ontology without Lens authorship. `personal-chat` runs only when explicitly selected and uses the existing Store ingestion process for every supported source kind. Storage marks new direct writes with a terminal ` [gralkor: direct]` marker, then removes that marker from the public source description. User descriptions cannot override the actual writer. Lens and Reflection names reserve both writer delimiters.

Historical ` [lens: operator]` provenance stays intact, and older unmarked episodes remain readable without invented authorship. Destination-only or selector-free search includes these records; a `personal-chat` Lens filter does not relabel or include them. Incomplete Reflection artefacts still require their durable completion marker.

The retired `operator` Destination never falls through to shared-name resolution. Moving `operator/<identifier>` to `personal/<same identifier>` requires the [explicit graph migration](PERSONAL_MEMORY_MIGRATION.md), which preserves stored history and changes physical and stored group identities together. Current public configuration rejects retired names; archival consumer routing must translate separately from immutable snapshots and hashes.

## Replaceable Lenses

A replaceable Lens replaces only graph content previously written by that Lens. It does not clear or replace its Destination.

The private `_gralkor_lens` ownership field identifies graph content written by a replaceable Lens. Replacing Lens `A` removes content carrying `_gralkor_lens: "A"`, then inserts the new graph carrying the same marker. It is separate from the source-description provenance used for episode writers.

Information saved through other Lenses, information saved through Reflection outputs, and information without Lens `A`'s ownership marker remain unchanged.

## Search

Search reads registered Destinations and returns everything relevant in one call. With only a query it searches every accessible registered Destination:

```elixir
Gralkor.Client.search(agent_server, %Gralkor.Search{
  operator_id: operator_id,
  query: "What should I remember?"
})
```

That includes the packaged `personal` and `global` Destinations and every application Destination. Only the current operator's logical `personal/<operator id>` graph is searched; other registered Destinations retain their shared logical graph identity.

`%Gralkor.Search{}` has exactly three optional fields besides `operator_id` and `query`:

```elixir
Gralkor.Client.search(agent_server, %Gralkor.Search{
  operator_id: operator_id,
  query: "what changed the parser",
  destinations: ["code"],                  # default: every accessible registered Destination
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

### Facts

A fact record contains its `fact` text, `created_at`, `valid_at`, `invalid_at`, `expired_at`, the edge's `relationship` name, its `source_node` and `target_node` as `%{uuid:, name:}` (so a consumer can render "Commit X CHANGES Function Y"), and `sources`. Each source retains `id`, `source_kind`, and `source_description`, plus `lens`, `reflection`, or `writer: :direct` when its writer is identifiable. Lens and Reflection source descriptions retain their stored provenance markers. Direct source descriptions return the original caller text with the storage-owned terminal marker removed. Missing timestamps remain `nil`. In-memory storage is a deterministic test backend: it wraps stored episode text as a fact record with Lens and source-description attribution rather than performing extraction, so its `relationship`, `source_node`, and `target_node` are `nil`.

### Episodes

Episodes identify their writer where provenance is recorded; historical unmarked episodes remain unattributed. Appending Lens episodes suffix their source description with ` [lens: <Lens name>]`; Reflection episodes use the exact source description `reflection:<Reflection name>`. Lens and Reflection names containing the Lens delimiter are rejected so attribution stays unambiguous. A Lens-written episode:

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

`Gralkor.Client.search/1,2` never applies model presentation or budgeting. Readable fact presentation is separate: call `Gralkor.Format.format_fact(record)` explicitly. Legacy `recall` still uses that operation to construct its readable memory block.

### Readable memory search

`memory_search` takes a query and an optional `destinations` list, runs the one search, and returns one readable string in `{:ok, %{result: text}}`:

```text
Facts

Lens: jira
- Payment retries must use an idempotency key.

Reflection: generalisations
- Prefer small, reversible deployments with monitoring.

Entities
- settlement worker: Retries failed requests three times. (team: payments)

Episodes
- [Lens: jira] PAY-142: settlement retries double-charged a customer when the… (truncated)
- [Reflection: generalisations] artefact 7f3c…: {"generalisations":[{"content":"Prefer small, reversible… (truncated)
```

Facts from every Destination come first, grouped under source headings in first-appearance order with retrieval order within each group; a fact with several named sources appears once under each distinct source. Known direct sources appear under `Source: direct conversation`, `Source: direct document`, or `Source: direct structured record`, a direct source without a recorded kind under `Source: direct`, and unattributable facts under `Source: unknown`. Entities follow in full (name, summary, attributes). Episodes are compact so whole source documents never flood the agent's context: a writer label and an excerpt of at most 280 characters, a Reflection episode summarised by its artefact identifier and a payload excerpt. A section with nothing to show is left out; an empty search produces `No matching memory.`

`JidoGralkor.MemorySearchPresentation.for_model(results, max_bytes)` is the explicit reusable formatter. It leaves the input unchanged and returns `{:ok, %{result: text}}`. Consumers can call the structured search API and choose their own formatter instead.

The action uses `tool_context[:memory_search_max_bytes]`, defaulting to 65,536 UTF-8 bytes for the complete serialized Jido success envelope. Independently, the entire text, including headings and notices, fits within 16,384 characters. These limits retain or omit complete bullets; later fitting bullets remain eligible. When bullets are omitted, the text ends with `Omitted (response limit): facts N, entities M, episodes K.` Each fact counts once regardless of how many source groups it would occupy. This is a response budget, not pagination.

If the byte budget cannot hold the required response notice, the formatter returns `{:error, {:memory_search_budget_too_small, %{max_bytes: limit, minimum_bytes: required}}}`. A non-positive or non-integer budget raises before search starts. The blank-query short circuit remains an explicit textual NON-RESULT, and errors remain `{:error, reason}`.

### Migrating from 11.x search

- `result_type` is gone: every search returns facts, nodes, and episodes per Destination. Replace `result.fact` / `result.node` / `result.episode` (one flat attributed list) with `result.facts` / `result.nodes` / `result.episodes` inside each Destination map.
- `lenses` is gone as a search selector: read each episode's `lens` or each fact source's `lens` to tell writers apart.
- `result_type: :artefacts` and `artefact_id` are gone: Reflection artefacts arrive whole in `episodes` as `artefact: %{id:, payload:}`; match the id there.
- `max_results` is gone: limits are fixed per Destination (`Gralkor.Search.limits/0`).
- Setting any removed field raises `ArgumentError` naming the field with this guidance.
- `memory_search` lost its `lenses` parameter; keep `destinations`. Treat `action_result.result` as readable text; never `Jason.decode!/1` it.

Jido AI 2.3.0 serializes the small action envelope containing the readable string. One decode of a model tool message yields `%{"ok" => true, "result" => %{"result" => text}}`. The formatter keeps that text below the released sanitizer's string limit, so nested payload depth, collection sizes, and domain-key redaction do not affect the presentation. No framework patch or fork is required.
