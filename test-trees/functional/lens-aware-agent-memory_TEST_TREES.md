Functional: lens-aware-agent-memory (src: lib/jido_gralkor/plugin.ex, lib/jido_gralkor/actions/memory_add.ex, lib/jido_gralkor/actions/memory_search.ex, lib/gralkor/client.ex; functional: test/functional/lens_aware_agent_memory_functional_test.exs)

when a mounted memory plugin has a configured ingestion Lens
  then automatic capture and memory addition use the registered ingestion Lens
  and the plugin does not redefine the selected Lens's Destination or ingestion process

when an agent with a mounted memory plugin invokes memory search
  then optional Destination and Lens selectors belong only to that search invocation
  and search selectors neither default from nor change the configured ingestion Lens
  and a turn-selected ingestion Lens neither defaults nor restricts memory search
  and every returned episode identifies its Destination and originating Lens or declaring Reflection
  where no conversation thread has been committed
    then memory search still runs for the current operator
  where the Destination selector is omitted or empty
  and the Lens selector is omitted or empty
    then memory search uses every accessible registered Destination

where an agent turn selects another registered Lens
  then memory addition uses the turn-selected Lens
  and that Lens is retained for the request
  and completion without a repeated Lens captures through the retained request Lens
  and failure without a repeated Lens captures through the retained request Lens

if an agent turn selects an unknown or non-binary Lens
  then handling the turn fails before memory addition or capture
  and the invalid Lens is identified

when turns in one session select different Lenses
  then each Lens retains only the turns selected for it
  and no flushed episode combines turns governed by different ontologies or ingestion processes
  and captured turns retain their original order

if a mounted plugin receives invalid ingestion Lens configuration
  then mounting fails before the plugin handles an agent signal
  and an unknown ingestion Lens is identified
  and the removed `:default_lens` option identifies `:ingestion_lens` as its replacement

if a mounted plugin receives the removed `:search_destinations` option
  then mounting fails before the plugin handles an agent signal
  and the error identifies MemorySearch's per-search `destinations` selector as its replacement
