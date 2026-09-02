Functional: native-memory-round-trip (src: lib/gralkor/client.ex, lib/gralkor/client/native.ex, lib/gralkor/graphiti_pool.ex, lib/gralkor/recall.ex, lib/gralkor/capture_buffer.ex, lib/gralkor/application.ex; functional: test/functional/native_memory_round_trip_functional_test.exs)

when a fact is written into an operator's memory
  then the graph stores its plain text unchanged
  and the graph named `operator/<operator id>` receives it

when facts are written for logical operator graphs that previously normalised to the same name
  then each logical graph identifier is encoded exactly once at the physical Graphiti boundary
  and the pool constructs and caches a distinct physical graph instance for each logical graph

when memory search returns facts for recall
  then every returned fact is presented verbatim and in order inside an untrusted memory block
  and every returned fact retains its available source wording

when a captured turn is flushed for its session
  then flush returns before graph ingestion completes
  and the rendered transcript eventually reaches the session's group with trusted `operator` Lens provenance
  and a second flush writes no duplicate transcript

if the graph fails a recall search
  then recall returns the graph failure without a memory block
