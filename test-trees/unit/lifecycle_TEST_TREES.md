Unit: lifecycle (src: lib/jido_gralkor/lifecycle.ex; unit: test/jido_gralkor/lifecycle_test.exs)

when a consumer wires the module as an agent server's lifecycle
  then it declares the Jido agent-server lifecycle behaviour, so the agent server calls terminate on graceful stop

when the agent server terminates
  while a thread is committed to agent state
    then that thread's buffered memory is flushed without blocking termination
    and the flush is logged at info naming the session id and the terminate reason
    if the flush call fails
      then the failure is logged
      and termination completes normally regardless
  while no thread is committed to agent state
    then no flush is requested at all
