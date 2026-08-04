Unit: learning-entity (src: lib/gralkor/learning_entity.ex; unit: test/gralkor/learning_entity_test.exs)

when the built-in learning entity type is requested
  then it is named "Learning"
  and it carries a non-empty description, without which the extraction model never mints a learning node
  and it declares the problem kind, the approach, the success flag, and the lesson, in that order
  and the problem kind is an optional string
  and the approach is an optional string
  and the success flag is an optional boolean
  and the lesson is an optional string
  and every field being optional means extraction never drops the entity over a missing attribute
  and no field takes a name the graph store reserves for itself

when a consumer's entity-type list is merged with the built-in learning entity type
  while the list declares no entity named "Learning"
    then the learning entry is appended after every entry the consumer declared
  while the list declares no entity types at all
    then the learning entry is the only entry returned
  if the list already declares an entity named "Learning"
    then the list is returned unchanged, so a consumer's own learning entity is never overridden

when a consumer ontology payload is merged with the built-in learning entity type
  then the payload's entity types gain the learning entry
  and the payload's edge types, edge-type map, and excluded entity types are preserved unchanged

while no consumer ontology payload is supplied
  when the built-in learning entity type is merged
    then a payload carrying only the learning entity type is returned, so learning extraction is not gated on a configured ontology
    and that payload declares no edge types, no edge-type map, and no excluded entity types
