Unit: Graphiti Lens storage (src: lib/gralkor/lens/storage/graphiti.ex; unit: test/gralkor/lens/storage/graphiti_test.exs)

when an operator-local Lens store adds an episode
  then Graphiti receives a deterministic group unique to the operator and Lens
  and changing either the operator or Lens produces a distinct group
  and the local group is distinct from the shared global group
  and the graph add receives the episode content, source description, and Lens ontology
  and the graph add result is returned to the ingestion process

when an operator-local Lens store is searched
  then graph search receives the same deterministic operator-and-Lens group
  and graph search receives the query and result limit
  and the graph search result is returned to the caller

when the implicit `default` Lens is added to or searched
  then graph operations use the operator's existing sanitized destination

when a global Lens store adds an episode
  then graph add receives the fixed global group
  and the episode source identifies the originating Lens in the same graph add

when the global pool is searched
  then graph search receives the fixed global group
  and no originating-Lens filter is supplied

when a store bound to a global Lens is searched by its ingestion process
  then graph search receives the fixed unfiltered global group
