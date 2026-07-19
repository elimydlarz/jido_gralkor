Unit: Graphiti Lens storage (src: lib/gralkor/lens/storage/graphiti.ex; unit: test/gralkor/lens/storage/graphiti_test.exs)

when an operator-local Lens store adds an episode
  then the graph add receives a deterministic destination unique to the operator and Lens
  and the graph add receives the episode content, source description, and Lens ontology
  and the graph add result is returned to the ingestion process

when an operator-local Lens store is searched
  then graph search receives the same deterministic operator-and-Lens destination
  and graph search receives the query and result limit
  and the graph search result is returned to the caller

when the implicit `default` Lens is added to or searched
  then graph operations use the operator's existing sanitized destination

when an operator-local Lens store removes an episode
  then graph removal receives the same operator-and-Lens destination and episode identity

when a global Lens store adds an episode
  then graph add receives the fixed global destination
  and graph add receives the originating Lens as provenance

when the global pool is searched
  then graph search receives the fixed global destination
  and no originating-Lens filter is supplied
