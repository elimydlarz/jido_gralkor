# Destinations

This document records the agreed direction for first-class Destinations in Jido Gralkor.

## Model

A Destination is a named place in memory. It has an address and an ontology:

```elixir
%Gralkor.Destination{
  name: "mistakes",
  address: "operator/mistakes",
  ontology: MyApp.MistakeOntology
}
```

Lenses and Reflections reference a registered Destination by name. Multiple Lenses and Reflections may save information to the same Destination.

A Destination is not owned by a Lens or Reflection. There is no generalized contributor or storage-channel concept.

## Addresses

A Destination has no separate scope property. Its address has the form `scope/path`:

```text
operator/mistakes
global/generalisations
```

An `operator/path` address resolves to a graph ID combining the requesting operator with the path. Different operators therefore use different graphs for the same Destination.

A `global/path` address resolves to the same graph ID for every operator. Information saved there is globally available.

The resolved Graphiti graph ID is an implementation detail. The stable application-facing value is the Destination address.

## Ontologies

The Destination ontology governs extraction for everything saved to that Destination.

When an application Destination omits its ontology, it uses `Gralkor.DefaultOntology`. Custom extraction schemas are configured on registered Destinations rather than globally or directly on Lenses and Reflections.

Jido Gralkor packages these default Destinations:

- Operator memory uses an `operator/...` address and `Gralkor.DefaultOntology`. Legacy capture, `memory_add/3`, `recall/4`, and the reserved operator Lens use it.
- Experiential learning uses `operator/experiential-learning` and `Gralkor.Reflection.ERLOntology`. The packaged ERL Reflection uses it.
- Global generalisations use `global/generalisations`. The packaged generalisation Reflection uses it.

`Gralkor.Reflection.ERLOntology` defines the `Learning` entity used by ERL, including optional problem kind, approach, success, and reusable lesson fields.

## Lenses and Reflections

Lenses define ingestion or complete-graph replacement and reference a Destination:

```elixir
%Gralkor.Lens{
  name: "support-cases",
  destination: product_knowledge,
  ingestion: MyApp.SupportIngestion
}
```

Reflections define post-ingestion reasoning and reference a Destination:

```elixir
%Gralkor.Reflection{
  name: "generalisation",
  destination: generalisations,
  chain_of_thought: chain
}
```

Neither type declares its own address or ontology.

## Replaceable Lenses

A replaceable Lens replaces only graph content previously written by that Lens. It does not clear or replace its Destination.

The private `_gralkor_lens` ownership field identifies graph content written by a replaceable Lens. Replacing Lens `A` removes content carrying `_gralkor_lens: "A"`, then inserts the new graph carrying the same marker.

Information saved through other Lenses, information saved through Reflections, and information without Lens `A`'s ownership marker remain unchanged.

This Lens-specific replacement bookkeeping does not create a generalized ownership or contributor abstraction.

## Search

Search names Destinations, not Lenses or Reflections:

```elixir
Gralkor.Client.search(%Gralkor.Search{
  operator_id: operator_id,
  query: "What mistakes should I avoid?",
  destinations: ["mistakes", "generalisations"],
  result_type: :facts
})
```

Each distinct Destination is searched once. Multiple Destinations are searched concurrently, and their results retain requested Destination order. Every result identifies its Destination.

When no Destination is supplied, search uses the packaged operator-memory and global-generalisations Destinations.

Search supports these result types:

- `:facts` for extracted relationships.
- `:nodes` for extracted entities.
- `:episodes` for saved episode bodies.
- `:artefacts` for final Reflection artefacts. Each artefact identifies its declaring Reflection because Reflection identity is intrinsic artefact data.

Node results may be filtered by ontology entity type, and fact results may be filtered by ontology relationship type.

Lens and Reflection names are not general search filters or indirect aliases for Destinations.
