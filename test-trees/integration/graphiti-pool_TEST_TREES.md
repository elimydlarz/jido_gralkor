Integration: graphiti-pool (src: lib/gralkor/graphiti_pool.ex; integration: test/gralkor/graphiti_pool_test.exs)

when the graph library needs inference
  then its own provider client issues the call

when the pool starts
  then the shared asyncio runtime is installed, so the pool can be started on its own
  and the LLM client, the embedder, and the cross-encoder are each constructed once and shared by every graph instance for the pool's lifetime
  and the graph library's node and edge filter constructors and episode full-text search are wrapped once, before any search
  while every configured model spec names a supported inference provider
    then client construction proceeds using the configured model ids
    and the LLM client is built for the provider the LLM spec names
    and the embedder is built for the provider the embedder spec names
    and each provider credential is passed explicitly from the BEAM side
    where the credential exists only in the BEAM environment
      then the BEAM-side credential lookup returns the configured value
      and the embedded Python environment cannot read that BEAM-only value directly
    while LLM routes are configured
      then graph instances receive an LLM runtime whose default model is the LLM spec's
      and each routed group or prompt runs on its route's model
      and routes sharing a provider and tuning share one client
      and a route's tuning applies only to the prompts it routes
    while no LLM routes are configured
      then graph instances receive the LLM client without an LLM runtime
    while a reranker model is configured
      then the cross-encoder is built for the provider and model it names
    while no reranker model is configured
      then the cross-encoder is built for the LLM's provider with the graph library's default reranker model
    while an LLM tuning setting is configured
      then the LLM spec's client receives it
    while no LLM tuning setting is configured
      then the LLM spec's client receives the graph library's default for it
    while an embedder dimension is configured
      then the embedder is configured with that dimension
    while the embedder spec names Google
      while no embedder batch size is configured
        then the embedder sends one input per request
      while an embedder batch size is configured
        then the embedder sends at most that many inputs per request
    while the role specs name different providers
      then each client is still built for its own role's provider
      and startup completes
  while an embedded connection is configured
    then stale embedded resume state is removed before database construction
    and an absent data directory is created before database construction
    and the embedded database is constructed once and held for the pool's lifetime
  while a remote connection is configured
    then the remote database is constructed once and held for the pool's lifetime

if a graph library function the pool wraps is missing or has another signature
  then startup raises naming that function and the pinned graph library version

if any configured model spec names a provider that is neither OpenAI nor Google
  then startup raises before any inference client is constructed
  and the failure names every configured model spec
  and the failure names the providers that are supported

if a tuning setting is configured for a model whose provider does not accept it
  then startup raises before any inference client is constructed
  and the failure names the setting and the model's provider

if the credential for a provider named by a configured model spec is absent or blank
  then startup raises before any inference client is constructed
  and the failure names the absent credential
  and the failure names the role whose spec required it

where a provider is named by no configured model spec
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
  then the instance is looked up from a cache shared across callers by the collision-free physical identifier encoded at this boundary
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
      if the in-progress addition's caller exits
        then the next waiting addition proceeds
  while no ontology is supplied
    then the graph library receives no entity types, edge types, edge type map, or excluded entity types
  while an ontology module is supplied
    then that ontology is translated into the graph library's schema representation on first encounter
    and a later add with the same ontology reuses the translated representation rather than rebuilding it
    and the translated entity types, edge types, edge type map, and excluded entity types are forwarded to the graph library
    and the forwarded dictionary carries exactly the keys the ontology selects, omitting the rest
    and the forwarded dictionary uses the graph library's key names outside and the ontology's declared type names inside
  where a supported source kind is supplied
    then conversation, document, and structured-record sources reach the graph library as message, text, and JSON episodes respectively
    and the existing episode extraction is instructed to preserve source attribution and epistemic wording
    and no separate presentation-classification operation is invoked
  while an episode identifier is supplied
    then concurrent writes carrying the same identifier are serialised even when other remote writes remain concurrent
    when that identifier does not exist
      then one episode is created under that identifier through the normal extraction path
      and durable extraction completion is recorded after the normal path succeeds
    when that identifier exists with equal immutable episode content
      while durable extraction completion is recorded
        then the add succeeds without invoking extraction again
      while durable extraction completion is absent
        then the normal extraction path runs again
        and durable extraction completion is recorded after it succeeds
    when that identifier exists with conflicting immutable episode content
      then the add returns an episode conflict and leaves the original unchanged

when one episode is requested by exact identifier
  then the matching episode content and immutable source fields are returned
  and the result identifies whether durable extraction completion is recorded
  while that identifier is absent
    then lookup reports not found

if adding an episode raises inside the graph library
  then the logged diagnostic is a single concise line, so neither the full traceback nor an embedding vector is written to the log
  while the exception is an inference provider's rate limit
    then an upstream rate-limit failure carrying the exception's class and message is returned
  while the exception is any other inference provider failure
    then an upstream provider failure carrying the exception's class and message is returned
  while the exception is not an inference provider failure
    then an error carrying only the raised exception's class and message is returned
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
  and each returned edge is rendered as a fact carrying its text and its created, valid, invalid, and expired timestamps
  and each returned edge identifies its originating episodes by identifier, source kind, and source description
  and each returned edge is rendered with its relationship name and the name and identifier of its source and target entities
  and a standalone custom-entity node cannot be returned, because edge search matches edges by their endpoints
  where edge types are supplied
    then the graph library's edge search is restricted to those ontology relationship types

if running a fact search raises inside the graph library
  then an error carrying the raised exception is returned

when a memory search is run for a group
  then the graph library is searched once for edges, nodes, and episodes together
  and edges and nodes are each ranked by reciprocal rank fusion of full-text and similarity search, and episodes by full-text search
  and the graph library is asked for as many results of each kind as the largest requested kind limit
  and it searches only the database of that group, whatever group id each record stores
  and each returned edge is rendered as a fact carrying its text, its created, valid, invalid, and expired timestamps, and its originating episodes by identifier, source kind, and source description
  and each returned edge is rendered with its relationship name and the name and identifier of its source and target entities
  and each returned node is rendered with its name, summary, and attributes
  and each returned episode is rendered with the body that was written, its source description, and its source kind
  and facts, nodes, and episodes are each returned in the graph library's relevance order and cut to their own requested limit
  and nothing an extractor derived from an episode is needed to return it, so an episode no entity was extracted from is still returned
  while node labels are supplied
    then the single search's filter carries those labels
    while several node labels are supplied
      then the graph library's node filter admits a node carrying any one of them
      and its edge filter admits an edge whose source and target each carry any one of them
  while edge types are supplied
    then the single search's filter carries those relationship types
  while neither node labels, edge types, nor Lenses are supplied
    then the single search's filter leaves every node and edge eligible
    and the graph library's own node and episode queries are issued unchanged
  while Lenses are supplied
    then the single search's filter admits only edges drawn from an episode whose source description names a supplied Lens or owned by a supplied Lens's graph replacement
    and the single search's filter admits only nodes mentioned by such an episode or owned by such a replacement
    and the single search's filter admits only episodes whose source description names a supplied Lens
    and the episode restriction is applied inside the full-text query, before its limit
    and each rendered fact's sources include only episodes whose source description names a supplied Lens
    while nothing in the group was written by a supplied Lens
      then the graph library is not searched
      and no facts, nodes, or episodes are returned
  when the query exceeds the graph library's full-text limit
    then the graph library receives a bounded non-empty query containing the earliest supported terms
  when a returned Reflection episode lacks its durable extraction-completion marker
    then that episode is excluded before the episode limit is applied

if running a memory search raises inside the graph library
  then an error carrying the raised exception is returned

when an index and constraint rebuild is requested for the whole graph
  then every group the pool holds an instance for is rebuilt, each group being its own database
  and a group whose instance has never been created is left alone, its indices being built the moment it is

when community building is requested for a group
  then the logical group is physically encoded before its graph instance is selected
  and the graph library builds communities for that physical group's instance
  and the returned community and edge counts are reported

if community building raises inside the graph library
  then an error carrying the raised exception is returned
