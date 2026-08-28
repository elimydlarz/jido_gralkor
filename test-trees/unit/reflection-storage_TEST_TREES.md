Unit: reflection-storage (src: lib/gralkor/reflection/store.ex, lib/gralkor/reflection/storage/in_memory.ex, lib/gralkor/reflection/storage/graphiti.ex, lib/gralkor/graphiti_pool.ex; unit: test/gralkor/reflection/storage/in_memory_test.exs, test/gralkor/reflection/storage/graphiti_test.exs, test/gralkor/graphiti_pool_test.exs)

when in-memory storage receives a new artefact
  then it stores the artefact in its Reflection Destination
  and exact lookup returns that artefact
  and Destination search returns it in insertion order

when in-memory storage receives the same artefact identifier and immutable content repeatedly
  then every write succeeds
  and exact lookup and Destination search retain exactly one copy at its original position

when in-memory storage receives an existing artefact identifier with different immutable content
  then the write returns an artefact conflict
  and exact lookup and Destination search retain the original unchanged

when Graphiti Reflection storage receives an artefact
  then it uses the Reflection Destination group, serialized immutable artefact content, Reflection source, and ontology
  and it supplies the artefact identifier as the requested episode UUID

when Graphiti Reflection storage looks up an artefact identifier
  then it returns the matching deserialized artefact
  and a missing episode reports not found

when Graphiti admits a new requested episode UUID under the pinned Graphiti release
  then one episode is created under that UUID through the normal extraction path

when Graphiti receives an existing requested episode UUID with equal immutable episode content
  then the write succeeds without invoking extraction again

when Graphiti receives an existing requested episode UUID with conflicting immutable episode content
  then the write returns an artefact conflict
  and the original episode remains unchanged

when concurrent Graphiti writes use the same requested episode UUID
  then those writes are serialized even when remote Graphiti writes otherwise run concurrently
  and equal writes converge on exactly one episode

when Graphiti commits a requested UUID but its response is lost
  then a repeated equal write confirms the stored episode
  and the repeated write does not invoke extraction again
