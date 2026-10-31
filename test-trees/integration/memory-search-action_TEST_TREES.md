Integration: memory-search-action (src: lib/jido_gralkor/actions/memory_search.ex; integration: test/jido_gralkor/actions/memory_search_test.exs)

when the memory search tool runs with a usable query
  then the existing public Search capability is invoked once
  and the Search request carries the current operator
  and the Search request carries the usable query unchanged
  and the Search request carries no entity or relationship type filter
  where the tool call supplies no Destination selector
    then the Search request leaves the Destination selector unrestricted
  where the tool call supplies Destinations
    then the Search request carries the same Destination list
  while the tool context identifies an owning AgentServer as the Gralkor runtime target
    then Search receives that owning AgentServer as its runtime target
  while the tool context has no Gralkor runtime target
    then Search uses the untargeted application compatibility boundary
  while Search returns results
    then the action result is readable text with memories under their writers and entities last
    and each named originating Lens or Reflection is identified by its source heading
    while the tool context supplies no byte budget
      then the response fits within 65,536 bytes
  if Search fails
    then the failure reason is returned to the caller unchanged

when a consumer reads the memory search tool description
  then it directs the agent to search related observations and generalisations
  and it directs the agent to use the returned memories
  and it offers a Destination selector but no Lens selector

if the memory search tool runs without a usable query
  then no Search is issued
  and the result explicitly states that no query was provided
  and the result explicitly states that it is a non-result
  and a warning naming the short-circuit is logged
  while the query is only whitespace
    then it counts as no query
