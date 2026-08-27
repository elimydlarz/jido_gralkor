Functional: jido-context-rotation (src: lib/jido_gralkor/context_rotator.ex; functional: test/functional/jido_context_rotation_functional_test.exs)

when an application rotates a running agent whose committed thread flushes successfully
  then the application receives success
  and the committed session is flushed with the caller's timeout
  and the active session is replaced
  and the fresh session retains only the requested newest committed entries
  and every entry arriving during the flush is retained exactly once

when an application rotates a running agent whose committed thread fails to flush
  then the application receives the failure
  and the active session remains unchanged

when an application rotates a running agent whose flush succeeds but fresh-session installation fails
  then the application receives the installation failure
  and the active session remains unchanged
  and the running agent remains available

when an application rotates a running agent with no committed thread
  then the application receives success
  and no flush is requested
  and no session is committed

if an application asks to rotate an agent whose state cannot be read
  then the application receives a state-read failure rather than false success
