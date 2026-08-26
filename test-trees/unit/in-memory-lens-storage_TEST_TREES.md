Unit: in-memory-lens-storage (src: lib/gralkor/lens/storage/in_memory.ex; unit: test/gralkor/lens/storage/in_memory_test.exs)

when a Lens store adds episodes to an operator's Destination or the `global` Destination
  then each episode remains in insertion order within only its Destination
  and every stored episode retains its originating Lens

when a Lens store is searched with a maximum result count
  then no more than that count is returned from the selected Destination
  and the retained insertion order is preserved

when a replaceable Lens store replaces a complete graph
  then the graph is stored within only its resolved Destination
  and every supplied node and relationship retains each non-reserved graph value
  and every supplied node and relationship records the replacing Lens as its owner
  and graph content previously owned by the replacing Lens at that destination is removed
  and graph content owned by another Lens at that destination remains unchanged
  and information saved through Reflections at that destination remains unchanged
  and graph content without a Lens owner at that destination remains unchanged

where a replaceable Lens store supplies an empty complete graph
  then graph content previously owned by the replacing Lens at that destination is removed
  and no replacement graph content is stored

when a replaceable Lens store replaces its complete graph more than once
  then only the most recently supplied graph remains owned by that Lens at the resolved destination

when a replaceable Lens store is searched
  then search reads from its resolved Destination
