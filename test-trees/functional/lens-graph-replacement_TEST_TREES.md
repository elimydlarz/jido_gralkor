Functional: lens-graph-replacement (functional: test/functional/lens_graph_replacement_functional_test.exs)

when a caller replaces the complete graph through a replaceable Lens
  then the Lens's Destination identifies the graph used by existing Lens operations
  and every node and relationship previously written by that Lens at the resolved destination is removed
  and every supplied node and relationship is inserted at the resolved destination with every non-reserved graph value unchanged
  and every inserted node and relationship carries the reserved Lens ownership field set to the selected Lens name
  and nodes and relationships owned by another Lens at the resolved destination remain unchanged
  and information saved through Reflections at the resolved destination remains unchanged
  and nodes and relationships without the reserved Lens ownership field at the resolved destination remain unchanged
  and the caller observes whether replacement succeeded or failed

where the selected Lens uses the `property_graph` format
  then every supplied node carries a unique identifier, labels, and properties
  and every supplied relationship carries source and destination node identifiers, a type, and properties

if a `property_graph` payload is malformed or names a missing relationship endpoint
  then replacement fails before graph content is removed or inserted
  and the error identifies the invalid graph data

where the supplied complete graph is empty
  then every node and relationship previously written by that Lens at the resolved destination is removed
  and no replacement node or relationship is inserted

when a Lens graph is replaced more than once
  then only the most recently supplied complete graph remains owned by that Lens at the resolved destination

if replacement selects an invalid Lens
  then replacement fails before graph content is removed or inserted

if replacement selects an appending Lens
  then replacement fails with an error identifying that the Lens accepts only episode ingestion
  and no existing graph content is removed or inserted

if the supplied graph format differs from the selected Lens's configured graph format
  then replacement fails before graph content is removed or inserted
  and the error identifies the expected and supplied graph formats

if the supplied complete graph cannot be imported
  then the import failure is returned to the caller
  and graph content already removed by the replacement is not restored

when a caller searches the Destination used by a replaceable Lens
  then Destination search resolves and searches that Destination's graph
