Functional: jido-context-rotation (src: lib/jido_gralkor/context_rotator.ex; functional: test/functional/jido_context_rotation_functional_test.exs)

when an application rotates a running agent whose committed thread flushes successfully
  then the application receives success after the active session is replaced

when an application rotates a running agent whose committed thread fails to flush
  then the application receives the failure and the active session remains unchanged

when an application rotates a running agent with no committed thread
  then the application receives success without a flush or a new session

if an application asks to rotate an agent whose state cannot be read
  then the application receives a state-read failure rather than false success
