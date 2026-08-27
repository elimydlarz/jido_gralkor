Unit: graphiti-pool (src: lib/gralkor/graphiti_pool.ex; integration: test/gralkor/graphiti_pool_test.exs; unit: test/gralkor/graphiti_pool_test.exs)

when the graph library needs inference
  then its own provider client issues the call

when the pool starts
  then the shared asyncio runtime is installed, so the pool can be started on its own
  and the LLM client, the embedder, and the cross-encoder are each constructed once and shared by every graph instance for the pool's lifetime
  while both configured model specs name a supported inference provider
    then client construction proceeds using the configured model ids
    and the LLM client is built for the provider the LLM spec names
    and the embedder is built for the provider the embedder spec names
    and the cross-encoder is built for the provider the LLM spec names
    and each provider credential is passed explicitly from the BEAM side
      where the credential exists only in the BEAM environment
        then the credential still reaches the provider client
    while the embedder spec names Google
      then the embedder sends one input per request
    while the two specs name different providers
      then each client is still built for its own role's provider
      and startup completes
  while an embedded connection is configured
    then stale embedded resume state is removed before database construction
    and the embedded database is constructed once and held for the pool's lifetime
  while a remote connection is configured
    then the remote database is constructed once and held for the pool's lifetime

if either configured model spec names a provider that is neither OpenAI nor Google
  then startup raises before any inference client is constructed
  and the failure names both configured model specs
  and the failure names the providers that are supported

if the credential for a provider named by a configured model spec is absent or blank
  then startup raises before any inference client is constructed
  and the failure names the absent credential
  and the failure names the role whose spec required it

where a provider is named by neither configured model spec
  then its absent credential does not prevent startup

when the pool has constructed its database
  then a warmup search runs once against a throwaway query and group, paying the cold-start cost before any consumer can recall
  and a single line reporting the search and total warmup durations is logged
  if a warmup call raises or returns an error
    then the failure is logged as non-fatal, naming the stage and the reason
    and startup completes anyway

when the pool terminates
  then the database it held for its lifetime is closed through the shared asyncio runtime
  while a remote connection is configured
    then the remote database client is closed before termination completes
  while an embedded connection is configured
    then the owned embedded server exits before termination completes
    and finalising the async wrapper emits no unawaited-coroutine warning

when a graph instance is requested for a group
  then the instance is looked up from a cache shared across callers
  while instances are already cached for their groups
    then concurrent callers read those instances in parallel without passing through the pool process
  while no instance is cached for that group
    then the instance is constructed, cached, and held for the pool's lifetime
    and index and constraint building is invoked before the instance is cached and returned
    while construction takes longer than the default call timeout
      then construction still runs to completion
    if index and constraint building fails
      then the failure is non-fatal
      and the instance is still cached and returned

when an episode is added
  then its name combines the current millisecond timestamp with a positive monotonic unique integer, so concurrent writes remain distinguishable without claiming an episode UUID
  while an embedded connection is configured
    while another episode addition is in progress
      then the graph library receives the episode only after the in-progress addition finishes
  while no ontology is supplied
    then the graph library receives no entity types, edge types, edge type map, or excluded entity types
  while an ontology module is supplied
    then that ontology is translated into the graph library's schema representation on first encounter
    and a later add with the same ontology reuses the translated representation rather than rebuilding it
    and the translated entity types, edge types, edge type map, and excluded entity types are forwarded to the graph library
    and the forwarded dictionary carries exactly the keys the ontology selects, omitting the rest
    and the forwarded dictionary uses the graph library's key names outside and the ontology's declared type names inside
  while an episode identifier is supplied
    then that identifier is forwarded to the graph library, so re-adding under it updates the episode by re-extraction
  where a supported source kind is supplied
    then conversation, document, and structured-record sources reach the graph library as message, text, and JSON episodes respectively
    and the existing episode extraction is instructed to preserve source attribution and epistemic wording
    and no separate presentation-classification operation is invoked

if adding an episode raises inside the graph library
  then an error carrying only the raised exception's class and message is returned
  and the logged diagnostic is a single concise line, so neither the full traceback nor an embedding vector is written to the log
  if the raised exception carries no detail
    then the returned reason falls back to a message stating that a Python exception was raised with no detail available

when an episode is removed
  then the graph library deletes that episode along with the nodes and edges it orphans

if removing an episode raises inside the graph library
  then an error carrying only the raised exception's class and message is returned
  and the logged diagnostic is a single concise line rather than a full traceback

when a complete property graph replaces content owned by a Lens in a group
  then every relationship carrying that Lens's reserved ownership field is removed before owned nodes are removed
  and every node carrying that Lens's reserved ownership field is removed
  and each supplied node is inserted with its identifier, labels, properties, and reserved Lens ownership field
  and each supplied relationship is inserted between its identified endpoints with its type, properties, and reserved Lens ownership field
  and every supplied string property crosses the native graph boundary as text without changing its value
  and nodes and relationships owned by another Lens remain unchanged
  and nodes and relationships without the reserved Lens ownership field remain unchanged
  and success is returned after every supplied node and relationship is inserted

where the supplied complete property graph is empty
  then every node and relationship owned by the Lens is removed
  and no node or relationship insertion is attempted

if removing Lens-owned graph content fails
  then the graph failure is returned
  and no supplied node or relationship is inserted

if inserting a supplied node fails
  then the graph failure is returned
  and no supplied relationship is inserted
  and removed Lens-owned content is not restored

if inserting a supplied relationship fails
  then the graph failure is returned
  and removed Lens-owned content and inserted nodes are not restored

when a fact search is run for a group
  then the graph library's edge search is invoked with the requested result count
  where edge types are supplied
    then the graph library's edge search is restricted to those ontology relationship types
  and each returned edge is rendered as a fact carrying its text and its created, valid, invalid, and expired timestamps
  and each returned edge identifies its originating episodes by identifier, source kind, and source description
  and a standalone custom-entity node cannot be returned, because edge search matches edges by their endpoints

if running a fact search raises inside the graph library
  then an error carrying the raised exception is returned

when an episode search is run for a group
  then the graph library is asked for episodes only, with the requested result count
  and it is restricted to the sanitised group id the episodes were written under
  and each returned episode is rendered with the body that was written and its source description
  and nothing an extractor derived from the episode is involved, so an episode no entity was extracted from is still returned

if running an episode search raises inside the graph library
  then an error carrying the raised exception is returned

when a node search is run for a group
  then it is restricted to the sanitised group id the episodes were written under, so a group id carrying hyphens still matches
  while node labels are supplied
    then the graph library's node search is invoked with the requested result count and a filter carrying those labels
    and each returned node is rendered with its name, summary, and attributes, ordered by relevance
  while no node labels are supplied
    then the graph library's node search is invoked with every node eligible

if running a node search raises inside the graph library
  then an error carrying the raised exception is returned

when an index and constraint rebuild is requested for the whole graph
  then every group the pool holds an instance for is rebuilt, each group being its own database
  and a group whose instance has never been created is left alone, its indices being built the moment it is

when community building is requested for a group
  then the group is sanitised before its graph instance is selected
  and the graph library builds communities for that sanitised group's instance
  and the returned community and edge counts are reported

if community building raises inside the graph library
  then an error carrying the raised exception is returned
