Functional: ontology-extraction (functional: test/functional/ontology_extraction_test.exs)

while memory writes run against a real graph and a real extraction LLM
  when an episode is ingested under a strict ontology declaring entity and relationship types
    then a node carrying each declared entity type's label is extracted from the episode
    and every extracted node carries at least one declared label rather than only the generic "Entity" label
    and an entity-to-entity edge carries the declared relationship verb as its semantic type
  when the same episode is ingested under an open ontology declaring the same types
    then a node carrying each declared entity type's label is still extracted
    but generic nodes are permitted alongside the declared ones
  when the same episode is ingested with no ontology declared for the write and none configured
    then no node carries a label from any undeclared entity type
    and the graph still contains generic entity nodes, preserving pre-ontology extraction
  where a caller passes an ontology as a per-call override on the memory write
    then that ontology alone governs extraction for that write, independent of any globally configured ontology
  if the real graph runtime or LLM credentials are unavailable
    then the run fails rather than skipping
