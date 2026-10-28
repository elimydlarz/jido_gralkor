Functional: destination-search (src: lib/gralkor/graphiti_pool.ex, lib/gralkor/search.ex, lib/gralkor/client.ex, lib/gralkor/destination/storage.ex, lib/gralkor/destination/storage/graphiti.ex, lib/gralkor/destination/storage/in_memory.ex; functional: test/functional/destination_search_functional_test.exs)

when a caller searches memory
  then every distinct selected Destination is searched concurrently
  and the search returns one result per selected Destination in the selected Destination order
  and every Destination result names its Destination
  and every Destination result carries its relevant facts, its relevant nodes, and its relevant episodes together
  and each Destination contributes at most twenty facts, twenty nodes, and five episodes
  and facts, nodes, and episodes each keep relevance order within their Destination

  where the Destination selector is omitted or empty
    then every accessible registered Destination is selected
    and results written directly or by every Lens or Destination artefact output can contribute

  where one or more Destinations are supplied
    then results from any supplied Destination can contribute
    but no result from another Destination can contribute

where the selected Destinations include `personal`
  then only the current operator's `personal/<operator id>` graph is searched
  and another operator's graph cannot contribute a result

where the selected Destinations include any shared Destination
  then results saved by every operator to that Destination's one graph can contribute

where the same Destination is selected more than once
  then that Destination is searched only once

when a Destination result carries episodes
  then relevant stored episode content is returned
  and every episode written through a Lens identifies that originating Lens
  and every directly written episode retains content and source kind without Lens or Reflection authorship
  and historical unmarked episodes remain available without invented authorship
  and historical operator-labelled episodes retain their recorded Lens provenance
  and Lens source descriptions and naturally textual content remain unchanged
  and every episode written through a Destination artefact output exposes its stable artefact identifier and payload as structured fields
  and a search for one word of an artefact's payload returns that artefact from a Graphiti Destination

when a Destination result carries facts
  then relevant relationships extracted in that Destination are returned as structured fact records
  and each fact retains originating episode identifiers, source kinds, and source descriptions
  and named Lens or Reflection provenance is exposed on each attributable fact source
  and every fact names its relationship
  and every fact identifies its source entity by name and identifier
  and every fact identifies its target entity by name and identifier
  and a fact written by a graph replacement is returned by a search for one of its words

when a Destination result carries nodes
  then relevant entities extracted in that Destination are returned

where a caller filters by entity type
  then only nodes carrying a selected ontology label are returned
  and only facts whose source and target entities both carry a selected ontology label are returned
  but episodes are not restricted by entity type

where a caller filters by edge type
  then only facts carrying a selected ontology relationship type are returned
  but nodes and episodes are not restricted by relationship type

if a selected Destination search fails
  then the error is returned without manufacturing a partial memory response

if search supplies a field removed in 12.0.0
  then search fails before any Destination query is started
  and the error names the removed field
  and the error gives migration guidance for that field

if search supplies any Destination selection that is not a list of registered non-blank names
  then search fails before any Destination query is started
  and no valid subset is searched
  and the error identifies the rejected Destination selection
  and the error identifies the rejected value
