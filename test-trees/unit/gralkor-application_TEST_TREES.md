Unit: gralkor-application (src: lib/gralkor/application.ex; integration: test/gralkor/application_test.exs; unit: test/gralkor/application_test.exs)

when the application starts
  while a remote FalkorDB connection is configured
    then the Python runtime, graph pool, dedicated Reflection supervisor, and capture buffer are supervised in that order
    and the Reflection supervisor owns the durable Scheduler
    and the graph pool is constructed with the remote connection, so no embedded server is spawned
    and the Python runtime is told not to sweep for orphaned embedded servers, this deployment never having spawned one
    and a configured data directory is ignored
  while a data directory is configured
  and no remote connection is configured
    then the Python runtime, graph pool, dedicated Reflection supervisor, and capture buffer are supervised in that order
    and the Reflection supervisor owns the durable Scheduler
    and the graph pool is constructed with the embedded connection
    and the Python runtime is told to sweep for orphaned embedded servers, this deployment spawning one of its own
    and startup returns only once all four have initialised, so a consumer needs no separate readiness gate
  while the application supervisor waits for CaptureBuffer to drain
    then the dedicated Reflection supervisor remains able to replace a crashed Scheduler
  while neither a remote connection nor a data directory is configured
    then no children are supervised, because the consumer has not opted into the native runtime
  while the in-memory client is configured
    then no children are supervised regardless of configured local or remote storage

if the remote FalkorDB configuration is not a keyword list carrying a host and a port
  then startup raises before any child starts

when a capture flush runs
  then the transcript episode is rendered from the user and assistant text of every captured turn only, with no agent reasoning and no inference call
  and the rendered transcript is written as a captured episode
  while no episode-writing dependency is supplied
    then default writes name the graph pool server explicitly and reach it without shifted arguments

when a capture flush writes its captured episode successfully
  then a single line reporting the group, the transcript size, and the duration is logged
  and the flush reports success
  where test mode is enabled
    then the rendered transcript itself is logged, so what actually landed in memory is readable from the logs

when a legacy or Lens capture flush renders an empty transcript
  then no legacy episode write or Lens ingestion is submitted
  and the flush reports success

if writing the captured episode fails
  then no success line is logged, so a failed attempt is never recorded as a success
  and a concise warning naming the group and the reason is logged
  and the failure is returned unchanged, so the capture buffer owns retry and backoff

when a capture flush is retried after its captured episode has already been written
  then that captured episode is written a second time, because episode writes are not idempotent

when a Lens capture flush runs
  then the selected turns are rendered in the order they were appended
  and the rendered transcript is submitted through the selected Lens as a captured episode
