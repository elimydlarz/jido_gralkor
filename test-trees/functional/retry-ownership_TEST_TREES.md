Functional: retry-ownership (src: lib/gralkor/capture_buffer.ex, lib/gralkor/client.ex, lib/gralkor/destination/storage.ex, lib/gralkor/reflection/runner.ex, lib/jido_gralkor/runtime.ex; functional: test/functional/retry_ownership_functional_test.exs)

when a capture callback returns an upstream rate-limit failure
  then the capture buffer does not retry the returned failure and logs it

when a capture callback returns another upstream failure
  then the capture buffer does not retry it and returns it unchanged

when a graph write raises inside a capture chain
  then the capture buffer retries with its default one-second and two-second backoffs
  and a returned write failure is not retried by a second layer

when a graph write fails outside a capture chain
  then the direct caller receives the failure after one attempt

when Reflection production, packaged generalisation related-memory retrieval, or Destination delivery reports a retryable server failure
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
