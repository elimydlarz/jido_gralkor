Functional: graph-operation-deadlines (src: lib/gralkor/python.ex, lib/gralkor/graphiti_pool.ex, lib/gralkor/config.ex, lib/gralkor/application.ex; functional: test/functional/graph_operation_deadlines_functional_test.exs)

when the remote runtime starts
  while no remote FalkorDB socket timeout is configured
    then the remote connection uses a sixty-second socket timeout
  while a positive `:remote_falkordb_socket_timeout_ms` is configured
    then the remote connection uses that timeout
  while no remote FalkorDB connection cap is configured
    then the remote connections are capped at one hundred
  while a positive `:remote_falkordb_max_connections` is configured
    then the remote connections are capped at that number

if `:remote_falkordb_socket_timeout_ms` is not a positive integer
  then application startup raises naming the setting and its offending value

if `:remote_falkordb_max_connections` is not a positive integer
  then application startup raises naming the setting and its offending value

when the runtime starts
  while no graph operation deadline is configured
    then graph operations use a thirty-minute deadline

if `:graph_operation_deadline_ms` is not a positive integer
  then application startup raises naming the setting and its offending value

when a remote FalkorDB accepts a connection and never replies
  then an episode write returns `{:error, :timeout}`
  and runtime-targeted Lens ingestion returns `{:error, :timeout}`
  and the timeout is logged with the stage it hit

when a graph operation outlasts `:graph_operation_deadline_ms`
  then the episode write returns `{:error, :timeout}` within the deadline
  and the outstanding graph work is cancelled
  and the timeout is logged with the stage it hit
  and the next graph operation still runs

while every remote FalkorDB connection is in use
  when another graph operation needs a connection
    when a connection is released within the socket timeout
      then the waiting operation completes with its result
    if no connection is released within the socket timeout
      then the waiting operation returns `{:error, :timeout}`
      and the timeout is logged with the stage it hit

while more episode writes are waiting on the graph or a model provider than the virtual machine has dirty CPU schedulers
  then a memory search still returns its results without waiting for them
  and each waiting write returns once its wait ends
