Functional: jido-public-memory-capabilities (src: lib/jido_gralkor/lifecycle.ex, lib/jido_gralkor/plugin.ex, lib/jido_gralkor/actions/memory_add.ex, lib/jido_gralkor/actions/memory_build_indices.ex, lib/jido_gralkor/actions/memory_build_communities.ex, lib/jido_gralkor/actions/memory_search.ex, lib/jido_gralkor/memory_search_presentation.ex, lib/jido_gralkor/re_act.ex, lib/gralkor/client.ex, lib/gralkor/search.ex; functional: test/functional/jido_public_memory_capabilities_functional_test.exs)

when an application gracefully stops an agent with a committed thread
  then termination returns without waiting for the memory flush
  and the configured memory client flushes the committed thread

when an operator runs the build-indices memory action
  then the action reports the backend status
  and the backend receives one unscoped index build
  and a backend failure is returned unchanged

when an operator runs the build-communities memory action
  then the action reports the backend counts
  and the backend receives one build for the graph named `personal/<operator id>`
  and a backend failure is returned unchanged

when an agent invokes memory addition and its background write fails
  then the background failure is logged
  and the agent's immediate acknowledgement remains unchanged

when an agent invokes memory search with a usable query
  then returned results are scoped to the current operator
  and the usable query is submitted to the one memory search for the current operator
  and returned results obey the optional `destinations` selector supplied for that invocation
  and the action returns one readable string with memories under named Lens or Reflection headings
  and relevant stored generalisations can contribute beside related ingested information
  and the presentation adds no artefact identifiers
  and a generalisation shows its level and each lineage snapshot as its own fields
  where the Destination selector is omitted or empty
    then every accessible registered Destination can contribute
  where Destinations are supplied
    then only results from any supplied Destination can contribute
  where no conversation thread has been committed
    then search still runs for the current operator
  if Search fails
    then the failure is returned unchanged

when a fresh agent handles a request related to an evolved generalisation
  then the provider receives the related observation under its Lens heading
  and the provider receives the evolved reversible limited-scope generalisation under its Reflection heading

when an agent receives the memory search tool
  then its description directs the agent to search related observations and generalisations
  and its description directs the agent to use the returned memories

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

when a consumer explicitly formats structured search results
  then a Lens writer's section has a heading of the form `Lens: <name>`
  and a Reflection writer's section has a heading of the form `Reflection: <name>`
  and each section's text holds bullets containing its writer's returned memory text
  and writer sections retain first-appearance order
  and memories retain retrieval order within each section
  and each searched Destination's entities follow every writer section under `Entities: <Destination>`
  while a fact is returned for several writers
    then the fact appears once in each of their sections
  while a Lens and a Reflection share a name
    then their memories remain in separate sections
  while a writer has no named Lens or Reflection provenance
    then its memories appear under `Source: unknown`
  while a Destination's search returns no entities
    then its Entities section explicitly states that no matching memory was found

when memory search formats memories for the consuming agent
  then every section's text stays within its own character limit
  and no section's text exceeds 16384 characters
  and every included memory retains its complete text
  while Lenses and Reflections in one Destination both wrote matching memory
    then every one of those writers has a section holding its own memories
  while a section's memories cannot all fit within its limit
    then a whole memory is omitted while later fitting memories remain eligible
    and that section reports its own omitted memory count and section-limit reason
    but every other section keeps its memories
  while one memory is longer than 4,000 characters
    then it is cut to 4,000 characters and marked as truncated

when unmodified Jido AI 2.3.0 sends memory search output to the provider
  then one decode of the tool envelope exposes every section's exact heading and readable text returned by the action
  and each section's text contains readable bullets rather than JSON-encoded memories
  while the canonical Reflection payload contains deep lineage or domain keys ending in `_key`
    then the provider receives deep lineage and `_key` fields unchanged
  while every section fits within its limit
    then the provider receives every section's text whole, without a truncation marker
  while a section's memories exceed its limit
    then the provider receives that section's explicit omission notice instead of a sliced memory
