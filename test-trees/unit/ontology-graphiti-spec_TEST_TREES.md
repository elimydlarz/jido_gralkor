Unit: ontology-graphiti-spec (src: lib/gralkor/graphiti_pool.ex; unit: test/gralkor/ontology_graphiti_spec_test.exs)

when a caller projects an ontology payload into the graphiti boundary spec
  while the payload declares entities
    then the spec carries `:entity_types` as string-keyed name/fields maps in declaration order
  while the payload declares no entities
    then the spec omits `:entity_types` entirely, so the episode write is made without that kwarg
  while the payload declares relationship verbs
    then the spec carries `:edge_types` as string-keyed name/fields maps in first-declaration order
  while the payload declares no relationship verbs
    then the spec omits `:edge_types` entirely, so the episode write is made without that kwarg
  while a projected type carries a required field
    then that field's entry carries `"required" => true`
  while a projected type carries an optional field
    then that field's entry carries `"required" => false`
  while a projected type carries a field with a doc string
    then that field's entry carries `"doc" =>` that string
  while a projected type carries a field with no doc string
    then that field's entry carries `"doc" => nil`
  while the payload's `:edge_type_map` is non-empty
    then the spec carries `:edge_type_map` as src/dst/names maps in the payload's order
  while the payload's `:edge_type_map` is empty
    then the spec omits `:edge_type_map` entirely, leaving graphiti's default that every named edge is allowed everywhere
  while the payload's `:excluded_entity_types` is `["Entity"]`
    then the spec carries `:excluded_entity_types` as `["Entity"]`
  while the payload's `:excluded_entity_types` is nil
    then the spec omits `:excluded_entity_types` entirely
  while the payload declares no entities, no verbs, and a nil `:excluded_entity_types`
    then the spec is empty, so the episode write is made with none of the four ontology kwargs
  while the payload declares no entities and no verbs but excludes "Entity"
    then the spec carries only `:excluded_entity_types`
