Functional: destination-addressing (functional: test/functional/destination_addressing_functional_test.exs)

when a Lens saves an episode to an `operator/path` Destination
  then the resolved graph is determined by the operator and address path together
  and the episode is unavailable to another operator using the same Destination
  and the episode is unavailable from any unselected Destination

when a Lens saves an episode to a `global/path` Destination
  then every operator resolves the same graph for that address path
  and the episode is unavailable from any unselected Destination

when multiple Lenses save episodes to the same Destination
  then every episode is available by searching that Destination

where a Lens references an operator or global Destination
  then that Destination's address and ontology govern every episode the Lens's ingestion process submits
