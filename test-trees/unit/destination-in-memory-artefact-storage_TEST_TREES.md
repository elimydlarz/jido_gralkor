Unit: destination-in-memory-artefact-storage (src: lib/gralkor/destination/storage/in_memory.ex; unit: test/gralkor/destination/storage/in_memory_artefact_test.exs)

when in-memory Destination storage receives a new artefact
  then it stores the artefact at the declared Destination output
  and exact lookup returns that artefact
  and Destination search returns it in insertion order

when in-memory Destination storage receives the same artefact identifier and immutable content repeatedly
  then every write succeeds
  and exact lookup and Destination search retain exactly one copy at its original position

when in-memory Destination storage receives an existing artefact identifier with different immutable content
  then the write returns an artefact conflict
  and exact lookup and Destination search retain the original unchanged

when in-memory Destination storage looks up an absent artefact identifier
  then lookup reports not found

when in-memory Destination storage is searched with neither included writers nor an earliest creation time
  then facts and episodes of the Destination are returned within their limits
  and no nodes are returned because this backend extracts no entities

when in-memory Destination storage is searched with writers included
  then only episodes written by an included writer are returned
  and only facts drawn from those episodes are returned
  and no nodes are returned
  but no episode by another writer contributes

when in-memory Destination storage is searched with an earliest creation time
  then only episodes stored at or after that time are returned
  and only facts drawn from those episodes are returned
  and no nodes are returned
  and included and excluded writers further restrict the remaining episodes
