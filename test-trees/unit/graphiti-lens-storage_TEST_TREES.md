Unit: graphiti-lens-storage (src: lib/gralkor/lens/storage/graphiti.ex; unit: test/gralkor/lens/storage/graphiti_test.exs)

when a Lens store adds an episode to an `operator/path` Destination
  then Graphiti receives a deterministic group unique to the operator and address path
  and changing either the operator or address path produces a distinct group
  and the graph add receives the episode content, source description, and Destination ontology
  and the graph add result is returned to the ingestion process

when a Lens store using an `operator/path` Destination is searched
  then graph search receives the same resolved group
  and graph search receives the query and result limit
  and the graph search result is returned to the caller

when the implicit `operator` Lens's packaged Destination is added to or searched
  then graph operations use the operator's existing sanitised group id

when a Lens store adds an episode to a `global/path` Destination
  then graph add receives the same address-derived group for every operator

when a replaceable Lens store using an `operator/path` Destination replaces a complete graph
  then graph replacement receives the same resolved group used by existing Lens operations
  and graph replacement receives the selected Lens name, configured graph format, and supplied graph data
  and the graph replacement result is returned to the caller

when a replaceable Lens store using a `global/path` Destination replaces a complete graph
  then graph replacement receives the same address-derived group for every operator
  and graph replacement receives the selected Lens name, configured graph format, and supplied graph data
  and the graph replacement result is returned to the caller

when a replaceable Lens store is searched
  then graph search receives its resolved Destination group
