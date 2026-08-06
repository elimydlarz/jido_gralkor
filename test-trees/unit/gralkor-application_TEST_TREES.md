Unit: gralkor-application (src: lib/gralkor/application.ex; integration: test/gralkor/application_test.exs; unit: test/gralkor/application_test.exs)

when the application starts
  while a remote FalkorDB connection is configured
    then the Python runtime, the graph pool, and the capture buffer are supervised in that order
    and the graph pool is constructed with the remote connection, so no embedded server is spawned
    and the Python runtime is told not to sweep for orphaned embedded servers, this deployment never having spawned one
    and a configured data directory is ignored
  while a data directory is configured
  and no remote connection is configured
    then the Python runtime, the graph pool, and the capture buffer are supervised in that order
    and the graph pool is constructed with the embedded connection
    and the Python runtime is told to sweep for orphaned embedded servers, this deployment spawning one of its own
    and startup returns only once all three have initialised, so a consumer needs no separate readiness gate
  while neither a remote connection nor a data directory is configured
    then no children are supervised, because the consumer has not opted into the native runtime
  while the in-memory client is configured
    then no children are supervised regardless of configured local or remote storage

if the remote FalkorDB configuration is not a keyword list carrying a host and a port
  then startup raises before any child starts

when a capture flush runs
  then the transcript episode is rendered from the user and assistant text of every captured turn only, with no agent reasoning and no inference call
  and the rendered transcript is written as a captured episode
  while no learning step is wired
    then no learning episode is written
  while no episode-writing dependency is supplied
    then default writes name the graph pool server explicitly and reach it without shifted arguments
  while generalisation on flush is disabled
    then no generalisation step runs

when a capture flush writes its captured episode successfully
  then a single line reporting the group, the transcript size, and the duration is logged
  and the flush reports success
  and every captured turn is learned from in the order it was appended
  and each learning result is written as its own separate episode carrying the same group and ontology as the captured episode
  and the learning write asks for the built-in Learning entity type to be merged onto its ontology, while the captured write does not
  where test mode is enabled
    then the rendered transcript itself is logged, so what actually landed in memory is readable from the logs
  while generalisation on flush is enabled
    then generalisation is started against the group and the rendered transcript without blocking the flush
    and a generalisation failure does not change the flush result

when a capture flush renders an empty transcript
  then no captured episode is written
  and the flush reports success
  and every captured turn is still learned from in the order it was appended

if writing the captured episode fails
  then no success line is logged, so a failed attempt is never recorded as a success
  and a concise warning naming the group and the reason is logged
  and the failure is returned unchanged, so the capture buffer owns retry and backoff
  and no learning episode is written on that attempt, so a retried flush cannot write learning twice

if writing a learning episode fails
  then the failure is returned unchanged rather than swallowed, so the capture buffer owns whether to retry or drop it

if producing a learning result fails
  then the failure is classified as upstream for capture-buffer retry ownership
  and the failure is not retried at the flush, because retry belongs to the inference call itself

if producing a learning result raises or returns an unexpected shape
  then the exception propagates, because an unexpected inference response is a fault rather than a best-effort drop

when a capture flush is retried after its captured episode has already been written
  then that captured episode is written a second time, because episode writes are not idempotent

when a Lens capture flush runs
  then the selected turns are rendered in the order they were appended
  and the rendered transcript is submitted through the selected Lens as a captured episode
