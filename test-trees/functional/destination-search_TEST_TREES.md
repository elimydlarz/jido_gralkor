Functional: destination-search (src: none; functional: none)

when a caller searches memory naming one or more Destinations
  then every distinct Destination is searched concurrently
  and results retain the requested Destination order
  and every result identifies its Destination
  and the same maximum result count applies independently to every Destination
  and no unselected Destination or another operator's local placement can contribute a result

where the same Destination is selected more than once
  then that Destination is searched only once

where no Destination is supplied
  then the requesting operator's packaged default Destination is searched

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
