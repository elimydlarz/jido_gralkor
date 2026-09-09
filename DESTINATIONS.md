# Destinations

A Destination is one logically named graph:

```elixir
%Gralkor.Destination{name: "global"}
```

Lenses and Reflection Destination outputs reference registered Destinations by name. Multiple writers may save information to the same graph.

## Graph identity

The package registers two Destinations:

- `global` is the single shared global graph. Its logical graph ID is exactly `global` for every operator.
- `operator` is operator-local. Its logical graph ID is `operator/<operator id>`.

An agent may register another Destination with only a name in its complete runtime configuration:

```elixir
runtime_config = %{
  destinations: [%{name: "product-knowledge"}],
  lenses: [],
  reflections: []
}
```

Its logical graph ID is exactly `product-knowledge`, shared by every operator. There is no address or scope syntax: `global/x` is just another literal Destination name, not part of the `global` graph. Names beginning `operator/` are reserved for operator-local logical IDs and cannot be registered as application Destinations.

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

The packaged `operator` Lens writes with `Gralkor.DefaultOntology`. The packaged generalisation Reflection has a `global` Destination output with `Gralkor.DefaultOntology`; packaged ERL has an `operator` Destination output with `Gralkor.Reflection.ERLOntology`.

## Replaceable Lenses

A replaceable Lens replaces only graph content previously written by that Lens. It does not clear or replace its Destination.

The private `_gralkor_lens` ownership field identifies graph content written by a replaceable Lens. Replacing Lens `A` removes content carrying `_gralkor_lens: "A"`, then inserts the new graph carrying the same marker. It is separate from the source-description provenance used for episode writers.

Information saved through other Lenses, information saved through Reflection outputs, and information without Lens `A`'s ownership marker remain unchanged.

## Search

Search reads registered Destinations. With no selectors it searches every accessible registered Destination and returns relevant episodes:

```elixir
Gralkor.Client.search(agent_server, %Gralkor.Search{
  operator_id: operator_id,
  query: "What should I remember?"
})
```

That includes the packaged `operator` and `global` Destinations and every application Destination. Only the current operator's logical `operator/<operator id>` graph is searched; other registered Destinations retain their shared logical graph identity.

Callers may narrow the graphs with `destinations` and may narrow episode writers with `lenses`:

```elixir
Gralkor.Client.search(agent_server, %Gralkor.Search{
  operator_id: operator_id,
  query: "What should I remember?",
  destinations: ["operator", "global"],
  lenses: ["support-cases", "decisions"]
})
```

Names within each selector are alternatives: either Destination and either Lens may contribute. When both selectors are present, a result must satisfy both dimensions. A Lens selector filters writers within the selected Destination graphs; it is not a Destination alias. Lens filtering applies to episode and fact results. Fact searches restrict eligible edges before the result limit and retain only the selected Lens sources.

Each distinct Destination is searched once. Multiple Destinations are searched concurrently, their results retain requested Destination order, and every result identifies its Destination. Episode results also identify their writer. Appending Lens episodes suffix their source description with ` [lens: <Lens name>]`; Reflection episodes use the exact source description `reflection:<Reflection name>`. Lens and Reflection names containing the Lens delimiter are rejected so attribution stays unambiguous. A Lens-written result has this shape:

```elixir
%{
  destination: "global",
  episode: %{
    content: "...",
    source_description: "support transcript",
    lens: "support-cases"
  }
}
```

A Reflection-written result has structured artefact fields instead of `episode.content`:

```elixir
%{
  destination: "global",
  episode: %{
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
}
```

`Gralkor.Client.search/1,2` returns `{:ok, [result]}`; an empty search returns `[]`. The API does not apply model presentation or budgeting. `memory_search` explicitly requests facts and returns `{:ok, %{result: text}}`. The existing blank-query short circuit remains an explicit textual NON-RESULT in `result`, and errors remain `{:error, reason}`.

Reflection payload keys and values retain their stored shape; Graphiti JSON object keys are strings. Only Reflection-provenanced episode bodies are decoded. Lens-authored documents, Jira records, and even text that happens to look like an artefact remain text in `episode.content`. A malformed completed Reflection body returns `{:error, {:invalid_reflection_artefact, reflection_name}}`; search does not return a manufactured partial response. Stored Graphiti representation and completion filtering are unchanged, so existing valid completed artefacts need no storage migration.

Fact results have `%{destination: name, fact: record}`. The Graphiti record contains `fact` text, `created_at`, `valid_at`, `invalid_at`, `expired_at`, and `sources`; each source retains `id`, `source_kind`, and `source_description`, plus `lens` or `reflection` when its writer is identifiable. Fact source descriptions retain their stored provenance markers. Missing timestamps remain `nil`. In-memory storage is a deterministic test backend: it wraps stored episode text as a fact record with Lens and source-description attribution rather than performing extraction. Node results remain `%{destination: name, node: node_map}`; explicit artefact results remain `%{destination: name, artefact: %Gralkor.Artefact{id: id, payload: payload}}`.

Readable presentation is separate: call `Gralkor.Format.format_fact(record)` explicitly. Legacy `recall` still uses that operation to construct its readable memory block. `Gralkor.Client.search/1,2` never invokes readable fact formatting.

### Readable memory search

`memory_search` returns one readable string in `{:ok, %{result: text}}`:

```text
Lens: jira
- Payment retries must use an idempotency key.
- The settlement worker retries failed requests three times.

Reflection: generalisations
- Prefer small, reversible deployments with monitoring.
```

The bullets are Graphiti's returned fact text. Formatting adds no Destination labels, artefact identifiers, levels, or evolution-history metadata. Groups retain first-appearance order and facts retain retrieval order within each group. A fact with several named sources appears once under each distinct source; a Lens and Reflection with the same name have separate headings. Facts without named provenance appear under `Source: unknown`. An empty search produces `No matching facts.`

`JidoGralkor.MemorySearchPresentation.for_model(results, max_bytes)` is the explicit reusable formatter for structured fact results. It leaves the input unchanged and returns `{:ok, %{result: text}}`. Consumers can call the structured search API and choose their own formatter instead.

The action uses `tool_context[:memory_search_max_bytes]`, defaulting to 65,536 UTF-8 bytes for the complete serialized Jido success envelope. Independently, the entire text—including headings and notices—fits within 16,384 characters. These limits retain or omit complete facts; later fitting facts remain eligible. When facts are omitted, the text ends with `Omitted facts: N (response limit).` The count refers to input facts, regardless of how many source groups each would occupy. An individually oversized fact is omitted whole. This is a response budget, not pagination or a count of all matching memories.

If the byte budget cannot hold the required response notice, the formatter returns `{:error, {:memory_search_budget_too_small, %{max_bytes: limit, minimum_bytes: required}}}`. A non-positive or non-integer budget raises before search starts. The existing blank-query short circuit remains an explicit textual NON-RESULT.

### Consumer migration and model delivery

- Treat `action_result.result` as readable text. It is not a JSON-encoded list and must not be passed to `Jason.decode!/1`.
- For programmatic fact access, call `Gralkor.Client.search/1,2` with `result_type: :facts`. Read `result.fact.fact` and `result.fact.sources` directly. Lens selectors are supported for facts as well as episodes.
- For complete stored Reflection output, use episode or artefact search. Episode results expose `result.episode.artefact.id` and `.payload`; consumers no longer decode Reflection JSON from `episode.content`.
- Naturally textual episode content stays text. Do not recursively decode source strings.

Jido AI 2.3.0 serializes the small action envelope containing the readable string. One decode of a model tool message yields `%{"ok" => true, "result" => %{"result" => text}}`. The formatter keeps that text below the released sanitizer's string limit, so nested payload depth, collection sizes, and domain-key redaction do not affect the fact presentation. No framework patch or fork is required. The repository retains its Hex dependency.

Provider-boundary acceptance compares the actual outgoing tool text with the expected complete presentation, including Unicode, domain-key wording, more than 100 facts, and explicit oversized-fact omissions. Native-boundary tests cover provenance and Lens filtering before the per-Destination limit. These checks establish retrieval and transport behavior; they do not guarantee a model's interpretation. Phil must install this jido_gralkor change; its existing wrapper can continue delegating to the action.

Facts, nodes, and artefacts remain available as explicit advanced result types:

```elixir
Gralkor.Client.search(agent_server, %Gralkor.Search{
  operator_id: operator_id,
  query: "What should I remember?",
  destinations: ["global"],
  result_type: :facts
})
```

Set `result_type` to `:facts`, `:nodes`, or `:artefacts` for those forms. Node results may be filtered by ontology entity type, and fact results by ontology relationship type. A non-empty `lenses` selector cannot be combined with these non-episode result types.
