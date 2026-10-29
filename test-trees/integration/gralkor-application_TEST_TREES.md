Integration: gralkor-application (src: lib/gralkor/application.ex, lib/gralkor/graphiti_pool.ex; integration: test/gralkor/application_integration_test.exs)

when the application starts
  while a data directory is configured and no remote connection is configured
    then startup returns only once the Python runtime, graph pool, and capture buffer have initialised

when a capture flush runs
  while no episode-writing dependency is supplied
    then default writes name the graph pool server explicitly and reach it without shifted arguments
    and the logical group is encoded exactly once by that graph pool boundary
