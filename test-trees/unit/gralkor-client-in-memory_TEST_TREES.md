Unit: gralkor-client-in-memory (src: lib/gralkor/client.ex, lib/gralkor/client/in_memory.ex; unit: test/support/gralkor_client_contract.ex and test/gralkor/client/in_memory_test.exs)

when recall, capture, flush-and-await, memory addition, index rebuilding, or community building is called
  then the call is recorded with every argument it was given, so a consumer's exact request can be inspected afterwards

if recall, capture, flush-and-await, memory addition, index rebuilding, or community building is called
  while no response is configured for it
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

when a canonical turn is captured for a named session, group, agent and user
  while its messages have user, assistant or behaviour roles
    then the write uses implicit-default memory without a caller ontology argument
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

if named-Lens capture is requested with a missing or blank operator identifier
  then an argument error is raised at the port boundary
  and no backend call is made

if a flush or flush-and-await is requested with a missing or blank session id
  then an argument error is raised at the port boundary
  and no backend call is made

if flush-and-await receives a timeout that is not a positive integer
  then an argument error is raised
  and the error identifies the invalid timeout
  and no backend call is made

when a flush is requested for a session
  then the call is recorded with its session id
  and success is returned before the flush completes
  if the backend fails afterwards
    then that failure is not observable through the return value

when a flush is requested for a session and awaited with a timeout
  while the flush completes inside the timeout
    then success is returned
    and a later recall for the same group reaches the backend as a separate call
  while the flush does not complete inside the timeout
    then a timeout error is returned
    and a later flush-and-await for the same session reaches the backend as a separate call
  if the backend fails before the timeout elapses
    then that failure is returned unchanged

when memory is added with a group, content and a source description
  then the write uses implicit-default memory, so a caller neither supplies nor configures an ontology
  while the backend acknowledges the add
    then success is returned
  where a source kind is supplied
    then the call is recorded with that source kind unchanged
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
