Functional: reflection-completion (src: lib/gralkor/artefact.ex, lib/gralkor/client.ex, lib/gralkor/destination/storage/in_memory.ex, lib/gralkor/destination/storage/graphiti.ex, lib/gralkor/graphiti_pool.ex; functional: test/functional/reflection_completion_functional_test.exs)

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
      and Graphiti resumes the normal extraction path before reporting success
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
