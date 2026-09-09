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

Names within each selector are alternatives: either Destination and either Lens may contribute. When both selectors are present, an episode must satisfy both dimensions. A Lens selector filters writers within the selected Destination graphs; it is not a Destination alias. Lens filtering applies only to episode results.

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

`Gralkor.Client.search/1,2` returns `{:ok, [result]}`. `memory_search` returns `{:ok, %{result: [result], omissions: %{byte_budget: count}}}` after whole-result model budgeting. An empty search returns `[]`. The canonical search API does not apply model budgeting. The existing blank-query short circuit remains an explicit textual NON-RESULT in `result`, and errors remain `{:error, reason}`.

Reflection payload keys and values retain their stored shape; Graphiti JSON object keys are strings. Only Reflection-provenanced episode bodies are decoded. Lens-authored documents, Jira records, and even text that happens to look like an artefact remain text in `episode.content`. A malformed completed Reflection body returns `{:error, {:invalid_reflection_artefact, reflection_name}}`; search does not return a manufactured partial response. Stored Graphiti representation and completion filtering are unchanged, so existing valid completed artefacts need no storage migration.

Fact results have `%{destination: name, fact: record}`. The Graphiti record contains `fact` text, `created_at`, `valid_at`, `invalid_at`, `expired_at`, and `sources`; each source retains `id`, `source_kind`, and `source_description`. Missing timestamps remain `nil`. In-memory storage is a deterministic test backend: it wraps stored episode text as a fact record with Lens and source-description attribution rather than performing extraction. Node results remain `%{destination: name, node: node_map}`; explicit artefact results remain `%{destination: name, artefact: %Gralkor.Artefact{id: id, payload: payload}}`.

Readable presentation is separate: call `Gralkor.Format.format_fact(record)` explicitly. Legacy `recall` still uses that operation to construct its readable memory block. Search never invokes readable fact formatting.

### Whole-result model budgeting

`JidoGralkor.MemorySearchPresentation.for_model(results, max_bytes)` is an explicit operation returning structured data. The action uses it with `tool_context[:memory_search_max_bytes]`, defaulting to 65,536 UTF-8 bytes. Set this per agent or request to match the consuming model's budget. This is a byte budget, not a token estimate.

The operation measures the complete Jido success envelope, including `ok`, `result`, and omission metadata. It scans results in order, retains a result only when that whole result fits, and continues considering later results after an oversized result. Neither source content nor Reflection history is shortened. `omissions.byte_budget` counts omitted results outside the result list; it is zero when everything fits. If the budget cannot hold even an empty success envelope with that count, the action returns `{:error, {:memory_search_budget_too_small, %{max_bytes: limit, minimum_bytes: required}}}`. Non-positive or non-integer budgets raise before search starts.

The underlying `Gralkor.Client.search/1,2` result list remains complete within its requested per-Destination retrieval limit. Callers can apply the explicit projection themselves without changing canonical memory data.

### Consumer migration and model delivery

This is a breaking return-value change:

- Remove `Jason.decode!(action_result.result)`; use `action_result.result` directly after handling the blank-query NON-RESULT.
- Replace `Jason.decode!(result.episode.content)` for Reflections with `result.episode.artefact`; read `.id` and `.payload` directly. Branch on `episode.reflection` versus `episode.lens` rather than guessing from source text.
- Replace string operations on `result.fact` with access to `result.fact.fact` and `result.fact.sources`, or explicitly call `Gralkor.Format.format_fact/1` for display.
- Keep domain payload keys as delivered. Do not recursively decode source strings, rename payload keys, or re-encode the result list before handing it to the agent framework.

The inspected Phil wrapper delegates directly to `JidoGralkor.Actions.MemorySearch.run/2`; its execution wrapper needs no change. Phil must adopt both this structured action and the lossless Jido AI transport change. Its previously installed action pre-encodes the result list, exposing the entire inner JSON string to truncation. Installing only the structured action removes double encoding but exposes the released framework's depth and collection limits.

Jido AI 2.3.0 and upstream main at `439bd61debf1fe62413303ea2e0e5bc3b1908cca` apply diagnostic sanitization before serializing successful tool results. That sanitizer limits strings to 16,384 characters, lists/maps to 100 entries, and nesting to eight levels; it also redacts keys such as `document_key`. These operations corrupt canonical memory data even when the result fits the model budget.

The tested Jido AI fix serializes successful JSON-compatible tool output directly at `Jido.AI.Turn.format_tool_result_content/1`. Diagnostic and error sanitization remain separate. Non-JSON-compatible successful output becomes an explicit `invalid_tool_output` error. Successful domain fields are not implicitly redacted by name: a producer must explicitly select which information it authorizes for the model before returning its output.

One decode of the model's tool-message content yields:

```elixir
%{
  "ok" => true,
  "result" => %{
    "result" => [attributed_result],
    "omissions" => %{"byte_budget" => 0}
  }
}
```

Deterministic acceptance tests inspect the actual outgoing provider request and compare complete payloads, including deep evolution history, `document_key`, a 16,385-character source field, 101 results, and exact whole-result omissions at the serialized byte limit. These tests establish transport delivery; they do not guarantee the model's interpretation or a Phil deployment. Retrieval `max_results` remains a per-Destination top-k selection, not a transport budget or a count of all matching memories.

**Dependency installation remains pending:** the verified framework candidate is currently installed locally for testing; `mix.exs` and `mix.lock` still select the unpatched Hex release. A reproducible dependency pin is required before this migration is complete. Phil's checkout and deployment have not been updated.

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
