Functional: jido-public-memory-capabilities (src: lib/jido_gralkor/lifecycle.ex, lib/jido_gralkor/plugin.ex, lib/jido_gralkor/actions/memory_add.ex, lib/jido_gralkor/actions/memory_build_indices.ex, lib/jido_gralkor/actions/memory_build_communities.ex, lib/jido_gralkor/actions/memory_search.ex, lib/jido_gralkor/re_act.ex, lib/gralkor/client.ex, lib/gralkor/search.ex; functional: test/functional/jido_public_memory_capabilities_functional_test.exs)

when an application gracefully stops an agent with a committed thread
  then termination returns without waiting for the memory flush
  and the configured memory client flushes the committed thread

when an operator runs the build-indices memory action
  then the action reports the backend status
  and the backend receives one unscoped index build
  and a backend failure is returned unchanged

when an operator runs the build-communities memory action
  then the action reports the backend counts
  and the backend receives one build for the graph named `operator/<operator id>`
  and a backend failure is returned unchanged

when an agent invokes memory addition and its background write fails
  then the background failure is logged
  and the agent's immediate acknowledgement remains unchanged

when an agent invokes memory search with a usable query
  then returned results are scoped to the current operator
  and the usable query selects relevant stored episodes
  and returned results obey the optional `destinations` and `lenses` selectors supplied for that invocation
  and the action returns results as JSON with their Destination and originating Lens or declaring Reflection
  and relevant stored generalisations can contribute beside related ingested information
  and each returned generalisation exposes its exact content, evolution-depth level, and `evolves_from` history
  where both selectors are omitted or empty
    then every accessible registered Destination can contribute
  where only Destinations are supplied
    then only results from any supplied Destination can contribute
  where only Lenses are supplied
    then only results originating in any supplied Lens can contribute
  where Destinations and Lenses are supplied
    then only results matching both selections can contribute
  where no conversation thread has been committed
    then search still runs for the current operator
  if Search fails
    then the failure is returned unchanged

when a fresh agent handles a request related to an evolved generalisation
  then the answer identifies the retrieved deployment predecessor and newly covered feature-release scope
  and the recommendation applies their reversible limited-scope lesson to the requested migration

when an agent receives the memory search tool
  then its description directs the agent to search related observations and generalisations
  and its description directs the agent to apply relevant generalisations in light of their evolution histories and related observations

if an agent invokes memory search without a usable query
  then no Search is issued
  and the agent receives an explicit non-result

when a mounted plugin completes a memory-worthy turn with a committed thread
  if agent state has no non-blank user name
    then completion raises an ArgumentError naming the missing user name
  if capture fails
    then completion raises reporting the capture failure

when a consumer prepares the first ReAct iteration
  then memory search is forced
  and every existing request override is preserved

when a consumer prepares a later ReAct iteration
  then every request override is returned unchanged
