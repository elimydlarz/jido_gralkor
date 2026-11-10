Integration: gralkor-application (src: lib/gralkor/application.ex, lib/gralkor/graphiti_pool.ex; integration: test/gralkor/application_integration_test.exs)

when the application starts
  while a data directory is configured and no remote connection is configured
    then startup returns only once the Python runtime and graph pool have initialised
