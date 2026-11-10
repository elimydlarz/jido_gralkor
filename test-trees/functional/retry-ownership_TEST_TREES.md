Functional: retry-ownership (src: lib/gralkor/client.ex, lib/gralkor/destination/storage.ex, lib/gralkor/reflection/runner.ex, lib/jido_gralkor/runtime.ex, lib/gralkor/recall.ex, lib/gralkor/client/native.ex, lib/gralkor/graphiti_pool.ex, lib/gralkor/application.ex; functional: test/functional/retry_ownership_functional_test.exs)

when a direct graph write fails
  then the direct caller receives the failure after one attempt

when Reflection production or Destination delivery reports a retryable server failure
  then the failing boundary retries with exponential backoff
  and another Reflection invocation continues independently
  while a later attempt succeeds
    then the invocation completes normally
  while no attempt succeeds within twenty-four hours of the first failure
    then the invocation abandons the failed work
    and no error artefact is written to the Reflection's Destination
    and its callback receives the produced artefact, when one exists, and the abandonment outcome

when Reflection production or Destination delivery reports a non-retryable client failure
  then the invocation abandons the failed work without retry
  and no error artefact is written to the Reflection's Destination
  and its callback receives the produced artefact, when one exists, and the abandonment outcome

when a consuming agent terminates during Reflection work
  then that agent's unfinished work terminates with its Gralkor runtime
  and the invocation callback is not invoked

when recall's outermost deadline expires
  then recall returns without retrying and logs the expiry as a warning
