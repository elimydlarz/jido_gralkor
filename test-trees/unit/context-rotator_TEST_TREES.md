Unit: context-rotator (src: lib/jido_gralkor/context_rotator.ex; unit: test/jido_gralkor/context_rotator_test.exs)

when a rotation seed is computed
  while every current entry was in the flushed set
    then the seed is the most recent entries up to the retention count
    while the retention count is zero
      then the seed is empty rather than falling back to any default retention
    while the retention count exceeds the number of flushed entries
      then every flushed entry is seeded
      and no more are invented
  while the current entries include in-flight entries that arrived after the flushed ones
    then those in-flight entries are seeded whatever the retention count is, so nothing mid-turn is lost
    and the retained entries precede the in-flight entries in the seed
    while there were no flushed entries at all
      then the seed is exactly the in-flight entries

when rotation is requested without option overrides
  then the flush uses a thirty-second timeout
  and the fresh thread retains the four newest pre-flush entries

if the configured flush call exits
  then rotation returns an error carrying the flush exit reason
  and the active session remains unchanged
