Functional: ontology-extraction (functional: test/functional/ontology_extraction_test.exs)

when an episode is ingested under a strict ontology
  then extraction conforms every node and relationship to the declared ontology

when an episode is ingested under an open ontology
  then extraction includes the declared entity types without excluding generic entities

when an episode is ingested while no ontology is configured
  then extraction preserves generic entities without undeclared custom labels

where a memory write supplies an ontology that differs from application configuration
  then that write's extraction is governed by the supplied ontology alone
