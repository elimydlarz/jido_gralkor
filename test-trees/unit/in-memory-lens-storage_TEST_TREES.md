Unit: in-memory-lens-storage (src: lib/gralkor/lens/storage/in_memory.ex; unit: test/gralkor/lens/storage/in_memory_test.exs)

when a Lens store adds episodes to the `personal`, `global`, or an application Destination
  then each episode remains in insertion order within only its Destination
  and every stored episode retains its originating Lens

when a Lens store is searched with a maximum result count
  then no more than that count is returned from the selected Destination
  and the retained insertion order is preserved
