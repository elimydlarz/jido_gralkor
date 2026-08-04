Unit: gralkor-client-native (src: lib/gralkor/client.ex, lib/gralkor/client/native.ex; unit: test/gralkor/client/native_test.exs)

when any adapter operation is called
  then the work runs in the calling node's own processes, no HTTP request or other network transport being involved

when a recall is requested with a group, an agent name and a query
  then a fact search scoped to the group is supplied to the recall pipeline
  and a generalisation search scoped to the group's `_gen` partition is supplied to the recall pipeline
  and a learning search is supplied on every recall, with no enabling flag and no inference-based classification of the query
  and that learning search is seeded with the caller's raw query rather than a derived one
  and that learning search asks the graph for nodes labelled `Learning` rather than for edges, so standalone learning nodes are returned instead of nothing
  and each learning node found is rendered from its name, its summary, and its lesson, approach and problem-kind attributes
  while a session id is given
    then it is handed to the recall pipeline, so the turns buffered for that session become the conversation context
  where no session id is given
    then the recall pipeline is invoked without one
    and the conversation context is empty
  where a recall deadline is configured
    then it is forwarded to the recall pipeline in place of the default deadline
  where an interpretation output budget is configured
    then it is read from configuration on that call rather than at boot, so an operator can change it without restarting
    and it is forwarded to the recall pipeline as the interpretation output-token budget
  if the configured interpretation output budget is not a positive integer
    then an argument error naming that setting is raised at the adapter boundary before any recall work starts

if a recall is requested with a missing or blank agent name
  then an argument error naming the agent name is raised
  and no search is issued

when a turn is captured for a session under a group, with an agent name, a user name and messages
  then the group is sanitized before it is buffered
  and the deployment-configured ontology is resolved and buffered alongside the turn, the caller being given no ontology argument of its own
  and the sanitized group, the agent name, the user name, the resolved ontology and the messages are appended to the capture buffer under that session
  and success is returned immediately, no distillation running before the call returns
  and nothing is logged for the turn itself, captured content becoming observable only at flush

where a turn is captured through a named Lens
  then the operator id is buffered unsanitized, so the Lens keeps the operator's original identity
  and the agent name, the user name, the Lens name and the messages are appended to the capture buffer under that session
  and the deployment-configured ontology is not consulted, a Lens owning its own ontology
  and success is returned immediately

where a turn is captured through a primary Lens together with additional Lenses
  then each named Lens receives that turn in its own flush batch
  but the session buffers the turn only once

if a capture is requested with a missing or blank session id
  then an argument error naming the session id is raised
  and no turn is buffered

if a capture is requested with a missing or blank agent name
  then an argument error naming the agent name is raised
  and no turn is buffered

if a capture is requested with a missing or blank user name
  then an argument error naming the user name is raised
  and no turn is buffered

when a session holding buffered turns is flushed
  then those turns are scheduled for flush
  and success is returned before that flush completes

when a session holding no buffered turns is flushed
  then success is returned
  and no flush work is scheduled

if a flush is requested with a missing or blank session id
  then an argument error naming the session id is raised

when a session holding buffered turns is flushed and awaited with a positive timeout
  while the flush completes inside the timeout
    then success is returned
    and a recall for the bound group made immediately afterwards surfaces the just-flushed turns
  while the flush does not complete inside the timeout
    then a timeout error is returned
    and the buffered turns remain available to flush on a later call
  if the backend fails before the timeout elapses
    then that failure is returned unchanged

when a session holding no buffered turns is flushed and awaited
  then success is returned

if a flush-and-await is requested with a missing or blank session id
  then an argument error naming the session id is raised

if a flush-and-await is requested with a missing or non-positive timeout
  then an argument error naming the timeout is raised

when memory is added with a group and content
  then the group is sanitized before the write
  and the content is written to the graph as a plain-text episode scoped to the sanitized group
  and the episode carries a generated name of "manual-add-" followed by the current millisecond timestamp
  and the episode carries a generated idempotency key rendered from a positive monotonic unique integer
  and success is returned once the graph accepts the write
  and a graph failure is returned unchanged
  while no ontology override is supplied
    then the deployment-configured ontology is the one applied, so a caller is never required to supply one
  where an ontology override is supplied
    then the override is the ontology applied and the deployment-configured ontology is not consulted
  where a source description is supplied
    then it is the source recorded on the episode
  where no source description is supplied
    then the source recorded on the episode is "manual"
  while the ontology that applies resolves to nothing
    then the write declares no entity types, edge types, edge-type map or excluded entity types, so extraction stays generic
  while the ontology that applies is a module declaring an ontology
    then that module's declared entity types, edge types, edge-type map and excluded entity types are forwarded with the write
  if the ontology supplied is a module that declares no ontology
    then an argument error naming that module is raised before any write is attempted
  if the ontology supplied is not a module
    then an argument error naming that value is raised before any write is attempted

when an index and constraint rebuild is requested
  then the rebuild is applied to the whole graph rather than to a single group
  and a status is returned once the rebuild completes
  and a graph failure is returned unchanged

when community building is requested for a group
  then the group is sanitized before use
  and community building is scoped to the sanitized group
  and the number of communities and the number of edges built are returned
  and a graph failure is returned unchanged

when generalisations are searched for a group
  then the group is sanitized and the search is scoped to that group's `_gen` partition
  and every result that decodes as a generalisation is returned carrying its decoded content, level and confidence
  but a result that does not decode as a generalisation is left out rather than surfaced raw
  if the search fails
    then that failure is returned unchanged

when a group id holding hyphens is sanitized
  then every hyphen is replaced with an underscore
  and consecutive hyphens are each replaced independently, so none is collapsed into another

when a group id holding no hyphens is sanitized
  then it is returned unchanged

when the client implementation is resolved while no client module is configured
  then the native adapter is returned

when a recall runs
  then it carries a deadline of twelve seconds
  if that deadline is exceeded
    then the in-flight Python work is cancelled through the graph pool worker
    and an error identifying the expired deadline is returned

when a memory add runs
  then it carries a deadline of sixty seconds, covering the graph library's entity and edge extraction
  if that deadline is exceeded
    then the in-flight Python work is cancelled through the graph pool worker
    and an error identifying the expired deadline is returned

where any adapter operation other than recall and memory add runs
  then it carries no deadline and either runs to completion or crashes
