Functional: lens-aware-agent-memory (functional: test/functional/lens_aware_agent_memory_functional_test.exs)

when a mounted memory plugin has a configured ingestion Lens and optional Destinations to search
  then automatic capture and memory addition use the registered ingestion Lens
  and memory search uses the configured Destinations
  and every returned fact identifies its Destination
  and the plugin does not redefine the selected Lens's Destination or ingestion process

where a mounted memory plugin has no Destinations to search
  then memory search uses the packaged operator-memory Destination
  and memory search uses the packaged `global` Destination
  and every returned fact identifies its Destination

where an agent turn selects another registered Lens
  then memory addition uses the turn-selected Lens
  and that Lens is retained for the request
  and completion without a repeated Lens captures through the retained request Lens
  and failure without a repeated Lens captures through the retained request Lens

if an agent turn selects an unknown or non-binary Lens
  then handling the turn fails before memory addition or capture
  and the invalid Lens is identified

when a mounted memory plugin captures through a Lens for an agent request
  then the host agent's configured tools reach every scheduled Reflection
  and the retained request tool context reaches every scheduled Reflection
  and the current operator, agent name, Lens, and session id override conflicting configured or retained context

when turns in one session select different Lenses
  then each Lens retains only the turns selected for it
  and no flushed episode combines turns governed by different ontologies or ingestion processes
  and captured turns retain their original order

if a mounted plugin receives invalid Lens configuration
  then mounting fails before the plugin handles an agent signal
  and an unknown ingestion Lens is identified
  and an unknown Destination to search is identified
  and Lens options without an ingestion Lens identify the required ingestion Lens
  and the removed `:default_lens` option identifies `:ingestion_lens` as its replacement
  and a non-list Destination search selection is identified
  and a non-binary Destination entry is identified
