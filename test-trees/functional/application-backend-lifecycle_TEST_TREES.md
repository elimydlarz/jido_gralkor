Functional: application-backend-lifecycle (src: lib/gralkor/application.ex, lib/gralkor/capture_buffer.ex, lib/gralkor/client.ex, lib/gralkor/graphiti_pool.ex; functional: test/functional/application_backend_lifecycle_functional_test.exs)

when an application starts with a remote memory backend
  then the native memory runtime starts without owning an embedded server
  and buffered Lens capture flushes without resolving or invoking configured Reflections
  and application compatibility capture does not require an owning agent runtime

when an application starts with an embedded memory backend
  then the native memory runtime starts with an embedded server owned for that application's lifetime
  when the application stops
    then the owned embedded server exits before shutdown completes

if an application starts with invalid remote memory-backend configuration
  then startup raises before the native memory runtime starts
  and the error identifies the invalid configuration

when an application starts without a configured memory backend
  then it starts without the native memory runtime
