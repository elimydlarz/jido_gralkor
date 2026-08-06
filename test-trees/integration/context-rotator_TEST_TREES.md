Integration: context-rotator (src: lib/jido_gralkor/context_rotator.ex; integration: test/integration/context_rotator_integration_test.exs)

when context rotation is requested
  while the agent has a committed thread
    while its session flush succeeds
      then exactly one flush is requested, naming the pre-rotation session id and the caller's flush timeout
      and the agent's active session id becomes a new one
      and the agent process is still running afterwards
      while recent entries are retained
      and the thread holds more
        then only that many newest entries seed the rotated thread
      while no entries are retained
      and every prior entry was flushed
        then the rotated thread is empty
      while entries arrive after flushing and before the fresh thread is installed
        then every in-flight entry is carried into the fresh thread exactly once
    if installing the fresh thread fails after flushing
      then the failure reason is returned to the caller
      and the agent process is still running afterwards
    if its session flush fails
      then the failure reason is returned to the caller
      and the active session id is left unchanged
      and the agent process is still running afterwards
  while the agent has no committed thread
    then rotation succeeds without requesting any flush
    and no session is committed as a side effect
    and the agent process is still running afterwards
