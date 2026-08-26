# Destinations

A Destination is one named graph:

```elixir
%Gralkor.Destination{name: "global"}
```

Lenses and Reflections reference registered Destinations by name. Multiple writers may save information to the same graph.

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

Destinations do not own extraction ontologies. Each appending Lens and Reflection selects the ontology for the information it writes, defaulting to `Gralkor.DefaultOntology`:

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
      destination: "global",
      ontology: MyApp.ReleaseOntology,
      chain_of_thought: "priv/reflections/release-review.yaml"
    ]
  ]
```

The packaged `operator` Lens writes with `Gralkor.DefaultOntology`. The packaged generalisation Reflection writes to `global` with `Gralkor.DefaultOntology`; the packaged ERL Reflection writes to `operator` with `Gralkor.Reflection.ERLOntology`.

## Replaceable Lenses

A replaceable Lens replaces only graph content previously written by that Lens. It does not clear or replace its Destination.

The private `_gralkor_lens` ownership field identifies graph content written by a replaceable Lens. Replacing Lens `A` removes content carrying `_gralkor_lens: "A"`, then inserts the new graph carrying the same marker.

Information saved through other Lenses, information saved through Reflections, and information without Lens `A`'s ownership marker remain unchanged.

## Search

Search names Destinations directly:

```elixir
Gralkor.Client.search(%Gralkor.Search{
  operator_id: operator_id,
  query: "What should I remember?",
  destinations: ["operator", "global"],
  result_type: :facts
})
```

Each distinct Destination is searched once. Multiple Destinations are searched concurrently, their results retain requested Destination order, and every result identifies its Destination.

When no Destination is supplied, search uses `operator` and `global`.

Search supports `:facts`, `:nodes`, `:episodes`, and `:artefacts`. Node results may be filtered by ontology entity type, and fact results by ontology relationship type. Lens and Reflection names are not search aliases.
