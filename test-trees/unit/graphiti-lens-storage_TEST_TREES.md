Unit: graphiti-lens-storage (src: lib/gralkor/lens/storage/graphiti.ex; unit: test/gralkor/lens/storage/graphiti_test.exs)

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

when the implicit `operator` Lens is added to or searched
  then graph operations use the operator's existing sanitised group id

when a global Lens store adds an episode
  then graph add receives the fixed global group
  and the episode source description identifies the originating Lens in the same graph add

when the reserved `global` Lens is searched
  then graph search receives the fixed global group
  and no originating-Lens filter is supplied

when a store bound to a global Lens is searched by its ingestion process
  then graph search receives the fixed unfiltered global group

when an operator-local replaceable Lens store replaces a complete graph
  then graph replacement receives the same deterministic operator-and-Lens group used by existing Lens operations
  and graph replacement receives the selected Lens name, configured graph format, and supplied graph data
  and the graph replacement result is returned to the caller

when a global replaceable Lens store replaces a complete graph
  then graph replacement receives the fixed global group
  and graph replacement receives the selected Lens name, configured graph format, and supplied graph data
  and the graph replacement result is returned to the caller

when an operator-local or global replaceable Lens store is searched
  then graph search receives the destination resolved from the Lens scope
