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

A Reflection-written result carries `episode.reflection` with the Reflection name and its encoded artefact in `episode.content`.

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
