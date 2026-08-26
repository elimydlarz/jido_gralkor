Functional: destination-graphs (functional: test/functional/destination_addressing_functional_test.exs)

when a Lens saves an episode to the `operator` Destination
  then the resolved graph is named `operator/<operator id>`
  and the episode is unavailable to another operator using the same Destination
  and the episode is unavailable from any unselected Destination

when a Lens saves an episode to the `global` Destination
  then every operator resolves the one graph named `global`
  and every operator can retrieve the episode by searching the `global` Destination
  and the episode is unavailable from any unselected Destination

when a Lens saves an episode to an application Destination
  then its one graph is named for that Destination
  and every operator can retrieve the episode by searching that Destination
  and the episode is unavailable from any unselected Destination

when multiple Lenses save episodes to the same Destination
  then every episode is available by searching that Destination

where a Lens references a registered Destination
  then that Destination governs the graph for every episode the Lens's ingestion process submits
