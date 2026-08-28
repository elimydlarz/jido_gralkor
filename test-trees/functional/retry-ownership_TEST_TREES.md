Functional: retry-ownership (src: lib/gralkor/capture_buffer.ex, lib/gralkor/client.ex, lib/gralkor/reflection/scheduler.ex, lib/gralkor/reflection/store.ex; functional: test/functional/retry_ownership_functional_test.exs)

when a capture callback returns an upstream rate-limit failure
  then the capture buffer does not retry the returned failure and logs it

when a capture callback returns another upstream failure
  then the capture buffer does not retry it and returns it unchanged

when a graph write raises inside a capture chain
  then the capture buffer retries with its default one-second and two-second backoffs
  and a returned write failure is not retried by a second layer

when a graph write fails outside a capture chain
  then the direct caller receives the failure after one attempt

when a Reflection Runner or canonical write fails after completed Lens ingestion
  then the Reflection Scheduler alone owns its bounded retry schedule
  and the Runner and canonical store each make one attempt when invoked by the Scheduler
  and no ingestion or capture layer retries the same Reflection failure

when recall's outermost deadline expires
  then recall returns without retrying and logs the expiry as a warning
