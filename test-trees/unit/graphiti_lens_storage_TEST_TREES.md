Unit: Graphiti Lens storage (src: lib/gralkor/lens/storage/graphiti.ex; unit: test/gralkor/lens/storage/graphiti_test.exs)

when an operator-local Lens store adds an episode
  then the graph add receives a deterministic destination unique to the operator and Lens
  and the graph add receives the episode content, source description, and Lens ontology
  and the graph add result is returned to the ingestion process
