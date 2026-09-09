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
  and the backend receives one build for the graph named `operator/<operator id>`
  and a backend failure is returned unchanged

when an agent invokes memory addition and its background write fails
  then the background failure is logged
  and the agent's immediate acknowledgement remains unchanged

when an agent invokes memory search with a usable query
  then returned results are scoped to the current operator
  and the usable query selects relevant extracted facts
  and returned results obey the optional `destinations` and `lenses` selectors supplied for that invocation
  and the action returns one readable string with fact bullets grouped under named Lens or Reflection headings
  and relevant stored generalisations can contribute beside related ingested information
  and the presentation adds no artefact identifiers, evolution-depth levels, or lineage metadata
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
  then the answer uses the retrieved facts relevant to the requested migration
  and the recommendation applies the retrieved reversible limited-scope lesson to the requested migration

when an agent receives the memory search tool
  then its description directs the agent to search related observations and generalisations
  and its description directs the agent to use the returned source-grouped facts

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

when a consumer explicitly formats structured fact search results
  then named Lens sources have headings of the form `Lens: <name>`
  and named Reflection sources have headings of the form `Reflection: <name>`
  and each source heading is followed by bullets containing its returned fact text
  and source groups retain first-appearance order
  and facts retain retrieval order within each source group
  and formatting leaves the canonical structured search results unchanged
  while a fact has several named sources
    then the fact appears once under each distinct named source
  while a Lens and a Reflection share a name
    then their facts remain in separate source groups
  while a fact has no named Lens or Reflection provenance
    then the fact appears under `Source: unknown`
  while search returns no facts
    then the text explicitly states that no matching facts were found

when memory search formats facts for the consuming agent
  then the complete text including headings and omission notices stays within 16384 characters
  and the serialized success envelope fits the configured byte budget
  and every included fact retains its complete text
  while a fact cannot fit within the response limits
    then that whole fact is omitted while later fitting facts remain eligible
    and the text reports the omitted fact count and response-limit reason
  while the byte budget cannot hold an empty response with the required notice
    then an explicit budget error is returned
  if the byte budget is not a positive integer
    then the action rejects the budget before searching memory

when unmodified Jido AI 2.3.0 sends memory search output to the provider
  then one decode of the tool envelope exposes the exact readable string returned by the action
  and the tool result contains readable fact bullets rather than a JSON-encoded result list
  while the canonical Reflection payload contains deep lineage or domain keys ending in `_key`
    then the provider receives the retained extracted fact text unchanged
  while more than 100 facts fit within the response limits
    then the provider receives every formatted fact without a synthetic omission item
  while a source fact exceeds the response limits
    then the provider receives an explicit omission notice instead of a sliced fact
