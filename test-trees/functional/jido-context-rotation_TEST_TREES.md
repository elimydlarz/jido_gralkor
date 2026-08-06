Functional: jido-context-rotation (src: lib/jido_gralkor/context_rotator.ex; functional: test/functional/jido_context_rotation_functional_test.exs)

when an application rotates a running agent's memory context
  while a thread is committed
    while its buffered memory flush succeeds
      then the application receives success after the active session is replaced
    if its buffered memory flush fails
      then the application receives the failure and the active session remains unchanged
  while no thread is committed
    then the application receives success without a flush or a new session

if an application asks to rotate an agent whose state cannot be read
  then the application receives a state-read failure rather than false success
