Functional: ontology-extraction (src: lib/gralkor/graphiti_pool.ex, lib/gralkor/client/native.ex, lib/gralkor/lens/storage/graphiti.ex; functional: test/functional/ontology_extraction_functional_test.exs)

when an episode is ingested through a named Lens with a strict ontology
  then every extracted entity carries only declared entity types
  and a relationship between declared endpoint types carries its declared relationship name

when an episode is ingested through a named Lens with an open ontology
  then extraction includes the declared entity types without excluding generic entities

when an episode is added through implicit-default memory
  then extraction preserves generic entities without undeclared custom labels

where a named Lens supplies an application-owned ontology that differs from jido_gralkor's built-in ontology
  then that Lens's extraction is governed by its application-owned ontology alone
