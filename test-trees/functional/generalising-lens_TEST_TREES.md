Functional: generalising-lens (functional: test/functional/generalising_lens_functional_test.exs)

when a transcript is submitted through Gralkor's generalising ingestion process
  then the process distils zero or more durable generalisation episodes
  and each resulting episode is added through the selected Lens with its ontology and group
  and repeated or contradicted generalisations are added as ordinary episodes without deleting earlier episodes
  and the caller observes whether ingestion succeeded or failed

where the generalising Lens is operator-local
  then its resulting memory is available only to that operator through that Lens

where the generalising Lens is global
  then its resulting memory enters the shared global group
  and every resulting episode records the generalising Lens as its origin

where capture is configured to generalise a flushed transcript through another Lens
  then the generalising Lens receives the transcript independently of the Lens that captured it
  and each Lens retains its own ontology, scope, and ingestion process

if distillation produces no durable generalisation
  then no episode is submitted to Graphiti
  and ingestion completes successfully

if distillation or memory ingestion fails
  then ingestion returns the failure without performing an alternative persistence write
