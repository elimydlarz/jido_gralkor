Integration: graphiti-pool (src: lib/gralkor/graphiti_pool.ex; integration: test/gralkor/graphiti_pool_test.exs)

when the graph library needs inference
  then its own provider client issues the call

when the pool starts
  then the shared asyncio runtime is installed, so the pool can be started on its own
  and the LLM client, the embedder, and the cross-encoder are each constructed once and shared by every graph instance for the pool's lifetime
  and the graph library's node and edge filter constructors, its fact similarity search, its entity similarity search both where searching calls it and where adding an episode calls it to find an extracted entity's possible duplicates, its episode full-text search, and its fact and entity result columns are wrapped once, before any search
  and the graph library's reading of facts by identifier, its loading of a fact's embedding, and its deletion of relationships by identifier are wrapped once, before any graph operation
  and the graph client's query is wrapped once, before any search, so a search can give its queries a query timeout
  and the graph library's FalkorDB index building is wrapped once, before any graph instance is built
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
  and the episode records its one writer: its Lens, the Reflection its source description names, direct, or `unknown`
  and every fact and entity the write touched records the writers of every episode it was drawn from or that mentions it, keeping writers recorded earlier
  and no query the write sends carries a query timeout
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
    where an entity field declares a maximum length
      then the graph library is given that maximum length for the field
      and the schema the model fills for extraction carries no length limit for the field
      and the graph library keeps a value longer than its default limit but within the declared length
      and the graph library drops a value longer than the declared length
      and the field keeps its earlier value
    where an edge property declares a maximum length
      then the graph library is given that maximum length for the property
      and the graph library keeps a value longer than its default limit but within the declared length
      and the graph library drops a value longer than the declared length
      and the property keeps its earlier value
    where an optional string field declares no maximum length
      then the graph library drops a value longer than its default limit
  where a supported source kind is supplied
    then conversation, document, and structured-record sources reach the graph library as message, text, and JSON episodes respectively
    and the existing episode extraction is instructed to preserve source attribution and epistemic wording
    and no separate presentation-classification operation is invoked
  while an episode identifier is supplied
    then concurrent writes carrying the same identifier are serialised even when other remote writes remain concurrent
    and writers are recorded only after durable extraction completion is recorded under the current claim
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

when the graph library reads facts by identifier, loads a fact's embedding, or deletes relationships by identifier on FalkorDB
  then it finds them through the identifier index, without reading every entity
  and it reads, loads, or deletes exactly what the graph library's own query does

when a fact search is run for a group
  then the graph library's edge search is invoked with the requested result count
  and each returned edge is rendered as a fact carrying its text and its created, valid, invalid, and expired timestamps
  and each returned edge identifies its originating episodes by identifier, source kind, and source description
  and each returned edge is rendered with its relationship name and the name and identifier of its source and target entities
  and a standalone custom-entity node cannot be returned, because edge search matches edges by their endpoints
  and every query the search sends carries a FalkorDB query timeout below the socket timeout
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
  and the fact and entity queries bring back no embedding from FalkorDB
  and each fact and entity still carries every other stored property among its attributes
  and after the graph library's search, the facts' source episodes, the writers and extraction completion recorded on those and the returned episodes, and the facts' entity names are read by three queries sent together
  and every query the search sends carries a FalkorDB query timeout below the socket timeout
  if a query the search sends runs past its FalkorDB query timeout
    then FalkorDB stops running it
    and the search returns FalkorDB's timeout error
  if one of the follow-up queries reading source episodes, recorded writers and extraction completion, and entity names fails
    then the search abandons the other follow-up queries before it returns
    and the search returns that query's error
    and a follow-up query that times out makes the search return a timeout
  while node labels are supplied
    then the single search's filter carries those labels
    while several node labels are supplied
      then the graph library's node filter admits a node carrying any one of them
      and its edge filter admits an edge whose source and target each carry any one of them
  while edge types are supplied
    then the single search's filter carries those relationship types
  while neither node labels, edge types, included writers, excluded writers, nor an earliest creation time are supplied
    then the single search's filter leaves every node and edge eligible
    and the graph library's own node and episode queries are issued unchanged
  while writers are included
    then the single search's filter admits only edges produced by an included writer
    and the single search's filter admits only nodes produced by an included writer
    and the single search's filter admits only episodes written by an included writer
    and each admission is decided from the writers recorded on the edge, node, or episode itself, without a list of record identifiers
    and every admission is applied inside its query, before its limit
    and each rendered fact's sources include only episodes written by an included writer
  while writers are excluded
    then the single search's filter rejects episodes written by an excluded writer
    and the single search's filter rejects edges produced only by excluded writers
    and the single search's filter rejects nodes produced only by excluded writers
    and each rejection is decided from the writers recorded on the edge, node, or episode itself, without a list of record identifiers
    and every rejection is applied inside its query, before its limit
    and each rendered fact's sources omit episodes written by an excluded writer
  while an earliest creation time is supplied
    then the single search's filter admits only edges created at or after that time
    and the single search's filter admits only nodes created at or after that time
    and the single search's filter admits only episodes created at or after that time
    and every admission is applied inside its query, before its limit
    and any included or excluded writers are applied in the same queries
    and the episode full-text query restricts the episodes the full-text index yields without looking each one up again
    where the fact vector index leaves fewer facts than the search keeps
      then the fact similarity query returns the facts, in the same order, that the graph library's own query returns under the same restrictions
      and the fact similarity query finds its facts through the creation-time index before it reads any entity
  when the query exceeds the graph library's full-text limit
    then the graph library receives a bounded non-empty query containing the earliest supported terms
  when a returned Reflection episode lacks its durable extraction-completion marker
    then that episode is excluded before the episode limit is applied

if running a memory search raises inside the graph library
  then an error carrying the raised exception is returned

when a fact or entity similarity search runs on FalkorDB
  while the graph's vector index for those embeddings is built
    then the vector index is asked for many more of the nearest facts or entities than the search keeps
    and the group, the graph library's own filters, the included and excluded writers, and the earliest creation time are applied to what the vector index gives, inside the same query, before the search's limit
    and each result is scored as the graph library scores it, and only results scoring above the search's minimum are kept, best first
    where at least as many results pass as the search keeps
      while the vector index gave fewer candidates than it was asked for, or the last result kept is within the nearest share of the candidates it gave
        then no stored embedding is compared with the search's outside the vector index
        and the search returns as many results as the graph library's own query returns under the same restrictions
        and every result scores at least as high as the lowest-scoring result of the graph library's own query, as long as the vector index gives the truly nearest candidates
      while the vector index gave every candidate it was asked for and the last result kept lies beyond the nearest share of them
        then the search answers with the graph library's own query under the same restrictions
        and returns what that query returns
    where fewer results pass than the search keeps
      while the vector index gave every candidate it was asked for, every candidate scoring above the search's minimum is within the nearest share of them, and at least one result passed
        then the results that passed are returned
        and the graph library's own query is not sent
      while a candidate beyond the nearest share scores above the search's minimum, the vector index gave fewer candidates than it was asked for, or no result passed
        then the search answers with the graph library's own query under the same restrictions, through the creation-time index when an earliest creation time is supplied to a fact search
        and returns as many results as that query does
    while writers are included and few of the graph's facts are theirs
      then the fact search returns as many results as the graph library's own query returns under the same restrictions
    while writers are included and few of the graph's entities are theirs
      then the entity search returns as many results as the graph library's own query returns under the same restrictions
    when the vector index is dropped
      while the search reads that the vector index is no longer there
        then the search answers with the graph library's own query
        and the vector index is not asked
      while the search reads that the vector index is still built
        when the vector index refuses the search's lookup because it is gone
          then the search answers with the graph library's own query under the same restrictions, through the creation-time index when an earliest creation time is supplied to a fact search
          and the graph library's own query is sent once
          and the graph library's own query carries the search's query timeout
    if the vector index lookup fails for any reason but the index being gone
      then the search fails with that failure
      and the graph library's own query is not sent
  while the graph's vector index for those embeddings is built but compares by another similarity than cosine, or at another dimension than the search's embedding
    then the search fails, naming the graph, the index, its similarity and dimension, and how to replace it
    and the vector index is not asked
  while the graph's vector index for those embeddings is still being built
    then the search answers with the graph library's own query
    and the vector index is not asked
  while the graph has no vector index for those embeddings
    then the search answers with the graph library's own query
    and the vector index is not asked
  where a fact search names the facts it may return, or the entities at either end of the facts it may return
    then the search answers with the graph library's own query
    and neither the vector index nor whether it is built is read

when adding an episode looks for entities that may duplicate an extracted entity
  while the entity vector index is built
    then the candidates come from the entity vector index, as every other entity similarity search's do

when adding an episode looks for facts a new fact may invalidate
  while the fact vector index is built
    then the candidates come from the fact vector index

when adding an episode looks for facts that duplicate a new fact between the same two entities
  then the candidates are compared as the graph library's own query compares them, without the vector index

when a graph instance's indexes are built on FalkorDB
  then its full-text indexes carry no stopword list
  and an exact-match lookup for an indexed value that is a stopword returns its match instead of crashing FalkorDB
  and the graph has a vector index over fact embeddings and one over entity name embeddings, each comparing by cosine at the dimension the embedder produces
  and the vector indexes are created after any stopword replacement and after writers are recorded
  and index building returns without waiting for FalkorDB to finish building them
  while the graph has no vector index over fact or entity embeddings
    then the missing vector indexes are created
    and their creation is logged naming the graph, each index created, and its dimension
  while both vector indexes already exist, built or still being built
    then neither is created again
    and nothing is logged about them
  if an existing vector index compares at another dimension than the embedder produces, or by another similarity than cosine
    then it is left unchanged
    and a vector index the graph lacks is still created
    and index building fails, naming the graph, the index, its dimension and similarity, the embedder's dimension, and how to replace it
    and index building is not tried again
    and any stopword replacement and writer recording done before it are still logged
    and every other graph's indexes are still built
    if a query for the graph's other vector index fails in the same try
      then index building is still not tried again
      and index building fails naming the mismatched index and that failure
  if any query of index building fails, times out, loses its connection, or is answered that FalkorDB is loading
    then index building is tried again after a set wait, up to a set number of times
    and tries that fail at different steps count against the same limit
    and a later try runs the graph library's own index building, the stopword replacement, and the writer recording again
    and the stopword replacement and writer recording that each try did are logged
    when index building is tried again
      then the graph library's own index building creates only the indexes the graph lacks
      and the stopword replacement replaces only the indexes that still carry a stopword list
      and the writer recording records writers only on episodes, facts, and entities still without them
      and the try reads which vector indexes the graph has
      and the try creates only the vector indexes the graph lacks, so one that a failed try created, or that FalkorDB created for a query its client stopped waiting for, is not created twice
      while a try succeeds
        then index building is not tried again
        and the success is logged once, naming the graph and which try succeeded
        and the vector indexes that the tries created are logged together, naming the graph, each index created, and its dimension
        and a vector index that FalkorDB created for a query its client stopped waiting for is logged among them
        and index building succeeds
      if a try finds a mismatched vector index
        then no success is logged
        and index building fails naming the mismatched index
      if every try fails
        then index building fails, naming the graph, how many times it was tried, and the last failure
        and every other graph's indexes are still built
  if index building fails any other way, or its graph operation runs past its deadline
    then index building is not tried again
  while a label's index already carries a stopword list
    then every index on that label is dropped and recreated with the same fields and no stopword list
    and the replacement is logged naming the label
    and an exact-match lookup for a stopword value on that label returns its match
    and both vector indexes are created after the replacement
  while every index already carries no stopword list
    then no index is replaced
  if a label carrying a stopword list also holds an index that is neither range nor full-text
    then that label's indexes are left unchanged
    and the failure is logged naming the label
    and no vector index is created
  while the graph holds episodes, facts, or entities without recorded writers
    then each such episode records the writer its provenance names, or `unknown`
    and each such fact and entity records the writers of its episodes
    and the recording is logged naming the graph and how many episodes, facts, and entities it recorded
  while every episode, fact, and entity already records its writers
    then nothing is recorded
    and nothing is logged

when an index and constraint rebuild is requested for the whole graph
  then every group the pool holds an instance for is rebuilt, each group being its own database
  and a group whose instance has never been created is left alone, its indices being built the moment it is

when community building is requested for a group
  then the logical group is physically encoded before its graph instance is selected
  and the graph library builds communities for that physical group's instance
  and the returned community and edge counts are reported

if community building raises inside the graph library
  then an error carrying the raised exception is returned
