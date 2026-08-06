Unit: generalise (src: lib/gralkor/generalise.ex; unit: test/gralkor/generalise_test.exs)

when the structured-output schema for hypothesising is requested
  then it requires the generalisations as a list of maps
  and it tells the model each entry carries content and a confidence between 0.0 and 1.0

when the structured-output schema for evaluating is requested
  then it requires the decisions as a list of maps
  and it tells the model each decision carries an action, the hypothesis index, a confidence and the content to save
  and it tells the model which actions are available

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
  then the contradicting generalisation is persisted one level above the existing one
  and it records the existing generalisation's id as generalised
  and the existing generalisation is left in place, because the graph library owns episode identity and a generalisation's id cannot address its episode

when evaluation decides to skip a candidate
  then no episode is added

when any decision persists a new generalisation
  then the episode write supplies no episode identifier, so the graph library mints a new episode instead of failing to find one to update
  and the generalisation's own id travels in the episode body, where it records lineage between generalisations

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
