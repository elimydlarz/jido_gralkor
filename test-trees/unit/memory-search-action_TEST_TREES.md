Unit: memory-search-action (src: lib/jido_gralkor/actions/memory_search.ex; unit: test/jido_gralkor/actions/memory_search_test.exs)

when the memory search tool runs with a query and a committed session
  then the operator's sanitised group id, the agent name, and the session id from the tool context are passed to the memory backend with the query
  while the backend returns a memory block
    then the action result carries that block
  if the backend fails
    then the failure reason is returned to the caller unchanged
  where the tool context selects Lenses to search
    then the Lens search is used in place of the legacy recall
    and the operator's reserved `operator` Lens is searched alongside every selected Lens
    and the action result is JSON identifying the searched Lens that contributed every fact
    if a Lens backend fails
      then the failure reason is returned to the caller unchanged

if the memory search tool runs without a usable query
  then no search is issued against any backend
  and the result explicitly states that no query was provided
  and the result explicitly states that it is a non-result
  and a warning naming the short-circuit is logged
  while the query is only whitespace
    then it counts as no query

if the memory search tool runs with no usable session id in its tool context
  then no search is issued against any backend
  and the result explicitly states that long-term memory was not queried
  and the result explicitly states that it is a non-result
  and a warning naming the operator is logged
  while the session id is only whitespace
    then it counts as no session id
