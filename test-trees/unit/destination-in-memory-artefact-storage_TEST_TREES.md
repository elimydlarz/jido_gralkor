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

when in-memory Destination storage is searched with no Lenses
  then facts, nodes, and episodes of the Destination are returned within their limits

when in-memory Destination storage is searched with Lenses
  then only episodes written through a selected Lens are returned
  and only facts drawn from those episodes or written by a selected Lens's graph replacement are returned
  and only nodes owned by a selected Lens's graph replacement are returned
  but no direct write or Destination artefact contributes
  and nodes are limited after Lens filtering
