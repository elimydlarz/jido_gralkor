Integration: plugin (src: lib/jido_gralkor/plugin.ex, lib/jido_gralkor/runtime.ex; integration: test/jido_gralkor/plugin_test.exs)

when a consumer reads the plugin's advertised actions
  then memory search, memory add, build indices, and build communities are exposed in that order for the consumer to pass as agent tools

when a consumer reads the plugin's advertised identity and ownership
  then it is named `gralkor`
  and it advertises the memory capability
  and it owns the `:__memory__` plugin-state slot
  and it is singleton

when a consuming AgentServer requests the plugin's child specification
  then the plugin declares one Gralkor runtime child owned by that AgentServer
  and the child receives the complete runtime configuration supplied to the plugin
  where runtime configuration is omitted
    then the child receives empty consumer Destination, Lens, and Reflection collections

when a consumer agent mounts the plugin
  then the expanded routes resolve with no conflicts against the host agent

when mount is given a non-blank agent name
  then it returns plugin state carrying that agent name

if mount is given no agent name
  then it raises ArgumentError

if mount is given a blank agent name
  then it raises ArgumentError

if mount's runtime configuration is invalid
  then it raises an ArgumentError identifying the invalid configuration

when mount selects an ingestion Lens
  then the selected Lens name is stored on the plugin state without copying its definition
  where the selected Lens is packaged
    then mounting accepts the Lens
  where the selected Lens is declared by that mount
    then mounting accepts the Lens
  if the ingestion Lens is unknown
    then mounting raises an ArgumentError identifying the unknown Lens
  if the ingestion Lens is retired
    then mounting raises an ArgumentError naming `personal-chat` as its replacement
  if the Lens exists only in the application compatibility registry
    then mounting raises an ArgumentError identifying the unknown Lens
  if the removed `:default_lens` option is supplied
    then mounting raises an ArgumentError identifying `:ingestion_lens` as its replacement

if mount receives the removed `:search_destinations` option
  then mounting raises an ArgumentError identifying MemorySearch's per-search `destinations` selector as its replacement

if mount receives the removed `capture_destination` option
  then mounting raises an ArgumentError saying capture was removed in 18.0.0 and directing the consumer to remember its own chat record with `Gralkor.Client.ingest/2` through a Lens

when an agent turn begins
  while a thread has committed to agent state
    then the session id planted on the signal's tool context is that committed thread's id rather than one the plugin mints
    and the mounted agent name is planted on the tool context beside it
    and the owning AgentServer is planted as the Gralkor runtime target
    and no recall is issued on the plugin's own initiative
    and the user's query is left untouched on the signal
    and unrelated incoming tool-context fields remain alongside fields planted by the plugin
    where the incoming tool context selects a Lens
      then the selected Lens is validated and kept on the tool context
      if the Lens is unknown or invalid
        then the callback raises identifying the invalid Lens
    where the incoming tool context explicitly selects no Lens
      then the tool context keeps that empty Lens selection
  while no thread has committed to agent state
    then the mounted agent name and Gralkor runtime target are planted on the tool context, with no session id
    and no recall is issued on the plugin's own initiative
  where the plugin was mounted with an ingestion Lens
    while a thread has committed to agent state
      then the Lens selection and committed session id are planted on the tool context beside the agent name
    while no thread has committed to agent state
      then the Lens selection is planted on the tool context beside the agent name without a session id

when a signal of any other type arrives
  then the plugin lets the signal continue untouched
  and nothing is recalled

if a memory signal hook cannot identify its owning AgentServer
  then the callback raises identifying the missing owner
