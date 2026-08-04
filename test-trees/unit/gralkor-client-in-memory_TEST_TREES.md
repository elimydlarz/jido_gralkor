Unit: gralkor-client-in-memory (src: lib/gralkor/client.ex, lib/gralkor/client/in_memory.ex; unit: test/support/gralkor_client_contract.ex and test/gralkor/client/in_memory_test.exs)

when any client operation is called
  then the call is recorded with every argument it was given, so a consumer's exact request can be inspected afterwards

if an operation is called while no response is configured for it
  then a not-configured error is returned rather than a fabricated success

when the double is reset
  then every configured response is cleared
  and every recorded call is cleared

when the client implementation is resolved
  while a client module is configured
    then that configured module is returned

when a recall is requested with a group, an agent name, a session id and a query
  while the backend returns a memory block
    then that block is returned to the caller as a success
  if the backend fails
    then that failure is returned unchanged

where a recall is requested with no session id
  while the backend returns a memory block
    then that block is returned to the caller as a success
  if the backend fails
    then that failure is returned unchanged

when a turn is captured with a session id, a group, an agent name, a user name and messages
  while the messages are canonical message structs whose role is user, assistant or behaviour
    then the write applies the deployment-configured ontology, the caller being given no ontology argument on this arity
    and every turn captured through this arity is learned from at its flush, there being no per-turn learning flag
  while the backend acknowledges the capture
    then success is returned
  if the backend fails
    then that failure is returned unchanged

where a turn is captured through a named Lens, alone or together with additional Lenses
  while the backend acknowledges the capture
    then success is returned
  if the backend fails
    then that failure is returned unchanged

if a recall or a capture is requested with a missing or blank agent name
  then an argument error is raised at the port boundary
  and no backend call is made

if a capture is requested with a missing or blank user name
  then an argument error is raised at the port boundary
  and no backend call is made

if a capture is requested with a missing or blank session id
  then an argument error is raised at the port boundary
  and no backend call is made

when a flush is requested for a session
  then success is returned before the flush completes
  if the backend fails afterwards
    then that failure is not observable through the return value

when a flush is requested for a session and awaited with a timeout
  while the flush completes inside the timeout
    then success is returned
    and a recall for the same group afterwards surfaces the just-flushed turns
  while the flush does not complete inside the timeout
    then a timeout error is returned
    and the buffered turns remain available to flush on a later call
  if the backend fails before the timeout elapses
    then that failure is returned unchanged

when memory is added with a group, content and a source description
  then the write applies the deployment-configured ontology, so a caller is never required to supply one
  while the backend acknowledges the add
    then success is returned
  if the backend fails
    then that failure is returned unchanged
  where an ontology override is supplied
    then the override is applied to the write and the deployment-configured ontology is not consulted
    and this override is the only per-call ontology surface the client exposes
    while the backend acknowledges the add
      then success is returned
    if the backend fails
      then that failure is returned unchanged

when an index rebuild is requested
  while the backend acknowledges the rebuild
    then its status is returned as a success
  if the backend fails
    then that failure is returned unchanged

when community building is requested for a group
  while the backend returns counts
    then the number of communities and the number of edges are returned as a success
  if the backend fails
    then that failure is returned unchanged

when generalisation is requested for a group and a transcript
  then success is returned once the pipeline completes
  if the pipeline's upstream inference fails
    then success is still returned, generalisation being fire-and-forget and its failures only logged

when generalisations are searched for a group with a query and a result ceiling
  while the backend returns generalisations
    then they are returned as a success carrying their decoded content, level and confidence
  while the backend returns none
    then an empty list is returned as a success rather than an error
  if the backend fails
    then that failure is returned unchanged
