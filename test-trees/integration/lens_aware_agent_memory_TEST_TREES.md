Integration: Lens-aware agent memory (integration: none)

when a mounted memory plugin has a configured default Lens and search targets
  then automatic capture and memory addition use the registered default Lens
  and memory search uses the configured search targets
  and the plugin does not redefine a selected Lens's ontology, scope, or ingestion process

where an agent turn selects another registered Lens
  then memory addition uses the turn-selected Lens
  and that Lens is retained for the request
    when the matching request completes or fails without repeating its Lens
      then automatic capture uses the retained request Lens rather than the plugin default

when turns in one session select different Lenses
  then each Lens receives only the turns selected for it
  and no flushed episode combines turns governed by different ontologies or ingestion processes
  and before flush the capture buffer exposes the session's complete turn order

if a mounted plugin selects an unknown default Lens, invalid search target, unknown or duplicate generalising Lens, or Lens options without a default Lens
  then mounting fails before the plugin handles an agent signal
