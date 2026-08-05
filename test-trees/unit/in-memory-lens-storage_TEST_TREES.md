Unit: in-memory-lens-storage (src: lib/gralkor/lens/storage/in_memory.ex; unit: test/gralkor/lens/storage/in_memory_test.exs)

when an operator-local or global Lens store adds episodes
  then each episode remains in insertion order within only its selected Lens group
  and every stored episode retains its originating Lens

when an operator-local or global Lens store is searched with a maximum result count
  then no more than that count is returned from the selected group
  and the retained insertion order is preserved
