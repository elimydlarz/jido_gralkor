Functional: native-memory-round-trip (src: lib/gralkor/client/native.ex, lib/gralkor/recall.ex, lib/gralkor/capture_buffer.ex, lib/gralkor/application.ex; functional: test/functional/native_memory_round_trip_functional_test.exs)

when a fact is written into an operator's memory
  then the graph stores its plain text under the operator's group
  and a fresh recall returns query-relevant facts inside an untrusted memory block

when a captured turn is flushed for its session
  then flush returns before graph ingestion completes
  and the rendered transcript eventually reaches the session's group
  and a second flush writes no duplicate transcript

when learning is enabled for a captured turn
  then flush stores the turn's learning with the built-in Learning entity type
  and recall combines relevant learning with relevant regular facts before interpretation

if the graph fails a recall search
  then recall returns the graph failure without a memory block
