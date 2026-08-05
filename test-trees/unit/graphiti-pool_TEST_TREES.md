Unit: graphiti-pool (src: lib/gralkor/graphiti_pool.ex; integration: test/gralkor/graphiti_pool_test.exs; unit: test/gralkor/graphiti_pool_test.exs)

when inference is needed to extract entities and edges from an episode, to embed a search query, or to rerank search candidates
  then the call is issued by the graph library's own provider client rather than by the BEAM-side LLM client

when the pool starts
  then the shared asyncio runtime is installed, so the pool can be started on its own
  and the LLM client, the embedder, and the cross-encoder are each constructed once and shared by every graph instance for the pool's lifetime
  while both configured model specs name a supported inference provider
    then client construction proceeds using the configured model ids
    and the LLM client is built for the provider the LLM spec names
    and the embedder is built for the provider the embedder spec names
    and the cross-encoder is built for the provider the LLM spec names
    and each provider's credential is read on the BEAM side and handed to its client as an explicit argument, the embedded interpreter's own environment never carrying it
      where the credential was set from Elixir rather than exported into the OS process
        then it still reaches the client, so a consumer's runtime configuration and a test helper's loaded `.env` both work
    while the embedder spec names Google
      then the embedder is constructed to send one input per request, so a batched call cannot receive fewer embeddings than it sent inputs
    while the two specs name different providers
      then each client is still built for its own role's provider
      and startup completes
  while an embedded connection is configured
    then any resume-cache file left beside the database is removed before the embedded database is constructed, so a stale socket from a previous boot cannot be reconnected to
    and the embedded database is constructed once and held for the pool's lifetime
  while a remote connection is configured
    then the remote database is constructed once and held for the pool's lifetime

if either configured model spec names a provider that is neither OpenAI nor Google
  then startup raises before any inference client is constructed
  and the failure names both configured model specs
  and the failure names the providers that are supported

if the credential for a provider named by a configured model spec is absent
  then startup raises before any inference client is constructed
  and the failure names the absent credential
  and the failure names the role whose spec required it

where a provider is named by neither configured model spec
  then its absent credential does not prevent startup

when the pool has constructed its database
  then a warmup search runs once against a throwaway query and group, paying the cold-start cost before any consumer can recall
  and a warmup interpretation runs once against an empty conversation and throwaway facts
  and a single line reporting the search, interpretation, and total warmup durations is logged
  if a warmup call raises or returns an error
    then the failure is logged as non-fatal, naming the stage and the reason
    and startup completes anyway

when a graph instance is requested for a group
  then the instance is looked up from a cache shared across callers
  and concurrent callers for different groups proceed in parallel
  while no instance is cached for that group
    then the instance is constructed, cached, and held for the pool's lifetime
    and index and constraint building is invoked before the instance is cached and returned
    while construction takes longer than the default call timeout
      then construction still runs to completion
    if index and constraint building fails
      then the failure is non-fatal
      and the instance is still cached and returned

when an episode is added
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

when a fact search is run for a group
  then the graph library's edge search is invoked with the requested result count
  and each returned edge is rendered as a fact carrying its text and its created, valid, invalid, and expired timestamps
  and a standalone custom-entity node cannot be returned, because edge search matches edges by their endpoints

when a node search is run for a group
  then it is restricted to the sanitised group id the episodes were written under, so a group id carrying hyphens still matches
  while node labels are supplied
    then the graph library's node search is invoked with the requested result count and a filter carrying those labels
    and each returned node is rendered with its name, summary, and attributes, ordered by relevance
  while no node labels are supplied
    then the graph library's node search is invoked with every node eligible
