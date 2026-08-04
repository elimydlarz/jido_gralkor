Journey: jido-memory-journey (journey: test/functional/jido_memory_journey_test.exs)

while memory runs against a real embedded Python runtime, real graph extraction, an embedded FalkorDB, and the configured LLM
  when a fact is written directly into an operator's memory
  and a later recall asks a related question from a fresh session
    then a delimited memory block marked as untrusted content is returned
    and the block semantically references the written fact
  when a captured turn is flushed for its session
    then the flush is accepted without waiting for the episode to be ingested
    and the turn's content later becomes recallable under the same operator group from a different session
  while learning is wired into the flush
    when a captured turn whose reasoning solved a problem is flushed
      then a memory search restricted to Learning nodes and keyed on that kind of problem returns a learning
      and the returned learning carries the lesson the turn arrived at
      and a later full recall keyed on the same kind of problem surfaces that lesson
