Integration: context-rotator (src: lib/jido_gralkor/context_rotator.ex; integration: test/integration/context_rotator_integration_test.exs)

when a running agent is asked to rotate its context now
  while a thread is committed to the agent
    while the flush of the committed session succeeds
      then exactly one flush is requested, naming the pre-rotation session id and the caller's flush timeout
      and the agent's active session id becomes a new one
      and the agent process is still running afterwards
      while the caller retains recent entries and the thread holds more than that
        then the rotated thread is seeded with only that many most recent entries, dropping everything before them
      while the caller retains nothing and every pre-rotation entry was already flushed
        then the rotated thread starts empty
    if the flush of the committed session fails
      then the failure reason is returned to the caller
      and the active session id is left unchanged
      and the agent process is still running afterwards
  while no thread is committed to the agent
    then rotation succeeds without requesting any flush
    and no session is committed as a side effect
    and the agent process is still running afterwards
