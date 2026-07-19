Unit: In-memory Lens storage (src: lib/gralkor/lens/storage/in_memory.ex; unit: test/gralkor/lens/storage/in_memory_test.exs)

when a Lens store adds an episode with an explicit identity
  then the stored episode records that identity
  and removing that identity removes the same stored episode
