Unit: reflection-scheduler (src: lib/gralkor/reflection/scheduler.ex, lib/gralkor/reflection/artefact.ex, lib/gralkor/reflection/journal.ex; unit: test/gralkor/reflection/scheduler_test.exs)

when completed ingestion schedules distinct Reflections
  then each operator, ingestion identifier, and Reflection name forms one logical completion key
  and each key receives one deterministic UUID that remains stable across Scheduler processes
  and different operators, ingestions, or Reflection names receive different UUIDs

when the same logical completion is scheduled concurrently
  then only one Runner attempt is active
  and later scheduling reports that the logical completion is already admitted

when several Reflections share one ingestion
  then each Reflection has independent admission, execution phase, retry state, and completion
  and adding a new Reflection name admits it without disturbing completed siblings

when a Runner attempt succeeds
  then its artefact is durably retained before canonical storage begins
  and canonical storage receives that exact artefact without rerunning the Runner
  and canonical storage success completes and releases the logical work

when a Runner attempt returns an error, crashes, or exceeds its execution timeout
  then only that Runner phase is retried after each configured bounded delay
  and every attempt receives the same deterministic artefact identifier
  and an expired attempt is stopped before its replacement begins

when a Runner, lookup, or storage task cannot start
  then that phase consumes one attempt and follows the configured bounded retry schedule

when canonical lookup returns an error, crashes, or exceeds its execution timeout
  then lookup follows the configured bounded storage retry schedule
  and an immutable-content conflict ends without retry

when a canonical storage attempt returns an error, crashes, or exceeds its execution timeout
  then only that storage phase is retried after each configured bounded delay
  and every attempt receives the exact artefact retained from the successful Runner
  and an expired attempt is stopped before its replacement begins

when a retryable phase consumes every configured retry
  then the logical work ends in an observable terminal failure
  and the notification identifies the Reflection name, failed phase, attempt count, and final reason
  and the logical work's in-memory admission and durable unfinished record are released

when canonical storage reports an artefact conflict
  then the conflict ends without retry
  and terminal failure identifies the storage phase and conflict

when the Scheduler process starts with durable unfinished work
  then every retained Runner or storage phase resumes with its retained retry state
  and retained storage work uses its exact retained artefact
  and already canonical work is confirmed complete without rerunning its Runner
  while the previous Scheduler stopped during an active attempt
    then that interrupted attempt consumes the durable retry budget before work resumes
  while the previous Scheduler stopped during an active storage attempt
    then canonical lookup first confirms whether that uncertain attempt completed
    and a confirmed artefact completes even when no storage retry remains

when the Scheduler stops during a configured retry delay
  then the durable retry deadline survives restart
  and the next attempt does not begin before the remaining delay elapses

when the Scheduler is asked to drain
  then the caller waits while admitted logical work can still complete or exhaust retries
  and every waiting caller is released after all logical work ends
  and later scheduling is rejected so no work can escape the drain boundary

if scheduling receives an incomplete ingestion, a missing or blank operator or ingestion identifier, or duplicate Reflection names
  then scheduling fails before durable admission or Runner execution
  and the failure identifies the invalid value or duplicated name

when scheduling receives no Reflections
  then scheduling succeeds without retaining admission or durable work

if retry delays are not a finite list of non-negative integer milliseconds or the execution timeout is not a positive integer
  then Scheduler startup or scheduling rejects the invalid boundedness configuration
