Unit: destination-graphiti-artefact-storage (src: lib/gralkor/destination/storage/graphiti.ex; unit: test/gralkor/destination/storage/graphiti_artefact_test.exs)

when Graphiti Destination storage receives an artefact
  then it uses the output Destination group, serialized producer-independent artefact content, Reflection source provenance, and output ontology
  and it supplies the artefact identifier as the requested episode UUID

when Graphiti Destination storage looks up an artefact identifier
  while the matching episode contains that artefact and durable extraction completion is recorded
    then it returns the matching deserialized artefact
  while the matching episode contains that artefact but durable extraction completion is absent
    then lookup returns the incomplete artefact for Destination storage to resume without rerunning the Runner
  while the episode body is not a valid artefact record
    then lookup reports an invalid artefact
  while the episode is missing
    then lookup reports not found
  while the episode body identifies another artefact
    then lookup reports an artefact conflict

when Graphiti reports an episode conflict for an artefact output
  then Destination storage reports the corresponding artefact conflict

if the episode boundary fails during an artefact write or lookup
  then Destination storage returns that failure unchanged
