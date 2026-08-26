Unit: graphiti-lens-storage (src: lib/gralkor/lens/storage/graphiti.ex; unit: test/gralkor/lens/storage/graphiti_test.exs)

when a Lens store adds an episode to a Destination other than `global`
  then Graphiti receives a deterministic group unique to the operator and Destination name
  and changing either the operator or Destination produces a distinct group
  and the graph add receives the episode content, source description, and Destination ontology
  and the graph add result is returned to the ingestion process

when a Lens store using a Destination other than `global` is searched
  then graph search receives the same resolved group
  and graph search receives the query and result limit
  and the graph search result is returned to the caller

when the implicit `operator` Lens's packaged Destination is added to or searched
  then graph operations use the operator's existing sanitised group id

when a Lens store adds an episode to the `global` Destination
  then graph add receives the group named `global` for every operator

when a replaceable Lens store using a Destination other than `global` replaces a complete graph
  then graph replacement receives the same resolved group used by existing Lens operations
  and graph replacement receives the selected Lens name, configured graph format, and supplied graph data
  and the graph replacement result is returned to the caller

when a replaceable Lens store using the `global` Destination replaces a complete graph
  then graph replacement receives the group named `global` for every operator
  and graph replacement receives the selected Lens name, configured graph format, and supplied graph data
  and the graph replacement result is returned to the caller

when a replaceable Lens store is searched
  then graph search receives its resolved Destination group
