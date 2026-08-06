Functional: lens-aware-agent-memory (functional: test/functional/lens_aware_agent_memory_functional_test.exs)

when a mounted memory plugin has a configured default ingestion Lens and optional additional Lenses to search
  then automatic capture and memory addition use the registered default ingestion Lens
  and memory search always includes the requesting operator's reserved `default` Lens
  and memory search also includes the configured additional Lenses
  and the plugin does not redefine a selected Lens's ontology, scope, or ingestion process

where a mounted memory plugin has no additional Lenses to search
  then memory search uses only the requesting operator's reserved `default` Lens

where an agent turn selects another registered Lens
  then memory addition uses the turn-selected Lens
  and that Lens is retained for the request
  and completion without a repeated Lens captures through the retained request Lens
  and failure without a repeated Lens captures through the retained request Lens

when turns in one session select different Lenses
  then each Lens retains only the turns selected for it
  and no flushed episode combines turns governed by different ontologies or ingestion processes
  and captured turns retain their original order

if a mounted plugin receives invalid Lens configuration
  then mounting fails before the plugin handles an agent signal
  and an unknown default Lens is identified
  and an unknown Lens to search is identified
  and an unknown generalising Lens is identified
  and a generalising Lens that duplicates the default is identified
  and Lens options without a default Lens identify the required default
  and a non-list Lens search selection is identified
