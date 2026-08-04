Integration: lifecycle (src: lib/jido_gralkor/lifecycle.ex; integration: test/integration/lifecycle_integration_test.exs)

when a running agent server is stopped gracefully
  while a thread is committed to its agent state
    then that thread's buffered memory is flushed exactly once, under the committed thread id
  while no thread is committed to its agent state
    then no flush is requested at all
