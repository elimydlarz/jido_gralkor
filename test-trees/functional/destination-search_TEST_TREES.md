Functional: destination-search (src: lib/gralkor/search.ex, lib/gralkor/client.ex, lib/gralkor/destination/storage.ex, lib/gralkor/destination/storage/graphiti.ex, lib/gralkor/destination/storage/in_memory.ex; functional: test/functional/destination_search_functional_test.exs)

when a caller searches memory
  then every distinct selected Destination is searched concurrently
  and results retain the selected Destination order
  and every result identifies its Destination
  and the same maximum result count applies independently to every Destination
  and unselected writers cannot consume the result allowance for selected-Lens results

  where the Destination selector is omitted or empty
  and the Lens selector is omitted or empty
    then every accessible registered Destination is selected
    and results written by every Lens or Reflection can contribute

  where one or more Destinations are supplied
    while the Lens selector is omitted or empty
      then results from any supplied Destination can contribute
      but no result from another Destination can contribute

  where one or more Lenses are supplied
    while the Destination selector is omitted or empty
      then every accessible registered Destination is selected
      and results originating in any supplied Lens can contribute
      but no result from another Lens or from a Reflection can contribute

  where one or more Destinations are supplied
  and one or more Lenses are supplied
    then only results whose Destination matches any supplied Destination and whose originating Lens matches any supplied Lens can contribute
    and selecting a Lens does not add that Lens's Destination to the supplied Destinations

where the selected Destinations include `operator`
  then only the current operator's `operator/<operator id>` graph is searched
  and another operator's graph cannot contribute a result

where the selected Destinations include any shared Destination
  then results saved by every operator to that Destination's one graph can contribute

where the same Destination is selected more than once
  then that Destination is searched only once

where the same Lens is selected more than once
  then that Lens contributes no duplicate result

where a caller supplies no maximum result count
  then every resolved Destination receives the default maximum result count of twenty

when a caller omits the result type or explicitly selects episodes
  then relevant stored episode content is returned
  and every episode written through a Lens identifies that originating Lens
  and every episode written through a Reflection identifies only its declaring Reflection as its writer

where a caller explicitly selects facts
  then relevant relationships extracted in the selected Destinations are returned

where a caller explicitly selects nodes
  then relevant entities extracted in the selected Destinations are returned

where a caller explicitly selects artefacts
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

if search combines one or more Lenses with a non-episode result type
  then search fails before any Destination query is started
  and the error identifies that Lens selection requires episode results

if search supplies any Destination or Lens selection that is not a list of registered non-blank names
  then search fails before any Destination query is started
  and no valid subset is searched
  and the error identifies whether the rejected selection was for Destinations or Lenses
  and the error identifies the rejected value
