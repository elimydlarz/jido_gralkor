Journey: memory-adventure (journey: test/journey/memory_adventure_journey_test.exs)

# Adventure: one operator adds ontology-free implicit memory, captures and flushes completed turns through an appending Lens, receives an ERL Learning, evolves a shared generalisation, and publishes global memory.
# The same operator's appending and replaceable Lenses save to one Destination before the replaceable Lens replaces its earlier graph.
# Fresh sessions then search and recall every Destination; another operator checks that global memory is shared while operator-local memory remains isolated.

when two operators use implicit memory, Lenses, ERL, and shared-Destination replacement
  then ontology-free implicit operator memory remains recallable
  and captured appending-Lens information remains searchable
  and ERL stores a structured Learning artefact
  and the global graph is visible to both operators
  and one operator's operator graph is unavailable to another operator
  and implicit-default memory uses the graph named `operator/<operator id>`
  and appending Lenses use that same graph
  and replaceable Lenses use that same graph
  and replacing one Lens's graph preserves information written by another Lens
  and fresh retrieval returns the current replacement graph
  and fresh retrieval omits the superseded replacement graph

when the Journey ingests related information through successive completed ingestions
  then the first resulting generalisation has level one and no preceding generalisations
  and the later generalisation that generalises over the first has level two
  and the later generalisation records the first generalisation's content and level

when the Journey ingests conversation, document, and structured-record episodes
  then every retrieved conversation fact identifies every originating episode
  and every retrieved conversation fact identifies its conversation source kind
  and every retrieved conversation fact identifies its captured-turn source description
  and every retrieved document fact identifies every originating episode
  and every retrieved document fact identifies its document source kind
  and every retrieved document fact identifies its deployment-policy source description
  and every retrieved structured-record fact identifies every originating episode
  and every retrieved structured-record fact identifies its structured-record source kind
  and every retrieved structured-record fact identifies its dependency-registry source description
