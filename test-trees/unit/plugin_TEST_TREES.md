Unit: plugin (src: lib/jido_gralkor/plugin.ex; unit: test/jido_gralkor/plugin_test.exs)

when a consumer reads the plugin's advertised actions
  then memory search, memory add, build indices, and build communities are exposed in that order for the consumer to pass as agent tools

when a consumer agent mounts the plugin
  then the expanded routes resolve with no conflicts against the host agent

when mount is given a non-blank agent name
  then it returns plugin state carrying that agent name

if mount is given no agent name
  then it raises ArgumentError

if mount is given a blank agent name
  then it raises ArgumentError

when mount selects an ingestion Lens and Destinations to search
  then those selections are resolved against their application registries and stored on the plugin state
  and the resolved Lens keeps the Destination and ingestion the registry declared for it, redefining neither
  if Lens options are supplied without an ingestion Lens
    then mounting raises an ArgumentError identifying that the ingestion Lens is required
  if the ingestion Lens is unknown
    then mounting raises an ArgumentError identifying the unknown Lens
  if a search Destination is unknown
    then mounting raises an ArgumentError identifying the unknown Destination
  if the removed `:default_lens` option is supplied
    then mounting raises an ArgumentError identifying `:ingestion_lens` as its replacement
  if the search Destination selection is not a list
    then mounting raises an ArgumentError identifying the invalid selection

when an agent turn begins
  while a thread has committed to agent state
    then the session id planted on the signal's tool context is that committed thread's id rather than one the plugin mints
    and the mounted agent name is planted on the tool context beside it
    and no recall is issued on the plugin's own initiative
    and the user's query is left untouched on the signal
    where the incoming tool context selects a Lens
      then the selected Lens is validated and retained on the request-correlated thread entry
      and the selected Lens remains available to completion and failure capture
  while no thread has committed to agent state
    then only the mounted agent name is planted on the tool context, with no session id
    and no recall is issued on the plugin's own initiative
  where the plugin was mounted with Lens and Destination selections
    while a thread has committed to agent state
      then the Lens and Destination selections and committed session id are planted on the tool context beside the agent name
    while no thread has committed to agent state
      then the Lens and Destination selections are planted on the tool context beside the agent name without a session id

when an agent turn completes
  while a thread has committed to agent state
    then the turn is sent for capture as canonical messages under that thread's session id and the operator's sanitised group id
    and the user name held in agent state is forwarded with the capture
    and the user's query opens the captured messages
    and the completed answer closes them
    while the completed turn's request trace holds no events
      then no capture is sent at all
    where the plugin was mounted with Lens selections
      then the capture carries the selected Lens
    if agent state holds no user name
      then the callback raises ArgumentError naming the missing user name
    if agent state holds a blank user name
      then the callback raises ArgumentError naming the missing user name
    if the capture call fails
      then the callback raises, reporting the capture failure
  while no thread has committed to agent state
    then capture is skipped
    and a warning naming the operator is logged

when an agent turn fails
  while a thread has committed to agent state
    then the turn is captured with the failure surfaced as a terminal `request failed: …` behaviour message
    and no assistant message is captured for the failed turn
    and the user's original query is captured ahead of the failure message
    while the failed turn's request trace holds no events
      then the user's query and terminal failure are still sent for capture
  while no thread has committed to agent state
    then capture is skipped
    and a warning naming the operator is logged

when a signal of any other type arrives
  then the plugin lets the signal continue untouched
  and nothing is captured
  and nothing is recalled
