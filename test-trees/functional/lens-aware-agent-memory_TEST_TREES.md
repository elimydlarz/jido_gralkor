Functional: lens-aware-agent-memory (functional: test/functional/lens_aware_agent_memory_functional_test.exs)

when a mounted memory plugin has a configured default ingestion Lens and optional additional search targets
  then automatic capture and memory addition use the registered default ingestion Lens
  and memory search always includes the requesting operator's reserved `default` target
  and memory search also includes the configured additional search targets
  and the plugin does not redefine a selected Lens's ontology, scope, or ingestion process

where a mounted memory plugin has no additional search targets
  then memory search uses only the requesting operator's reserved `default` target

where an agent turn selects another registered Lens
  then memory addition uses the turn-selected Lens
  and that Lens is retained for the request
    when the matching request completes or fails without repeating its Lens
      then automatic capture uses the retained request Lens rather than the plugin default

when turns in one session select different Lenses
  then each Lens retains only the turns selected for it
  and no flushed episode combines turns governed by different ontologies or ingestion processes
  and captured turns retain their original order

if a mounted plugin receives invalid Lens configuration
  then mounting fails before the plugin handles an agent signal
    where the default Lens is unknown
      then the error identifies the unknown default Lens
    where a search target is invalid
      then the error identifies the invalid target
    where the generalising Lens is unknown
      then the error identifies the unknown generalising Lens
    where the generalising Lens duplicates the default Lens
      then the error identifies that the two selections must differ
    where Lens options are supplied without a default Lens
      then the error identifies that a default Lens is required
