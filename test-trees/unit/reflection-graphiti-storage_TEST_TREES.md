Unit: reflection-graphiti-storage (src: lib/gralkor/reflection/store.ex, lib/gralkor/reflection/storage/graphiti.ex; unit: test/gralkor/reflection/storage/graphiti_test.exs)

when Graphiti Reflection storage receives an artefact
  then it uses the Reflection Destination group, serialized immutable artefact content, Reflection source, and ontology
  and it supplies the artefact identifier as the requested episode UUID

when Graphiti Reflection storage looks up an artefact identifier
  while the matching episode contains that artefact for the requested Reflection
    then it returns the matching deserialized artefact
  while the episode is missing
    then lookup reports not found
  while the episode body identifies another artefact or Reflection
    then lookup reports an artefact conflict

when Graphiti reports an episode conflict for a Reflection artefact
  then Reflection storage reports the corresponding artefact conflict
