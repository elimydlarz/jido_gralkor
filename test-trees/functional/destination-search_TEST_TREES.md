Functional: destination-search (src: lib/gralkor/search.ex, lib/gralkor/client.ex, lib/gralkor/destination/storage.ex, lib/gralkor/destination/storage/graphiti.ex; functional: test/functional/destination_search_functional_test.exs)

when a caller searches memory naming one or more Destinations
  then every distinct Destination is searched concurrently
  and results retain the requested Destination order
  and every result identifies its Destination
  and the same maximum result count applies independently to every Destination
  and no unselected Destination can contribute a result

where a caller selects a Destination other than `global`
  then another operator's graph cannot contribute a result

where a caller selects the `global` Destination
  then results saved by every operator to the one global graph can contribute

where the same Destination is selected more than once
  then that Destination is searched only once

where no Destination is supplied
  then the packaged operator-memory Destination is searched
  and the packaged `global` Destination is searched

where a caller supplies no maximum result count
  then every resolved Destination receives the default maximum result count of twenty

where a caller selects facts
  then relevant relationships extracted in the selected Destinations are returned

where a caller selects nodes
  then relevant entities extracted in the selected Destinations are returned

where a caller selects episodes
  then relevant episode bodies from the selected Destinations are returned

where a caller selects artefacts
  then relevant Reflection artefacts from the selected Destinations are returned
  and every artefact identifies its declaring Reflection

where a caller filters nodes by entity type
  then only nodes carrying a selected ontology label are returned

where a caller filters facts by edge type
  then only facts carrying a selected ontology relationship type are returned

if a selected Destination search fails
  then the error is returned without manufacturing a partial memory response

if search supplies a maximum result count that is not a positive integer
  then search fails before any Destination query is started
  and the error identifies the invalid maximum result count

if search supplies an unsupported result type
  then search fails before any Destination query is started
  and the error identifies the unsupported result type

if search names a Destination that is not registered or packaged
  then search fails before any Destination query is started
  and no valid subset is searched
  and the error identifies the unknown Destination
