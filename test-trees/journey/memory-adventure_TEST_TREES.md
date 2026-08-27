Journey: memory-adventure (journey: test/journey/memory_adventure_journey_test.exs)

# Adventure: one operator adds ontology-free implicit memory, captures and flushes a completed turn through an appending Lens, receives an ERL Learning, and publishes global memory.
# The same operator's appending and replaceable Lenses save to one Destination before the replaceable Lens replaces its earlier graph.
# Fresh sessions then search and recall every Destination; another operator checks that global memory is shared while operator-local memory remains isolated.

when two operators use implicit memory, Lenses, ERL, and shared-Destination replacement
  then ontology-free implicit operator memory remains recallable
  and captured appending-Lens information remains searchable
  and ERL stores a structured Learning artefact
  and the global graph is visible to both operators
  and one operator's operator graph is unavailable to another operator
  and appending and replaceable Lenses use the same operator graph
  and replacing one Lens's graph preserves information written by another Lens
  and fresh retrieval returns the current replacement graph
  and fresh retrieval omits the superseded replacement graph

when the Journey ingests conversation, document, and structured-record episodes
  then retrieved facts identify every originating episode by identifier, source kind, and source description
