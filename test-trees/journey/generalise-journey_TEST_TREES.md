Journey: generalise-journey (src: lib/gralkor/generalise.ex, lib/gralkor/graphiti_pool.ex; journey: test/functional/generalise_journey_test.exs)

while generalisation is wired into the capture flush
  when a captured turn is flushed for its session
    then each generalisation the pipeline decides to keep is saved into the `_gen` group derived from the session's group id
    and searching that group for the generalised subject returns at least one memory naming it, whether the stored episode or something extracted from it

when a generalisation is stored directly into a `_gen` group as an episode
  then searching that group for the generalisation's subject returns at least one result
  and what comes back carries the generalisation's plain content
