# Destinations

A Destination is one named graph:

```elixir
%Gralkor.Destination{name: "global"}
```

Lenses and Reflection Destination outputs reference registered Destinations by name. Multiple writers may save information to the same graph.

## Graph identity

The package registers two Destinations:

- `global` is the single shared global graph. Its graph ID is exactly `global` for every operator.
- `operator` is operator-local. Its graph ID is `operator/<operator id>`.

An application may register another Destination with only a name:

```elixir
config :jido_gralkor,
  destinations: [[name: "product-knowledge"]]
```

Its graph ID is exactly `product-knowledge`, shared by every operator. There is no address or scope syntax: `global/x` is just another literal Destination name, not part of the `global` graph.

Most shared application memory should target the packaged `global` Destination. Register another Destination only when the application needs a separate graph.

## Ontologies belong to writers

Destinations do not own extraction ontologies. Each appending Lens and Reflection Destination output selects the ontology for the information it writes, defaulting to `Gralkor.DefaultOntology`:

```elixir
config :jido_gralkor,
  lenses: [
    [
      name: "support-cases",
      destination: "global",
      ontology: MyApp.SupportOntology,
      ingestion: MyApp.SupportIngestion
    ]
  ],
  reflections: [
    [
      name: "release-review",
      triggers: [:programmatic],
      chain_of_thought: "priv/reflections/release-review.yaml",
      outputs: [
        [
          kind: :destination,
          destination: "global",
          ontology: MyApp.ReleaseOntology
        ]
      ]
    ]
  ]
```

The packaged `operator` Lens writes with `Gralkor.DefaultOntology`. The packaged generalisation Reflection has a `global` Destination output with `Gralkor.DefaultOntology`; packaged ERL has an `operator` Destination output with `Gralkor.Reflection.ERLOntology`.

## Replaceable Lenses

A replaceable Lens replaces only graph content previously written by that Lens. It does not clear or replace its Destination.

The private `_gralkor_lens` ownership field identifies graph content written by a replaceable Lens. Replacing Lens `A` removes content carrying `_gralkor_lens: "A"`, then inserts the new graph carrying the same marker.

Information saved through other Lenses, information saved through Reflection outputs, and information without Lens `A`'s ownership marker remain unchanged.

## Search

Search reads registered Destinations. With no selectors it searches every accessible registered Destination and returns relevant episodes:

```elixir
Gralkor.Client.search(%Gralkor.Search{
  operator_id: operator_id,
  query: "What should I remember?"
})
```

That includes the packaged `operator` and `global` Destinations and every application Destination. Only the current operator's `operator/<operator id>` graph is searched; other registered Destinations retain their shared graph identity.

Callers may narrow the graphs with `destinations` and may narrow episode writers with `lenses`:

```elixir
Gralkor.Client.search(%Gralkor.Search{
  operator_id: operator_id,
  query: "What should I remember?",
  destinations: ["operator", "global"],
  lenses: ["support-cases", "decisions"]
})
```

Names within each selector are alternatives: either Destination and either Lens may contribute. When both selectors are present, an episode must satisfy both dimensions. A Lens selector filters writers within the selected Destination graphs; it is not a Destination alias. Lens filtering applies only to episode results.

Each distinct Destination is searched once. Multiple Destinations are searched concurrently, their results retain requested Destination order, and every result identifies its Destination. Episode results also identify their writer. A Lens-written result has this shape:

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
Gralkor.Client.search(%Gralkor.Search{
  operator_id: operator_id,
  query: "What should I remember?",
  destinations: ["global"],
  result_type: :facts
})
```

Set `result_type` to `:facts`, `:nodes`, or `:artefacts` for those forms. Node results may be filtered by ontology entity type, and fact results by ontology relationship type. A non-empty `lenses` selector cannot be combined with these non-episode result types.
