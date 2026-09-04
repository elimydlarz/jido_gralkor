Unit: graphiti-lens-storage (src: lib/gralkor/lens/storage/graphiti.ex; unit: test/gralkor/lens/storage/graphiti_test.exs)

when a Lens store adds an episode to the `operator` Destination
  then Graphiti receives the group named `operator/<operator id>`
  and changing the operator produces a distinct group
  and the graph add receives the episode content, source description, and Lens ontology
  and the graph add result is returned to the ingestion process

when a Lens store adds an episode carrying a source kind
  then Graphiti receives that source kind unchanged

if a Lens store receives an unsupported addition or replacement option
  then an `ArgumentError` is raised
  and the error identifies the unsupported option
  and no Graphiti operation begins

when a Lens store using the `operator` Destination is searched
  then graph search receives the same resolved group
  and graph search receives the query and result limit
  and the graph search result is returned to the caller

when the implicit `operator` Lens's packaged Destination is added to or searched
  then graph operations use the group named `operator/<operator id>`

when a Lens store adds an episode to the `global` Destination
  then graph add receives the group named `global` for every operator

when a Lens store adds an episode to an application Destination
  then graph add receives the group named for that Destination for every operator

when a replaceable Lens store using the `operator` Destination replaces a complete graph
  then graph replacement receives the same resolved group used by existing Lens operations
  and graph replacement receives the selected Lens name
  and graph replacement receives the supplied nodes and relationships
  and the graph replacement result is returned to the caller

when a replaceable Lens store using the `global` Destination replaces a complete graph
  then graph replacement receives the group named `global` for every operator
  and graph replacement receives the selected Lens name
  and graph replacement receives the supplied nodes and relationships
  and the graph replacement result is returned to the caller

when a replaceable Lens store using an application Destination replaces a complete graph
  then graph replacement receives the group named for that Destination for every operator
  and graph replacement receives the selected Lens name
  and graph replacement receives the supplied nodes and relationships
  and the graph replacement result is returned to the caller

when a replaceable Lens store is searched
  then graph search receives its resolved Destination group
