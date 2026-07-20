Integration: Lens registration (integration: none)

when an application registers a Lens with a non-blank name, ontology, operator-local or global scope, and ingestion process
  then direct callers and mounted memory plugins can select that Lens by name
  and every consumer observes the same application-owned Lens definition

if a Lens definition is blank, duplicate, reserved as `default` or `global`, or malformed
  then configuration resolution raises `ArgumentError` naming the invalid Lens before ingestion or search begins
