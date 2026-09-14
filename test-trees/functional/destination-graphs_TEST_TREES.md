Functional: destination-graphs (src: lib/gralkor/destination.ex, lib/gralkor/destination/registry.ex, lib/gralkor/destination/storage/in_memory.ex; functional: test/functional/destination_graphs_functional_test.exs)

when a Lens saves an episode to the `personal` Destination
  then the resolved graph is named `personal/<operator id>`
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

when personal memory is resolved for an existing identity
  then the identifier is preserved byte for byte in the logical graph name
  and punctuation-sensitive identifiers resolve to distinct physical graphs

if a caller resolves a stale Destination named operator
  then resolution raises a migration error before it can become a shared operator graph

if a caller supplies a blank identity or a resolved private graph in place of an identity
  then personal graph resolution fails before any storage request
