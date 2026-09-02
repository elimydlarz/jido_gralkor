Unit: memory-search-action (src: lib/jido_gralkor/actions/memory_search.ex; unit: test/jido_gralkor/actions/memory_search_test.exs)

when the memory search tool runs with a usable query
  then the existing public Search capability is invoked once
  and the Search request carries the current operator
  and the Search request carries the usable query unchanged
  and the Search request asks for stored episodes
  where the tool call supplies no Destination selector
  and the tool call supplies no Lens selector
    then the Search request leaves both selector dimensions unrestricted
  where the tool call supplies Destinations
    then the Search request carries the same Destination list
  where the tool call supplies Lenses
    then the Search request carries the same Lens list
  where the tool call supplies Destinations and Lenses
    then the Search request carries both lists unchanged
  while Search returns results
    then the action result is their JSON encoding
    and every returned episode's Destination, originating Lens, or artefact identifier remains identifiable
  if Search fails
    then the failure reason is returned to the caller unchanged

when a consumer reads the memory search tool description
  then it directs the agent to search related observations and generalisations
  and it directs the agent to apply relevant generalisations in light of their evolution histories and related observations

if the memory search tool runs without a usable query
  then no Search is issued
  and the result explicitly states that no query was provided
  and the result explicitly states that it is a non-result
  and a warning naming the short-circuit is logged
  while the query is only whitespace
    then it counts as no query
