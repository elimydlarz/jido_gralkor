Unit: gralkor-ontology (src: lib/gralkor/ontology.ex; unit: test/gralkor/ontology_test.exs)

when a module declares an ontology with `use Gralkor.Ontology`
  if the `:entities` option is not provided
    then compilation fails with an error naming `:entities` and its allowed values `:strict` and `:open`
  if the `:entities` option is any value other than `:strict` or `:open`
    then compilation fails with an error naming `:entities` and the rejected value
  if the `:relationships` option is not provided
    then compilation fails with an error naming `:relationships` and its allowed values `:scoped` and `:open`
  if the `:relationships` option is any value other than `:scoped` or `:open`
    then compilation fails with an error naming `:relationships` and the rejected value

when an ontology declares `entity Foo do … end` with an alias
  then the entity is named with the alias' last segment as a string ("Foo")
  and no module named Foo is defined by the declaration
  where the block calls `field :name, :type`
    then the entity carries a field with that name and type
    where the call passes `required: true`
      then the field is recorded as required
    where the call omits `:required` or passes `required: false`
      then the field is recorded as optional
    where the call passes `doc: "…"`
      then the doc string is recorded as the field's description
    where the call omits `:doc`
      then the field's description is recorded as nil
    if `:type` is outside the supported set (`:string`, `:integer`, `:float`, `:boolean`)
      then compilation fails with an error naming the rejected type
    if `:required` is given a non-boolean value
      then compilation fails with an error naming `:required`
    if `:doc` is given a value that is neither a string nor nil
      then compilation fails with an error naming `:doc`
  if two fields in the same entity share a name
    then compilation fails with an error naming the duplicated field
  if a non-field expression appears inside the block
    then compilation fails, only `field` declarations being available inside an `entity` block and relationships living in `from` blocks
  if the same entity name is declared more than once in one ontology
    then compilation fails with an error naming the duplicated entity

when an ontology declares `from Source do … end` with an alias
  where the block calls `verb Target` with no do-block
    then a relationship is declared from the source entity to the target entity under the verb's edge name
    and that relationship carries no edge properties
  where the block calls `verb Target do … end`
    then a relationship is declared from the source entity to the target entity under the verb's edge name
    and the do-block's `field` declarations become that relationship's edge properties, with the same name, type, required and doc semantics as entity fields
  where the verb is a single lowercase word ("prefers")
    then the edge name is that word uppercased ("PREFERS")
  where the verb contains underscores ("relates_to")
    then the edge name uppercases each segment and preserves the underscores ("RELATES_TO")
  where the verb's target is the source entity itself
    then the endpoint pair records that entity as both source and target
  where the same verb appears in several `from` blocks with matching edge-property schemas
    then exactly one edge type is declared for that verb
    and the endpoint map gains one entry per distinct (source, target) pair where the verb appeared, in the order those pairs were declared
  if the verb's target is not an alias
    then compilation fails with an error showing the expected `verb Target` form
  if the same verb is declared again with a differing edge-property schema (field names, types or required flags)
    then compilation fails with an error naming the conflicting verb
  if the source alias does not name a declared entity
    then compilation fails at the end of the module naming the unknown source
  if a relationship's target alias does not name a declared entity
    then compilation fails at the end of the module naming the unknown target

when a consumer calls `__ontology__/0` on a declared ontology module
  then it returns a map whose keys are exactly `:entity_types`, `:edge_types`, `:edge_type_map` and `:excluded_entity_types`
  and `:entity_types` lists one `%{name: String.t(), fields: [field()]}` entry per declared entity, in declaration order
  and `:edge_types` lists one `%{name: String.t(), fields: [field()]}` entry per declared verb, deduplicated across `from` blocks
  and `:edge_types` preserves the verbs' first-declaration order
  and `:edge_type_map` lists `{{source_name, target_name}, [edge_name]}` pairs preserving declaration order across `from` blocks
  and each field entry is `%{name: atom(), type: atom(), required: boolean(), doc: String.t() | nil}`

while an ontology is declared with `relationships: :open`
  then `__ontology__/0` returns an empty `:edge_type_map` even when relationships were declared, so every named edge stays allowed everywhere
  but the declared verbs still appear in `:edge_types`

while an ontology is declared with `relationships: :scoped`
  then `__ontology__/0` returns exactly the declared (source, target) → [edge_name] entries in `:edge_type_map`

while an ontology is declared with `entities: :open`
  then `__ontology__/0` returns nil for `:excluded_entity_types`, leaving generic Entity extraction enabled

while an ontology is declared with `entities: :strict`
  then `__ontology__/0` returns `["Entity"]` for `:excluded_entity_types`, so only declared types are extracted

while an ontology declares no entities and no relationships
  then `__ontology__/0` still returns a valid payload with an empty `:entity_types`
  and an empty `:edge_types`
  and an empty `:edge_type_map`
  and an `:excluded_entity_types` that still follows the declared `:entities` option
