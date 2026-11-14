Functional: destination-search (src: lib/gralkor/graphiti_pool.ex, lib/gralkor/search.ex, lib/gralkor/client.ex, lib/gralkor/application.ex, lib/gralkor/destination/storage.ex, lib/gralkor/destination/storage/graphiti.ex, lib/gralkor/destination/storage/in_memory.ex, lib/jido_gralkor/runtime.ex; functional: test/functional/destination_search_functional_test.exs)

when a caller searches memory
  then every distinct selected Destination is searched concurrently
  and the search returns one result per selected Destination in the selected Destination order
  and every Destination result names its Destination
  and every Destination result carries its relevant facts, its relevant nodes, and its relevant episodes together
  and facts, nodes, and episodes each keep relevance order within their Destination

  and each Destination contributes at most fifty facts, twenty nodes, and fifteen episodes

  where the Destination selector is omitted or empty
    then every accessible registered Destination is selected
    and results follow the order `personal`, `global`, then application Destinations
    and including or excluding a Lens writer does not narrow the search to that Lens's Destination

  where one or more Destinations are supplied
    then results from any supplied Destination can contribute
    but no result from another Destination can contribute
    and including a Lens writer does not add that Lens's Destination to the supplied Destinations

  where no writer is included or excluded
    then results from every writer can contribute

  where one or more writers are included
    then only episodes written by an included writer are returned
    and only facts drawn from an episode written by an included writer are returned
    and only entities mentioned by an episode written by an included writer are returned
    and results from other writers cannot consume any per-Destination limit
    and each returned fact's sources name only included writers
    and entity and edge type filters further restrict the included writers' results
    and a writer included more than once is applied once
    while the search is made through an agent's runtime
      then the Lenses that included writers name resolve from that runtime's configuration

  where one or more writers are excluded
    then no episode written by an excluded writer is returned
    and no fact drawn only from episodes written by excluded writers is returned
    and no entity mentioned only by episodes written by excluded writers is returned
    but a fact also drawn from an episode by a writer that is not excluded is returned
    and an entity also mentioned by an episode by a writer that is not excluded is returned
    and excluded results cannot consume any per-Destination limit
    and each returned fact's sources name no excluded writer
    and entity and edge type filters further restrict the remaining results
    and each excluded Lens writer's Destination is still searched
    and a writer excluded more than once is applied once
    where writers are also included
      then a result is returned only when an included writer produced it and a writer that is not excluded produced it
    while the search is made through an agent's runtime
      then the Lenses that excluded writers name resolve from that runtime's configuration

  where one or more writers are included or excluded
    then the search takes about as long as an unfiltered search of the same Destinations, however many results those writers produced

  where no earliest creation time is supplied
    then results created at any time can contribute

  where an earliest creation time is supplied
    then only episodes created at or after that time are returned
    and only facts created at or after that time are returned
    and only entities created at or after that time are returned
    and results created earlier than that time cannot consume any per-Destination limit
    and entity and edge type filters further restrict the remaining results
    and included and excluded writers further restrict the remaining results

when a search names a writer
  then `lens:<name>` names the Lens of that name
  and `reflection:<name>` names the Reflection of that name, whose output is stored in memory
  and `direct` names direct memory addition and conversations captured before 18.0.0
  and `unknown` names memory whose writer could not be determined
  and `lens:*` names every Lens
  and `reflection:*` names every Reflection

when memory is written to a Destination
  then each episode is written by exactly one writer: the Lens it was ingested through, the Reflection whose output it stores, or direct addition
  and each fact is produced by the writer of every episode it was drawn from
  and each entity is produced by the writer of every episode that mentions it

while a Destination holds memory written before its writers were recorded
  when that Destination is first searched or written
    then each of its episodes, facts, and entities is produced by the writers its episodes' provenance records
    and an episode whose writer cannot be determined is written by `unknown`
    and later searches by writer return that memory as they return memory written since

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

if a selected Destination search exits instead of returning
  then the search returns an error naming that Destination and its exit reason
  and the caller does not exit

if search supplies a field removed in 12.0.0 or 17.0.0
  then search fails before any Destination query is started
  and the error names the removed field
  and the error gives migration guidance for that field

if search supplies a Destination selection that is not a list of registered non-blank names
  then search fails before any Destination query is started
  and no valid subset is searched
  and the error identifies the rejected Destination selection and its rejected value

if search includes or excludes anything but `direct`, `unknown`, `lens:*`, `reflection:*`, `lens:` naming a registered Lens, or `reflection:` with a non-blank name
  then search fails before any Destination query is started
  and no valid subset is searched
  and the error says whether the rejected writer was included or excluded
  and the error identifies the rejected value

if search supplies an earliest creation time that is not a date and time with a time zone
  then search fails before any Destination query is started
  and the error identifies the rejected earliest creation time and its rejected value
