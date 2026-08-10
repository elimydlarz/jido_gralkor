Functional: ontology-extraction (functional: test/functional/ontology_extraction_test.exs)

when an episode is ingested through a named Lens with a strict ontology
  then extraction conforms every node and relationship to the declared ontology

when an episode is ingested through a named Lens with an open ontology
  then extraction includes the declared entity types without excluding generic entities

when an episode is added through implicit-default memory
  then extraction preserves generic entities without undeclared custom labels

where a named Lens supplies an application-owned ontology that differs from jido_gralkor's built-in ontology
  then that Lens's extraction is governed by its application-owned ontology alone
