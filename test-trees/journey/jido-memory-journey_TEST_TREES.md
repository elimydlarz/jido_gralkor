Journey: jido-memory-journey (journey: test/functional/jido_memory_journey_test.exs)

when a fact is written before a fresh-session recall
  then the untrusted memory response semantically references the written fact

when a captured turn is flushed before a fresh-session recall
  then the turn becomes recallable under the same operator group

when a solved turn is flushed with learning enabled
  then its lesson survives Learning-node retrieval and full recall
