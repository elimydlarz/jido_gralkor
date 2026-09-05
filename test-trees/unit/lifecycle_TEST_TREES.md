Unit: lifecycle (src: lib/jido_gralkor/lifecycle.ex; unit: test/jido_gralkor/lifecycle_test.exs)

when a consumer wires the module as an agent server's lifecycle
  then it declares the Jido agent-server lifecycle behaviour, so the agent server calls terminate on graceful stop
  and initialisation hands back the agent server's state unchanged, so wiring it in alters nothing about the agent
  and every lifecycle event it is handed continues to the rest of the server with state unchanged, so it observes without intercepting

when the agent server terminates
  while a thread is committed to agent state
    then that thread's buffered-memory flush is scheduled before termination returns
    and termination does not wait for the scheduled ingestion to complete
    and the flush is logged at info naming the session id and the terminate reason
    if the flush call fails
      then the failure is logged
      and termination completes normally regardless
  while no thread is committed to agent state
    then no flush is requested at all
