Unit: reflection-in-memory-storage (src: lib/gralkor/reflection/store.ex, lib/gralkor/reflection/storage/in_memory.ex; unit: test/gralkor/reflection/storage/in_memory_test.exs)

when in-memory Reflection storage receives a new artefact
  then it stores the artefact in its Reflection Destination
  and exact lookup returns that artefact
  and Destination search returns it in insertion order

when in-memory Reflection storage receives the same artefact identifier and immutable content repeatedly
  then every write succeeds
  and exact lookup and Destination search retain exactly one copy at its original position

when in-memory Reflection storage receives an existing artefact identifier with different immutable content
  then the write returns an artefact conflict
  and exact lookup and Destination search retain the original unchanged
