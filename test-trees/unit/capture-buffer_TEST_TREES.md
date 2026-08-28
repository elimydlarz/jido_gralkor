Unit: capture-buffer (src: lib/gralkor/capture_buffer.ex, lib/gralkor/reflection/supervisor.ex, lib/gralkor/reflection/scheduler.ex; unit: test/gralkor/capture_buffer_test.exs)

when a turn is appended for a session that holds none
  then the turn is buffered and readable back for that session
  and it stays buffered until a flush is explicitly requested, the buffer having no idle-flush policy of its own
  and the entry binds the session to its group, agent name, user name, and ontology, the ontology being a module or nothing
  and the group it binds is the sanitised form of the group supplied
  and the bound group, agent name, user name, and ontology are what the flush callback later receives

when a further turn is appended for a session that already holds turns
  then it is buffered after the turns already held, which remain buffered

when turns are appended for several sessions
  then each session buffers its own turns independently of the others

if a turn is appended for an existing session under a different group
  then an argument error is raised, a session not being re-bindable across groups

if a turn is appended for an existing session under a different agent name
  then an argument error is raised

if a turn is appended for an existing session under a different user name
  then an argument error is raised, the human's identity being fixed at the session's first append

if a turn is appended for an existing session under a different ontology
  then an argument error is raised, one episode never mixing entity and edge schemas

if a turn without a Lens is appended for a session that already holds Lens-selected turns
  then an argument error is raised before the new turn is buffered, preserving the Lens-selected turns unchanged

if the agent name is missing or blank
  then an argument error is raised

if the user name is missing or blank
  then an argument error is raised

where captured turns select a Lens
  if no Lens is selected
    then an argument error is raised before any turn is buffered
  if a selected Lens name is missing or blank
    then an argument error is raised before any turn is buffered
  if a turn is appended for an existing session under a different operator
    then an argument error is raised, a session not being re-bindable across operators
  if a turn is appended for an existing session under a different agent name
    then an argument error is raised
  if a turn is appended for an existing session under a different user name
    then an argument error is raised
  if a Lens-selected turn is appended for a session that already holds turns without a Lens
    then an argument error is raised before the new turn is buffered, preserving the turns without a Lens unchanged
  when turns in one session select different Lenses
    then each turn stays associated with the Lens it selected
    and reading the session's turns back returns every turn in append order across Lenses
  when the session is flushed
    then the Lens flush callback receives one batch per Lens carrying only that Lens's turns
  when one captured turn is routed through a primary Lens and an additional Lens
    then every routed Lens receives that turn in its own batch
    but the session's buffered turns contain that turn only once
  when later turns contribute Reflection context
    then nested tool context is merged key by key
    and later context outside tool context replaces earlier context
  if one Lens's flush fails
    then every other Lens's batch is still attempted
    and an awaited flush reports the first failure only after every Lens has been attempted
  when every Lens batch for a completed ingestion succeeds and Reflections are declared
    then every completed representation retains the Lens identity supplied by its batch
    and every completed representation retains the evidence identity supplied by its batch
    and every declared Reflection is scheduled exactly once
    and each scheduled Reflection receives the completed representations
    and each scheduled Reflection receives the ingestion context
  if a completed representation does not carry its batch's Lens and evidence identity
    then the awaited flush reports the representation validation failure
    and no Reflection is scheduled
  if Reflection scheduling returns a failure or raises
    then the scheduling failure is logged
    and the successfully completed flush still reports success

when Reflection scheduling needs a scheduler
  while one is already running
    then that scheduler's registered identity is retained rather than duplicating it
    and a supervised replacement remains reachable through that identity
  while the capture buffer starts the scheduler it needs
    then stopping the buffer stops that owned scheduler
  while the scheduler is shared rather than owned by the buffer
    then stopping the buffer leaves it running

when a session's turns are read back before anything has been appended for it
  then nothing is returned

when a session's turns are read back after it has been flushed
  then nothing is returned

when a session holding turns is flushed without awaiting
  then the flush callback is scheduled with the session's group, agent name, user name, ontology, and every buffered turn
  and the call returns without waiting for the scheduled flush
  and the entry is removed, so reading the session's turns back returns nothing
  and a scheduled-flush line naming the session and its turn count is logged at info, so a successful flush is observable from logs alone

when a session holding no turns is flushed without awaiting
  then no flush is scheduled
  and an empty-flush line naming the session is logged at info, so an empty flush is distinguishable from no flush attempted

when a scheduled flush's callback succeeds, on its first attempt or after retries
  then a flush-completed line naming the turn count and the elapsed milliseconds is logged at info

if the flush callback reports a client contract error
  then the flush is dropped without any retry
  and a dropped-on-contract-error line is logged at warning

if the flush callback reports an upstream-LLM error
  then the flush is dropped without any retry, retrying only amplifying load on a struggling upstream
  and a dropped-on-upstream-error line is logged at warning

if the flush callback raises or fails for any other reason
  then the flush is retried on the configured backoff schedule, which defaults to 1s, then 2s, then 4s
  when the callback throws, exits, or returns a value outside its contract
    then the outcome is retried as a failure without stopping the buffer
  when that schedule is exhausted
    then the turns are dropped
    and an exhausted line is logged at error

when a session holding turns is flushed and awaited
  while the flush callback succeeds within the caller's timeout
    then success is returned
    and the entry is consumed, so reading the session's turns back returns nothing
    and a flush-completed event naming the session and its outcome is logged at info
  while the flush callback reports a client contract error
    then that error is returned without any retry
    and the entry is still consumed
  while the flush callback reports an upstream-LLM error
    then that error is returned without any retry
  while the flush callback fails for any other reason
    then the same configured backoff schedule applies, bounded by the caller's timeout
    when the callback throws, exits, or returns a value outside its contract
      then the outcome is retried as a failure without stopping the buffer
    when the retries together outlast that timeout
      then a timeout error is returned
  if the flush callback does not finish within the caller's timeout
    then a timeout error is returned
    and the buffered turns remain available to flush again
    and a timeout event naming the session is logged at warning

when a session holding no turns is flushed and awaited
  then success is returned without scheduling any flush
  and an empty-flush event naming the session is logged at info

when every buffered session is flushed at once
  then each session's turns go through the same flush callback and retry schedule
  and the call returns only once every one of those flushes has been awaited
  if one session's flush fails
    then the other sessions' flushes still complete
    and the call reports success after every session has been attempted

when a flush of every buffered session finds none buffered
  then the call returns immediately without invoking the flush callback

when a linked flush worker exits normally
  then nothing is logged for that exit, the flush having already replied
  and the buffer keeps running

if any other unexpected message arrives, a linked process exiting abnormally included
  then it is logged at error, so a genuine crash stays observable
  and the buffer keeps running

when the supervision tree stops the buffer
  then every pending entry is drained through the flush callback before termination returns
  and every already-started fire-and-forget flush worker finishes before Reflection draining begins
  and every Reflection admitted by those workers finishes before termination returns
  while the buffer started with no declared Reflections
    then work admitted directly or by a later Reflection registry is still drained
  while the Scheduler exits during its drain call
    then the buffer waits for its supervised replacement and drains that replacement before returning
