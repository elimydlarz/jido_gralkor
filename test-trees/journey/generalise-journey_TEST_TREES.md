Journey: generalise-journey (src: lib/gralkor/generalise.ex, lib/gralkor/graphiti_pool.ex; journey: test/functional/generalise_journey_test.exs)

while generalisation is wired into the capture flush
  when a captured turn is flushed for its session
    then each generalisation the pipeline decides to keep is saved into the group's `_gen` partition
    and searching that partition for the generalised subject returns at least one fact naming it

when a generalisation is stored directly into a group's `_gen` partition as an episode
  then searching that partition for the generalisation's subject returns at least one result
  and the extracted facts carry the generalisation's plain content
