Functional: reflection-completion (src: lib/gralkor/application.ex, lib/gralkor/client.ex, lib/gralkor/ingest.ex, lib/gralkor/capture_buffer.ex, lib/gralkor/reflection/artefact.ex, lib/gralkor/reflection/runner.ex, lib/gralkor/reflection/scheduler.ex, lib/gralkor/reflection/journal.ex, lib/gralkor/reflection/store.ex, lib/gralkor/reflection/storage/in_memory.ex, lib/gralkor/reflection/storage/graphiti.ex, lib/gralkor/graphiti_pool.ex; functional: test/functional/reflection_completion_functional_test.exs)

when an application ingests information under a stable ingestion identifier while Reflections are declared
  then ingestion returns without waiting for Reflection completion
  and each Reflection has one logical completion identity combining the operator, ingestion, and Reflection names
  and each completed Reflection stores one artefact whose stable identifier represents that logical completion
  and every completed artefact remains searchable through its Reflection's Destination

when overlapping requests schedule the same operator, ingestion, and Reflection
  then at most one Runner execution for that logical completion is active at a time
  and at most one canonical artefact for that logical completion becomes searchable

when one ingestion schedules several Reflections
  while one Reflection completes canonical storage
  and another Reflection fails before canonical storage
    then the completed Reflection remains completed
    and the failed Reflection is retried independently
    and retrying the failed Reflection does not rerun the completed Reflection

when a Reflection Runner returns an error or crashes
  then the Scheduler retries that Runner on its bounded backoff schedule
  and each Runner attempt receives the same logical artefact identifier
  and host tools invoked before an interrupted Runner attempt are treated as at-least-once side effects

when a Reflection Runner does not finish within its execution timeout
  then that attempt exits before its replacement starts
  and the timeout follows the same bounded Runner retry schedule

when a retryable Runner failure consumes every configured retry
  then terminal failure is observable with the Reflection name, Runner stage, attempt count, and final reason

when a Reflection Runner produces an artefact
  if canonical storage fails, crashes, or does not finish within its execution timeout
    then the Scheduler retries canonical storage without rerunning the Runner
    and every storage attempt receives the exact same artefact
    when the retry schedule is exhausted
      then terminal failure is observable with the Reflection name, storage stage, and final reason

when canonical storage commits an artefact but its response is lost
  then the Scheduler retries the exact same artefact identifier
  and the retry converges on one canonical artefact
  and exactly one artefact for that logical completion is searchable

when an ingestion is replayed after one or more of its Reflections completed
  then canonical storage identifies every already completed Reflection without rerunning its Runner
  and a newly declared Reflection for that ingestion remains eligible to run and complete

when the supervised Reflection Scheduler crashes with unfinished work
  then the application restarts the Scheduler
  and the restarted Scheduler resumes every unfinished logical completion from durable work state
  and canonical storage prevents already committed work from rerunning

when the application stops gracefully with unfinished Reflection work
  then shutdown waits for every admitted Reflection to complete or exhaust its bounded retry schedule
  and no admitted Reflection task is silently abandoned
  while the supervised Scheduler was restarted after CaptureBuffer began
    then shutdown drains the current replacement Scheduler

when repeated canonical writes use the same artefact identifier and immutable content
  then the first write creates the artefact
  and every later write reports success without creating another artefact

if repeated canonical writes use the same artefact identifier with conflicting immutable content
  then the repeated write is rejected as an artefact conflict
  and the original canonical artefact remains unchanged

where Graphiti is the canonical Reflection store
  when a new artefact is written with its stable identifier
    then Graphiti creates one episode under a deterministic UUID derived from that artefact identifier
    and Graphiti records durable extraction completion only after every graph effect succeeds
  when that artefact is written again after an uncertain response
    while durable extraction completion was recorded
      then Graphiti confirms the existing episode without repeating extraction
    while the episode exists but extraction completion was not recorded
      then Graphiti resumes the normal extraction path before reporting success
    and exactly one episode carrying that artefact remains searchable

where in-memory storage is the canonical Reflection store
  when the same artefact is written repeatedly
    then exactly one copy remains searchable in its original insertion position

if public ingestion omits or supplies a blank stable ingestion identifier
  then ingestion raises before any Lens ingestion, Runner execution, or canonical write begins

if scheduling receives duplicate Reflection names
  then scheduling fails before any Runner execution begins
  and the duplicated Reflection name is identified

when an ingestion completes while no Reflections are declared
  then ingestion succeeds without retaining scheduler work

when Reflection work completes or exhausts its retry schedule
  then its in-memory admission state and durable unfinished-work record are released
