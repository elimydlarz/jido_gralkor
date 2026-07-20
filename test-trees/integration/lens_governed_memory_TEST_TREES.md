Integration: Lens-governed memory (integration: test/integration/lens_governed_memory_integration_test.exs)

when an application registers a Lens with a non-blank name, ontology, local or global scope, and ingestion process
  then direct callers and mounted memory plugins can select that Lens by name
  and every plugin mount observes the same application-owned Lens definition

when information is submitted through a registered Lens
  then the Lens's ingestion process receives the information and a store bound to that Lens
  and every episode the process asks the store to add is submitted once to Graphiti with the Lens's ontology and Graphiti group
  and the process may add no episodes, one episode, or multiple episodes without changing those bindings
  and Graphiti owns extraction, duplicate resolution, temporal invalidation, persistence, and fact-to-episode provenance

where information is submitted directly without a mounted plugin or conversational turn
  then the selected Lens's ingestion process runs without requiring an agent response or capture flush
  and the caller observes whether ingestion succeeded or failed

when an operator-local Lens adds an episode
  then its Graphiti group is determined by the operator and Lens together
  and that group is distinct from every other operator-local Lens group and the shared global group
  and the episode is available only through that Lens for that operator
  and a Lens with the same name belonging to another operator cannot observe it
  and another operator-local Lens belonging to the same operator cannot observe it

when a global Lens adds an episode
  then Graphiti ingests the episode into the one global group shared by every global Lens and every operator
  and the same episode submission records the name of the Lens that ingested it in its source
  and the ingestion process does not have to add Lens provenance itself

when a caller searches a non-empty selection of operator-local Lenses and reserved `default` or `global` targets
  then the selection resolves to Graphiti groups for the requesting operator
  and those groups are searched through one Graphiti multi-group search
  and selecting the global pool searches every episode in that pool without filtering by originating Lens
  and results from all selected destinations are combined into one memory response
  and results are concatenated in requested target order without deduplicating repeated matches
  and the same maximum result count is applied to every selected destination
  and no unselected operator-local Lens or another operator's local memory can contribute a result

if Graphiti's multi-group search fails
  then the error is returned without manufacturing a partial memory response

where a global Lens name identifies an episode's origin
  then that name remains attribution rather than a search boundary
  and `global` is the only target that selects globally stored memory

when a mounted plugin has a configured default Lens and search targets
  then automatic capture and memory addition use the registered default Lens
  and memory search uses the configured search targets
  and the plugin does not redefine the selected Lenses' ontology, scope, or ingestion process

if a mounted plugin selects an unknown default Lens, invalid search target, unknown or duplicate generalising Lens, or Lens options without a default Lens
  then mounting fails before the plugin handles an agent signal

where a turn supplies a registered Lens through plugin context
  then that Lens is retained as the ingestion Lens for that request
  and the application-owned definition of the selected Lens remains authoritative
    when the matching request completes or fails without repeating the Lens in its completion signal
      then automatic capture uses the retained request Lens rather than the plugin default

when turns in one session select different Lenses
  then each Lens receives only the turns selected for it
  and no flushed episode combines turns governed by different ontologies or ingestion processes
  and before flush the capture buffer exposes the session's complete turn order

where an application has not registered or selected a named Lens
  then the implicit `default` Lens preserves access to the operator's existing memory partition
  and the `:jido_gralkor, :ontology` value remains its ontology
  and an unset `:jido_gralkor, :ontology` preserves generic extraction
  and existing capture, memory addition, and recall preserve legacy behavior under that compatibility mapping

where search selects the reserved `default` target
  then Graphiti searches the requesting operator's compatibility group
  and another operator's compatibility memory cannot contribute a result

when a transcript is submitted through Gralkor's generalising ingestion process
  then the process distils the transcript into zero or more generalisation episodes
  and each distilled episode is added through the selected Lens with its ontology and Graphiti group
  and existing episodes remain as provenance-bearing source history while Graphiti resolves duplicate and contradicted facts
  and the selected Lens determines whether the resulting generalisations are operator-local or global

where capture is configured to generalise a flushed transcript through another Lens
  then the generalising Lens receives the transcript independently of the Lens that captured it
  and each Lens retains its own ontology, scope, and ingestion process

if Lens registration is invalid (blank, duplicate, reserved `default` or `global`, or malformed)
  then configuration resolution raises `ArgumentError` naming the invalid Lens before ingestion or search begins

if ingestion names an unknown or blank Lens
  then ingestion fails before an ingestion process or graph write is started

if search supplies an empty selection or a target that is neither a registered operator-local Lens nor reserved `default` or `global`
  then search fails before any memory query is started
  and no valid subset is searched

if a Lens's ingestion process fails
  then ingestion returns that failure to the caller
  and no implicit fallback write bypasses the selected process
