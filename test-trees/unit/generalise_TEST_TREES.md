Unit: generalise (src: lib/gralkor/generalise.ex; unit: test/gralkor/generalise_test.exs)

when a transcript is generalised
  then only hypothesised candidates at or above the minimum confidence reach evaluation
  and candidates reach evaluation sorted by confidence descending
  and the minimum confidence defaults to 0.3
  if every hypothesised candidate falls below the minimum confidence
    then nothing is persisted
  if no candidates are hypothesised at all
    then nothing is persisted

when evaluation decides to save a candidate
  then a new generalisation is persisted at level 0
  and it records no generalised ids
  and the persisted episode body is the encoded generalisation

when evaluation decides a candidate broadens an existing generalisation
  then a new generalisation is persisted one level above the existing one
  and it records the existing generalisation's id as generalised
  and the existing generalisation is left active

when evaluation decides a candidate narrows an existing generalisation
  then a new generalisation is persisted one level above the existing one
  and it records the existing generalisation's id as generalised
  and the existing generalisation is left active

when evaluation decides a candidate contradicts an existing generalisation
  where a removal function is supplied
    then the existing generalisation is removed by its id before the replacement is written

when evaluation decides to skip a candidate
  then no episode is added

when any decision persists a new generalisation
  then the episode write receives the generalisation's id as the episode uuid
  and that uuid is the same id encoded in the episode body, so later updates and deletes address it

when the existing generalisation named by a decision is found among the searched generalisations
  then the new generalisation's level is one above that existing level

if the existing generalisation named by a decision is not found
  then the new generalisation's level is 0

if the hypothesis model call fails
  then generalisation still returns :ok
  and the failure is logged

if the evaluation model call fails
  then generalisation still returns :ok
  and nothing is persisted

if the search for existing generalisations fails
  then evaluation continues against an empty existing list

if an episode write fails
  then the failure is logged
  and the remaining decisions are still applied
