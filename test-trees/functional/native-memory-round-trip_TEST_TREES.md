Functional: native-memory-round-trip (src: lib/gralkor/client/native.ex, lib/gralkor/recall.ex, lib/gralkor/capture_buffer.ex, lib/gralkor/application.ex; functional: test/functional/native_memory_round_trip_functional_test.exs)

while the native adapter runs against a deterministic graph and the configured model
  when a fact is written into an operator's memory
    then the write reaches the graph as a plain-text episode under that operator's group
    when a later recall from a session that never held the conversation asks about it
      then the answer comes back inside a delimited memory block marked as untrusted content
      and the block carries what interpretation kept of the facts the graph returned
      and the query itself reaches interpretation, so relevance is judged against what was asked
  when a captured turn is flushed for its session
    then the flush is accepted without waiting for the episode to be ingested
    and the rendered transcript reaches the graph as a captured episode under the session's group
    and the session's buffered turns are consumed, so a second flush writes nothing
  while learning is wired into the flush
    when a captured turn is flushed
      then the turn's learning reaches the graph as its own episode, asking for the built-in Learning entity type
      and a later recall combines what the learning search returns with the regular facts before interpretation
  if the graph fails the search a recall runs
    then that failure is returned to the caller
    and no memory block is manufactured
