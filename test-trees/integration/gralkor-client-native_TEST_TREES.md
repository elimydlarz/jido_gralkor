Integration: gralkor-client-native (src: lib/gralkor/client.ex, lib/gralkor/client/native.ex, lib/gralkor/default_ontology.ex; integration: test/gralkor/client/native_test.exs)

when any adapter operation is called
  then the work runs in the calling node's own processes, no HTTP request or other network transport being involved

when recall is requested for a group, agent and query
  then a fact search scoped to the group is supplied to the recall pipeline
  while a session id is given
    then it is handed to the recall pipeline for recall observability
  where no session id is given
    then the recall pipeline is invoked without one
  where a positive-integer recall deadline is configured
    then it is forwarded to the recall pipeline in place of the default deadline
  if a configured recall deadline is not a positive integer
    then an argument error naming the recall deadline is raised before any search is issued

if a recall is requested with a missing or blank agent name
  then an argument error naming the agent name is raised
  and no search is issued

when memory is added with a group and content
  then the logical group reaches the physical Graphiti boundary unchanged and is encoded exactly once there
  and the content is written to the graph as a plain-text episode scoped to that physical group
  and storage-owned direct writer provenance is recorded without a Lens
  and the generated name combines the millisecond timestamp with a positive monotonic integer
  and success is returned once the graph accepts the write
  and generic entity and relationship extraction remains enabled without an application-owned schema
  if the graph fails
    then that failure is returned unchanged
  then jido_gralkor's built-in ontology is applied, so a caller neither supplies nor configures one
  where a source description is supplied
    then it is retained as the source beneath storage-owned direct provenance
  where a source kind is supplied
    then the declared source kind is forwarded to the graph write
    while the source kind is structured record
      then the supplied map or list is forwarded as its JSON encoding
  where no source description is supplied
    then the source retained beneath storage-owned direct provenance is "manual"

when an index and constraint rebuild is requested
  then the rebuild is applied to the whole graph rather than to a single group
  and a status is returned once the rebuild completes
  if the graph fails
    then that failure is returned unchanged

when community building is requested for a group
  then the logical group reaches the physical Graphiti boundary unchanged and is encoded exactly once there
  and community building is scoped to that physical group
  and the number of communities and the number of edges built are returned
  if the graph fails
    then that failure is returned unchanged

when a logical graph identifier is encoded for Graphiti
  then its physical identifier is `g_` followed by the lowercase hexadecimal encoding of every original byte
  and distinct logical identifiers always produce distinct physical identifiers

when the client implementation is resolved
  while no client module is configured
    then the native adapter is returned

when a recall runs
  then it carries the recall pipeline's deadline, twelve seconds unless the deployment configures another
  if that deadline is exceeded
    then an error identifying the expired deadline is returned to the caller
    and the work already handed to the embedded interpreter finishes unobserved, no layer being able to cancel it

where any adapter operation other than recall runs
  then it carries no deadline of its own, so a memory addition, an index rebuild and a community build each run for as long as the graph takes
