Functional: embedded-memory-writes (src: lib/gralkor/application.ex, lib/gralkor/config.ex, lib/gralkor/graphiti_pool.ex, lib/gralkor/client/native.ex; functional: test/functional/embedded_memory_writes_functional_test.exs)

when several episode writes overlap through one embedded runtime
  while the graph accepts every write
    then one episode write reaches the graph at a time
    and every caller receives success

when a memory search overlaps an episode write through one embedded runtime
  while the graph accepts the search
    then the search reaches the graph without waiting for episode write admission
    and the caller receives the search result

when several episode writes overlap through one remote runtime
  while the graph accepts every write
    then more than one episode write may reach the remote graph concurrently
    and every caller receives success

when the embedded runtime starts
  while no embedded FalkorDB socket read timeout is configured
    then the embedded connection uses a sixty-second socket read timeout
  while a positive `:embedded_falkordb_socket_timeout_ms` is configured
    then the embedded connection uses that timeout

if `:embedded_falkordb_socket_timeout_ms` is not a positive integer
  then application startup raises naming the setting and its offending value

when an episode relationship has no existing edge candidates
  then no vector edge search carrying an empty candidate filter is executed
  and no full-text edge search carrying an empty candidate filter is executed
  and episode addition continues
