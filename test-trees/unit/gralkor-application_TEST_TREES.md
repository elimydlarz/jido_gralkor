Unit: gralkor-application (src: lib/gralkor/application.ex; unit: test/gralkor/application_test.exs)

when the application starts
  while a remote FalkorDB connection is configured
    then the Python runtime and graph pool are supervised in that order
    and the graph pool is constructed with the remote connection, so no embedded server is spawned
    and the graph pool receives no embedded socket timeout
    and the Python runtime is told not to sweep for orphaned embedded servers, this deployment never having spawned one
    and a configured data directory is ignored
  while a data directory is configured
    while no remote connection is configured
      then the Python runtime and graph pool are supervised in that order
      and the graph pool is constructed with the embedded connection
      and the graph pool receives the configured embedded socket timeout
      and the Python runtime is told to sweep for orphaned embedded servers, this deployment spawning one of its own
  while neither a remote connection nor a data directory is configured
    then no children are supervised, because the consumer has not opted into the native runtime
  while the in-memory client is configured
    then no children are supervised regardless of configured local or remote storage

if the remote FalkorDB configuration is not a keyword list carrying a host and a port
  then startup raises before any child starts

if the retired `:reflection_storage` setting is configured
  then application startup fails identifying Destination outputs as the artefact memory boundary
