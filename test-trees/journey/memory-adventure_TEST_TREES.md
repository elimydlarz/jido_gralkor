Journey: memory-adventure (journey: test/journey/memory_adventure_journey_test.exs)

# Adventure: one operator adds ontology-free implicit memory, captures and flushes a completed turn through an appending Lens, receives an ERL Learning, and publishes global memory.
# The same operator's appending and replaceable Lenses save to one Destination before the replaceable Lens replaces its earlier graph.
# Fresh sessions then search and recall every Destination; another operator checks that global memory is shared while operator-local memory remains isolated.

when two operators use implicit memory, Lenses, ERL, and shared-Destination replacement
  then fresh retrieval preserves local and global memory but omits the replaced Lens graph
