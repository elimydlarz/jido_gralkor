Functional: reflection-completion (src: lib/gralkor/application.ex, lib/gralkor/client.ex, lib/gralkor/ingest.ex, lib/gralkor/capture_buffer.ex, lib/gralkor/artefact.ex, lib/gralkor/artefact/return_handler.ex, lib/gralkor/destination/storage/in_memory.ex, lib/gralkor/destination/storage/graphiti.ex, lib/gralkor/reflection/runner.ex, lib/gralkor/reflection/supervisor.ex, lib/gralkor/reflection/scheduler.ex, lib/gralkor/reflection/journal.ex, lib/gralkor/graphiti_pool.ex; functional: test/functional/reflection_completion_functional_test.exs)

when an application invokes eligible Reflections with a non-blank `invocation_id`
  then the triggering operation returns without waiting for Reflection artefacts
  and each Reflection has the logical work identity `{operator_id, invocation_id, reflection_name}`
  and each Reflection produces one artefact whose stable identifier represents that logical work
  and each declared output independently receives that exact artefact

when overlapping triggers invoke the same `{operator_id, invocation_id, reflection_name}`
  then at most one Runner execution for that logical work is active at a time
  and at most one canonical artefact for that logical work becomes searchable

when one invocation admits several eligible Reflections
  while one Reflection finishes every output
  and another Reflection fails before finishing every output
    then the finished Reflection remains finished
    and the failed Reflection is retried independently
    and retrying the failed Reflection does not rerun the finished Reflection

when a Reflection Runner returns an error or crashes
  then the Scheduler retries that Runner on its bounded backoff schedule
  and each Runner attempt receives the same logical artefact identifier
  and host tools invoked before an interrupted Runner attempt are treated as at-least-once side effects

when a Runner task cannot start
  then the task-start failure consumes one attempt on the bounded Runner retry schedule
  and a later successful attempt can produce the same logical artefact

when a Reflection Runner does not finish within its execution timeout
  then that attempt exits before its replacement starts
  and the timeout follows the same bounded Runner retry schedule

when a retryable Runner failure consumes every configured retry
  then terminal failure is observable with the Reflection name, Runner stage, attempt count, and final reason

when a Reflection Runner produces an artefact
  then the Scheduler durably retains that exact artefact before any output begins
  and every configured output has independent durable attempt state
  and no output failure reruns the successful Runner

  while the Destination output succeeds
    then the artefact becomes canonically searchable through that Destination

  while the return output succeeds
    then its handler's `return/3` callback receives the operator identifier, invocation identifier, and exact artefact

  while one output succeeds and another output requires retry
    then the successful output remains successful
    and only the failed output follows its bounded retry schedule

if a Destination output fails, crashes, or does not finish within its execution timeout
  then the Scheduler retries only that Destination output without rerunning the Runner or another successful output
  and every Destination attempt receives the exact artefact retained from the Runner
  when the retry schedule is exhausted
    then terminal failure is observable with the Reflection name, Destination output kind, and final reason

if a return output fails, crashes, or does not finish within its execution timeout
  then the Scheduler retries only that return output without rerunning the Runner or another successful output
  and every return attempt receives the same operator identifier, invocation identifier, and exact artefact
  when the retry schedule is exhausted
    then terminal failure is observable with the Reflection name, return output kind, and final reason
    and a successful Destination output remains searchable

when a return handler accepts an artefact but its response is lost
  then the Scheduler retries the return output with the same artefact identifier
  and the handler may receive that artefact more than once
  and the stable artefact identifier permits the consumer to make repeated delivery idempotent

when a Destination output commits an artefact but its response is lost
  then the Scheduler retries the exact same artefact identifier
  and the retry converges on one canonical artefact
  and exactly one artefact for that logical work is searchable

when an invocation is replayed after one or more of its Reflections finished
  then canonical Destination output storage identifies every already finished Reflection without rerunning its Runner or finished outputs
  and a newly eligible Reflection for that invocation remains eligible to run and produce its artefact

when the supervised Reflection Scheduler crashes with unfinished work
  then the application restarts the Scheduler
  and the restarted Scheduler resumes every unfinished Runner and output from durable work state
  and every resumed output receives the exact artefact retained before restart
  and canonical Destination storage prevents already finished work from rerunning

when the application stops gracefully with unfinished Reflection work
  then shutdown waits for every admitted Runner and output to finish or exhaust its bounded retry schedule
  and no admitted Reflection or output task is silently abandoned
  while a fire-and-forget capture flush is already running
    then shutdown waits for that flush to admit its Reflection and for every admitted output to finish
  while the supervised Scheduler was restarted after CaptureBuffer began
    then shutdown drains the current replacement Scheduler
  while CaptureBuffer began with no declared Reflections
    then shutdown still drains Reflection work admitted through the Scheduler
  while the supervised Scheduler exits during its drain call
    then shutdown waits for the replacement Scheduler and drains it

when repeated Destination writes use the same artefact identifier and immutable payload
  then the first write creates the artefact
  and every later write reports success without creating another artefact

if repeated Destination writes use the same artefact identifier with a conflicting immutable payload
  then the repeated write is rejected as an artefact conflict
  and the original canonical artefact remains unchanged

where Graphiti stores a Destination artefact output
  when a new artefact is written with its stable identifier
    then Graphiti creates one episode under a deterministic UUID derived from that artefact identifier
    and the episode body contains exactly the artefact identifier and payload
    and Graphiti records durable extraction completion only after every graph effect succeeds
    if graph extraction fails before its claim-fenced transaction commits
      then canonical lookup and public artefact search report no episode
      and a later equal write retries extraction from scratch
  when that artefact is written again after an uncertain response
    while durable extraction completion was recorded
      then Graphiti confirms the existing episode without repeating extraction
    while the episode exists but extraction completion was not recorded
      then canonical lookup retains the exact episode artefact as incomplete rather than reporting success
      and public artefact search excludes that incomplete artefact
      and Graphiti resumes the normal extraction path without rerunning the Runner before reporting success
    and exactly one episode carrying that artefact remains searchable
  when artefact search encounters historical complete episodes carrying the same artefact identifier
    while their immutable payloads are equal
      then search returns one artefact
    while their immutable payloads conflict
      then search reports an artefact conflict
  when incomplete or duplicate episodes outnumber the requested result window
    then they cannot crowd completed unique artefacts out of the requested results
    and conflicts for selected artefact identifiers are detected beyond the ranked window
  when independent application runtimes write the same artefact UUID concurrently
    then a graph uniqueness constraint exists before UUID claim admission
    and graph-backed admission serializes extraction across runtimes
    and equal payloads converge while conflicting payloads are rejected
    while a claim lease changes owner
      then graph-server time determines expiry
      and the episode plus every derived node and edge persist in one claim-fenced graph transaction
      and loss of ownership aborts that transaction before any graph effect commits
      and the completion marker is fenced by the current claim generation
      and a stale owner cannot mutate or finish the artefact output
  when upgrading from an unmarked pre-completion-marker artefact
    then it remains hidden until an explicit replay or migration establishes durable extraction completion
    and upgrade behavior does not expose a possibly partial episode as completed

where in-memory Destination storage receives an artefact output
  when the same artefact is written repeatedly
    then exactly one copy remains searchable in its original insertion position

if public ingestion omits or supplies a blank operator or stable ingestion identifier
  then ingestion raises before any Lens ingestion, Runner execution, or artefact output begins

if scheduling receives duplicate Reflection names
  then scheduling fails before any Runner execution begins
  and the duplicated Reflection name is identified

when Reflection work finishes or exhausts its retry schedule
  then its in-memory admission state and durable unfinished-work record are released
