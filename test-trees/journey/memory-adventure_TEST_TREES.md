Journey: memory-adventure (journey: test/journey/memory_adventure_journey_test.exs)

# Adventure: one operator adds ontology-free implicit memory, captures and flushes completed turns through an appending Lens, receives an ERL Learning, evolves a shared generalisation, and publishes global memory.
# The same operator's appending and replaceable Lenses save to one Destination before the replaceable Lens replaces its earlier graph.
# Fresh sessions then use default and selected memory search; another operator checks that shared memory remains visible while operator-local memory remains isolated.

when two operators use implicit memory, Lenses, ERL, and shared-Destination replacement
  then ontology-free implicit operator memory remains recallable
  and captured appending-Lens information remains searchable
  and ERL writes a structured Learning artefact through its Destination output
  and the global graph is visible to both operators
  and one operator's operator graph is unavailable to another operator
  and implicit-default memory uses the graph named `operator/<operator id>`
  and appending Lenses use that same graph
  and replaceable Lenses use that same graph
  and replacing one Lens's graph preserves information written by another Lens
  and fresh retrieval returns the current replacement graph
  and fresh retrieval omits the superseded replacement graph

when the Journey completes successive ingestions containing related observations
  then the first resulting generalisation has evolution-depth level one and an empty `evolves_from`
  and the later generalisation that evolves from the first has evolution-depth level two
  and the later generalisation's `evolves_from` records the first generalisation's content and level

when a fresh agent handles a request related to an evolved generalisation
  then one MemorySearch call is made without selectors
  and every accessible registered Destination is searched
  and its results include relevant lensed information and relevant stored generalisations
  and every result identifies its Destination and any originating Lens
  and the agent applies the relevant evolved generalisation in light of its evolution history and related observations

when the agent searches with both Destination and Lens selectors
  then only memory in the intersection is returned
  and those search selectors do not change the Lens used for later ingestion or capture

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
