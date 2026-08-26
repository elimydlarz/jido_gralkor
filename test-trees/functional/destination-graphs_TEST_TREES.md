Functional: destination-graphs (functional: test/functional/destination_addressing_functional_test.exs)

when a Lens saves an episode to a registered Destination other than `global`
  then the resolved graph is determined by the operator and Destination name together
  and the episode is unavailable to another operator using the same Destination
  and the episode is unavailable from any unselected Destination

when a Lens saves an episode to the `global` Destination
  then every operator resolves the one graph named `global`
  and every operator can retrieve the episode by searching the `global` Destination
  and the episode is unavailable from any unselected Destination

when multiple Lenses save episodes to the same Destination
  then every episode is available by searching that Destination

where a Lens references a registered Destination
  then that Destination's name and ontology govern every episode the Lens's ingestion process submits
