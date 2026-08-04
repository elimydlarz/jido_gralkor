Journey: remote-falkordb-journey (journey: test/functional/remote_falkordb_journey_test.exs)

while memory is configured to reach a real FalkorDB over the network instead of the embedded one
  when a fact is written directly into an operator's memory
  and a later recall asks a related question from a fresh session
    then a delimited memory block marked as untrusted content is returned
    and the block semantically references the fact held in the remote graph
  when a captured turn is flushed for its session with an await budget
    then the awaited flush reports success only once the episode has been handed to the remote graph
    and a follow-up recall surfaces the turn's content from the remote graph
  when the whole remote-backed journey has finished exercising memory
    then no local embedded redis-server process was started at any point during the run
