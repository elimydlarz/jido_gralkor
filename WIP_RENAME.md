# Personal memory naming and capture correction

Status: implementation, complete package Functional/Journey, and both Stop gates verified; final Phil Journey and independent review in progress, 2026-09-15. The operator explicitly authorized this document end to end across both repositories, including contract reconciliation, implementation, isolated migration/rollback verification, and final independent review. Publication, deployment, and live-data migration remain outside that authorization.

Implemented decisions: `Gralkor.Capture` is the typed runtime-targeted request; `{:direct, destination}` and `{:lenses, names}` dispatch exclusively. Mounts require `capture_destination`. The packaged names are `personal-chat` and `personal`, with unchanged operator identifiers. Positional capture calls raise migration guidance. Direct provenance is storage-owned, and historical provenance remains unchanged. Phil has guarded persisted-configuration migration and archival delivery/projection routing that retains original snapshots and hashes.

Verification so far: affected package capture, search, configuration, ERL, and replacement Functional checks pass in isolated builds. All 44 migration Functional tests pass, including bounded copy failure, safe late-copy adoption, controlled server recovery, migration-client interruption, restored synthetic RDB backup, public historical reads, replay, and guarded rollback. Coordinated graph/configuration/application rollback passed using the actual prior Phil/package revisions. Phil passed 608 full Functional tests, 796 Unit/Integration tests through its installed Stop gate, and 85 affected Functional tests against the shutdown-corrected package. The package Stop gate, formatting, README sync, and whitespace checks passed at their recorded checkpoints. Section 9 records the evidence and its limits.

The recorded stale-write race was reproduced with delayed claim theft and fixed with an explicit extraction barrier in the fixture. The 75ms recall diagnostic reproduced deadline expiry during startup while proving correct deadline forwarding; the fixture now separates forwarding from actual deadline expiry, which remains covered independently. The operator has now specifically approved the complete package Functional suite and both isolated real-provider Journeys, including their fixture payloads and OpenAI API destination. Those gates are being run sequentially with isolated resources. The final independent review follows them, so the overall task is not yet complete.

The requirements and original source findings below remain the acceptance checklist. “Current” findings and historical line anchors describe the pre-implementation baseline unless a completion note states otherwise.

Primary repository: `/Users/eli/code/os/jido_gralkor`.
Consumer repository: `/Users/eli/code/fasset/fasset-intelligence-lab/phil`.
Inspected package version: `10.0.0`. Recheck both checkouts and their instructions before implementation.

## 1. Operator intention and revised scope

The operator initially requested removal of the packaged `operator` Lens, explicit direct conversation capture to the private Destination, truthful provenance, historical recall, unchanged Reflection routing, and an exact Phil migration. They then revised the naming:

- Replace the packaged `operator` Lens with `personal-chat`, describing its conversation-ingestion purpose.
- Replace the packaged `operator` Destination with `personal`.
- Consumers select the name `personal`; Gralkor resolves it to `personal/<identifier>` using the separately supplied identity, as the existing resolver does for `operator`.

These later decisions supersede the earlier removal-only proposal. They also supersede preserving the literal `operator/<identifier>` graph name. Preserve the same person's memory and identity through an explicit migration to the new graph namespace.

| Concept | Current | Intended |
|---|---|---|
| Packaged conversation Lens | `operator` | `personal-chat` |
| Packaged private Destination | `operator` | `personal` |
| Resolved logical private graph | `operator/<identifier>` | `personal/<same identifier>` |
| Packaged Lens output | `operator` | `personal` |
| ERL Destination output | `operator` | `personal` |
| ERL extraction ontology | `Gralkor.Reflection.ERLOntology` | Unchanged |
| Generalisations Destination | `global` | Unchanged |
| Identity input | `operator_id`, supplied from the agent or direct caller | Same field and same value |

Keep real consumer-defined Lenses, including Lenses targeting `personal`. A Destination remains a graph placement, with no ingestion process or ontology of its own. The packaged `personal-chat` Lens initially uses the existing Store ingestion process and `Gralkor.DefaultOntology`; this rename does not authorize a new summarizer, classifier, inference pass, or conversation-only input restriction.

Ordinary direct capture must remain possible without any selected Lens. Remove the old automatically supplied `operator` Lens and its special resolution fallback. New direct writes must not claim either `operator` or `personal-chat` Lens authorship.

The naming decisions are operator instructions. The typed request and exclusive dispatch recommendations below have been finalized in the revised trees under the operator's explicit authorization to complete this work without routine confirmation.

## 2. Capture contract and routing recommendation

Use one public runtime-targeted capture boundary with a typed request rather than continuing ambiguous positional overloads in which the second argument sometimes means a raw graph ID and sometimes an operator ID. Direct requests must identify a registered Destination explicitly, separately from operator identity. Lens requests must explicitly identify their selected processing Lenses. Settle the exact request type and arities from the Functional consumer test; the configuration keys below are proposed, not shipped APIs.

Recommended dispatch preserves the current exclusive direct-or-Lens behaviour:

1. With no selected Lens, capture writes once through the direct conversation writer to `capture_destination`.
2. With a primary Lens selected, capture runs that Lens and each distinct additional Lens. It does not also perform an implicit direct write.
3. Every Lens keeps its declared Destination, ontology, and ingestion process. `capture_destination` governs direct capture only and cannot override a Lens's Destination.
4. Deduplicate repeated Lens names, not different processing Lenses sharing a Destination. A process may legitimately produce zero, one, or many writes.
5. Retain per-turn Lens selection, request correlation across completion/failure, and existing additional-Lens fan-out. Selecting a Lens must not change search selectors.
6. Support direct-to-Lens and Lens-to-direct selections within one session by retaining each turn's selected route and batching direct and Lens turns independently. No turn enters an unselected route, and no batch combines incompatible processing or ontologies. This is a proposed correction to the current buffer's mode-mismatch rejection; express it explicitly in the revised contract.

This refines an earlier assistant suggestion of always storing directly plus optional additive Lens processing. That additive suggestion was not an approved operator contract. Automatically combining direct storage with the packaged Store-based `personal-chat` Lens would create two copies of an ordinary conversation. The recommended exclusive dispatch avoids introducing that behaviour. Make this refinement visible in the proposed tree diff.

Proposed Phil chat configuration, retaining its existing selected-Lens mode:

```elixir
%{
  agent_name: @agent_name,
  capture_destination: "personal",
  ingestion_lens: "personal-chat"
}
```

The explicit direct alternative is:

```elixir
%{agent_name: @agent_name, capture_destination: "personal"}
```

The package must verify both. The packaged Lens's presence must not force its selection when the consumer chooses direct capture.

Validate identity, Destination, and selected Lens inputs before buffering. Keep agent/session/user-name requirements and canonical message handling. The plugin must not ask callers to construct `personal/<identifier>`, and the public interface must not accept an arbitrary private graph string in place of operator identity. Retire old public name inputs with useful migration errors rather than silently reinterpreting a Destination name as a Lens.

Review old capture adapter arities and implement an explicit compatibility/deprecation policy. Any retained compatibility adapter must route into the corrected behaviour and cannot restore the old Lens fallback or fictitious provenance. Update both Native and InMemory adapters and consumers that inspect recorded captures.

## 3. Production boundaries and source findings

Paths and line anchors below were inspected during evaluation; search by symbol if lines move.

| Boundary | Current evidence | Required work |
|---|---|---|
| `lib/jido_gralkor/runtime.ex:198` | Injects Destinations and an `operator` Lens; reservations at `:318` | Install `personal`, `global`, and `personal-chat`; update reservations, validation, and atomic snapshots |
| `lib/gralkor/destination.ex:12` | Only `operator` receives per-identity resolution | Resolve `personal` privately; ensure legacy `operator` cannot fall through as a shared graph |
| `lib/gralkor/destination/registry.ex:6` | Compatibility registry packages `operator`/`global` and reserves `operator/` | Align runtime and application registries; reserve new private namespace and retire old one |
| `lib/gralkor/client.ex:148,484,661` | Lens-only runtime capture wrapper, special `lens!("operator")` fallback, `operator_graph_id/1` helper | Correct capture interface, packaged Lens lookup, private graph helpers, search/name validation |
| `lib/jido_gralkor/plugin.ex:109,219` | Mount assumes operator Lens exists; dispatch chooses direct or selected Lens | Explicit direct Destination config, new packaged Lens selection, retained request context |
| `lib/gralkor/client/native.ex:43,144` | Direct capture accepts raw group; direct MemoryAdd stamps `lens: "operator"` | Correct routing and direct provenance; keep default extraction behaviour |
| `lib/gralkor/capture_buffer.ex:194,241,594` | Separate direct/Lens entries reject mixing; Lenses resolved before asynchronous work | Coherent capture entry/routing contract, ordered batches, safe configuration snapshots |
| `lib/gralkor/application.ex:73,116` | Direct flush hardcodes operator Lens; separate Lens flush callback builds `%Ingest{}` | Direct conversation writes without a Lens; real Lens processing only when selected |
| `lib/gralkor/destination/storage/graphiti.ex:100` and `lib/gralkor/graphiti_pool.ex:364` | Public episode search admits only recognized Lens/Reflection provenance | Admit real direct writes without inventing a writer, while retaining historical decoding |
| `lib/gralkor/destination/storage/in_memory.ex:47` | Ordinary episode filtering assumes a `.lens` field | Support direct episodes as well as Lens and Reflection records |
| `lib/gralkor/search.ex:27` | Episode result type describes only Lens or Reflection records | Add truthful direct episode shape and document selector behaviour |
| `lib/jido_gralkor/memory_search_presentation.ex:83` | Sources without a named Lens/Reflection become `Source: unknown` | Present known direct conversation origin truthfully within existing response budgets |
| `lib/jido_gralkor/actions/` | MemoryAdd and maintenance actions resolve the operator graph | Update private Destination resolution and direct MemoryAdd provenance |
| `lib/gralkor/reflection/packaged.ex:59` | ERL already declares a Destination output directly | Change its Destination name to personal while preserving identity, ontology, and delivery semantics |

Use `rg` across source, tests, trees, configuration, and docs. Classify every `operator` occurrence by meaning; do not perform a repository-wide string replacement. Identity fields, historical provenance, existing account IDs, and migration fixtures deliberately retain the old word.

### Provenance and historical search

Deleting the hardcoded Lens option alone breaks episode retrieval: Destination search currently asks Graphiti for trusted writer provenance, which recognizes only a Lens suffix or Reflection prefix.

- New direct capture retains speaker-attributed transcript content, `source_kind: :conversation`, and the captured-turn source description, with no `lens` or `reflection` claim.
- Add storage-owned direct-write provenance so writer-like user descriptions cannot fabricate Lens or Reflection authorship. This applies to direct MemoryAdd too; its declared source kind and source description remain meaningful.
- Real `personal-chat` processing records `personal-chat`; consumer Lenses record their own names.
- Historical ` [lens: operator]` episodes and fact sources remain readable without registering an active `operator` Lens. Preserve their recorded provenance rather than relabelling them all as `personal-chat`: historical records include direct writes that never passed through a Lens.
- Historical access must work through `destinations: ["personal"]` with no Lens filter, and through selector-free search. A new `personal-chat` Lens filter must not silently assert that all old operator-labelled writes came through that process.
- Preserve access through existing recall paths for older unmarked records; test the supported historical forms explicitly. Do not invent authorship to make an old record fit a new type.
- Preserve Reflection completion-marker requirements and protection against source text such as `reflection:generalisations` or `manual [lens: observations]`.
- Preserve structured search data separately from model-facing text, source episode identifiers on facts, result ordering/limits, and formatter byte/character budgets.

### Buffer, flush, and retry semantics

Keep ordered turns and independent selected-Lens batches. The representation must handle direct and selected-Lens requests without accidentally coalescing incompatible routes or executing both for one ordinary capture. Preserve runtime owner, operator, agent, and user binding; reject conflicting session identities. Resolve/snapshot needed definitions before asynchronous flush work so runtime replacement or termination cannot reroute already scheduled work.

Existing behaviour to cover explicitly:

- Async flush schedules work and consumes the entry; awaited success/error consumes it, while an await timeout preserves it.
- A failed Lens route does not prevent attempting remaining selected routes; each route owns its retries and the overall call reports failure.
- Default retry delays are 1/2/4 seconds for retryable internal failures; contract/upstream-LLM errors are dropped without that retry loop. Preserve classification and exhaustion behaviour.
- Empty rendered transcripts submit no write or Lens ingestion.
- Rotation and shutdown use their existing completion semantics; preserve active and buffered work handling.
- Capture is not idempotent today. Stable Lens ingestion IDs are not forwarded as Graphiti episode UUIDs. Direct writes also lack deterministic UUIDs. Retrying after a write or an await timeout can duplicate an episode or a previously successful route. Do not claim exactly-once delivery or silently introduce it as part of the rename.
- `flush_all/0` success alone does not establish that every session persisted successfully. Migration cutover must inspect failures and outstanding work, not merely its return value.

## 4. Stored graph migration

The new graph prefix requires a real data migration. `Client.sanitize_group_id/1` encodes the complete logical graph name as `g_` plus lowercase hexadecimal bytes. Graphiti uses that encoded value for both the FalkorDB database and stored/query `group_id` values. Renaming only the database leaves reads and deterministic write claims inconsistent.

For each exact identity, inventory:

```text
operator/<identifier> -> personal/<same identifier>
g_<hex of old logical ID> -> g_<hex of new logical ID>
```

Preserve the identifier byte-for-byte, including `owner`, `dashboard:<UUID>`, punctuation, and case. Do not infer a new account ID from a display name. Do not change the existing injective encoding or revive the unrelated former lossy underscore normalization.

Migration requirements:

1. Produce a dry-run manifest with exact old/new logical and physical names, source/target existence, schema and property inventories, UUID sets/counts, and configuration references.
2. Reject namespace conflicts before mutation. Existing consumer Destinations named `personal` or under `personal/`, existing graphs at target names, and existing consumer Lenses named `personal-chat` are currently possible. Never merge a shared application graph into private memory or silently replace a consumer process with the packaged Lens.
3. Keep `operator/` retired/reserved after cutover. A stale Destination struct named `operator` must fail or undergo explicit historical routing translation before generic Destination resolution; it must never become the shared graph `operator`.
4. Inspect the deployed FalkorDB/Graphiti versions and prove a supported migration mechanism on a disposable restored copy. No rename, export, restore, or transactional capability was validated during this evaluation; do not assume one.
5. Coordinate a quiescent cutover across every writer: capture buffers, asynchronous memory additions, Reflection workers, queued deliveries, schedulers, and other consuming runtimes. Drain and inspect work before taking a consistent backup. Stop old workers from recreating the old namespace after cutover.
6. Migrate physical graph identity and every stored group identity together. Inventory episodes, entities, relationships, communities, and claim records rather than assuming only episode nodes carry the field.
7. Preserve episode/entity/edge UUIDs, relationship endpoints, fact-to-episode references, immutable artefact content, embeddings, timestamps, indexes/constraints, `_gralkor_lens` ownership, and source provenance. Do not re-ingest or re-extract to accomplish the rename.
8. Preserve Reflection extraction-completion state and claim generation/fencing semantics. `_GralkorEpisodeClaim` equality includes group identity; migrate it consistently with the episode. Never mark incomplete history complete to make it searchable, or copy an actively renewed lease without quiescing its owner.
9. Make the migration restartable and fail on conflicting targets. Verify data and public reads before switching consumers; restart/invalidate graph-instance caches as part of activation.
10. Prove rollback of matching graph, configuration, and application state. Retain a restorable source/backup until validation completes; do not delete the only source copy during cutover.

Artefact identity is derived from operator ID, invocation ID, and Reflection name, not Destination name (`lib/gralkor/artefact.ex:13`). Preserve those inputs. Replaying a completed Reflection after migration must find the same immutable artefact; an incomplete one must remain resumable without a newly invented identity.

Older graphs under the former lossy physical encoding require a separate mapping from known identities. This rename must not guess that mapping from underscores.

Implement and test migration tooling against isolated fixtures/restored copies. Execution against live stores, deployment, and release publication require their own concrete scope; this handover is not authorization to mutate them.

## 5. Exact Phil consumer migration

All paths in this section are relative to `/Users/eli/code/fasset/fasset-intelligence-lab/phil`.

### Mounts, identity, and private recall

- `lib/phil/chat_agent.ex:111`: replace `ingestion_lens: "operator"` with `ingestion_lens: "personal-chat"` and add the proposed explicit `capture_destination: "personal"`. Use the exclusive dispatch recommendation above so this does not store two transcripts. Tests must also exercise the configuration with no ingestion Lens.
- `lib/phil/runtime_configuration/agent.ex:8`: supply explicit `capture_destination: "personal"` at the background runtime mount consistently with the proposed plugin configuration. This does not cause that non-chat agent to emit captures.
- `lib/phil/runtime_configuration/plugin.ex:17` already forwards mount configuration and injects runtime definitions. Keep that existing wiring rather than introducing another configuration layer.
- Preserve `Phil.Chat.agent_id/1`, persisted `User.operator_id`, legacy `owner`, and other `dashboard:<account UUID>` values. `priv/repo/migrations/20260910100000_admin_membership.exs` deliberately preserves these identities.
- Keep Slack's `capture_conversation: false` (`lib/phil/slack_chat.ex:384`) and the suppression in `lib/phil/chat/memory_plugin.ex:21`.
- `lib/phil/actions/memory_search.ex:24` forwards search params/context and has no hardcoded operator Lens filter. Update explicit private Destination selectors where found; do not introduce a default Lens filter that would hide history or Reflection outputs.

### Catalogue, validation, and persisted configuration

- `lib/phil/runtime_configuration.ex:132`: replace the packaged `operator` entry in `lens_names/1` with `personal-chat`, followed by genuine configured Lenses. There is still one packaged Lens; do not remove the count increment as the earlier removal-only evaluation suggested.
- `lib/phil/web/runtime_configuration_live.ex:524-544`: update the packaged Lens card, selectors, DOM identifiers, summary, and Destination card to show `personal-chat -> personal`. Update Reflection Destination choices around `:422` to `personal`; retain `global`.
- Trigger checkboxes and validation already use `lens_names/1`. New selections must validate against `personal-chat` and configured consumer Lenses, and reject the retired operator Lens name.
- Migrate existing active configuration before updated startup preflight. `load_or_seed!/0` retains the stored row; editing seed data alone is insufficient. Preflight runs before normal jido_gralkor startup.
- Rename typed consumer Lens `destination` references and Reflection Destination outputs from `operator` to `personal`. Preserve unrelated JSON, ontology choices, prompts, schedules, ingestion checkpoints, and definitions.
- The current seed's `organisational-content -> global` route is unchanged. Do not reset saved runtime configuration or inject a duplicate consumer definition for the packaged Lens.

For explicit persisted trigger arrays:

| Before | After |
|---|---|
| `ingestion_lenses: ["operator"]` | `ingestion_lenses: ["personal-chat"]` |
| `ingestion_lenses: ["operator", "organisational-content"]` | `ingestion_lenses: ["personal-chat", "organisational-content"]` |
| An explicit empty array | Unchanged |
| Legacy `ingestion: true` / `false` | Unchanged |
| Missing Reflection trigger entry | Remains missing |

Preserve ordering and other selections. This supersedes the earlier removal-only recommendation to delete `operator` from arrays. A missing entry and an explicit empty entry have different defaults; never exchange them. Legacy/default expansion should now include packaged `personal-chat` as the renamed choice.

Dashboard capture currently does not admit Phil's ingestion-triggered Reflections. Admission occurs in `lib/phil/ingestion.ex:248-290` after background source ingestion returns Lens representations. Preserve that separation for both direct and personal-chat capture; this task does not introduce a new dashboard-capture trigger event. Keep once-per-event admission when several matching Lenses complete together.

### Durable Reflection state and historical routing

Updating active definitions is insufficient. Phil restores historical Destination names directly from stored snapshots:

- `lib/phil/reflections/definition.ex:111,295`: supports old single-Destination and current output-list snapshot formats, and constructs a raw `%Gralkor.Destination{name: name}`.
- `lib/phil/reflections/execution.ex:74`: persists `result_checkpoint.resolved_definition`.
- `lib/phil/reflections/output_delivery.ex:62`: resumes delivery using resolved snapshots.
- `lib/phil/artefacts/artefact.ex:42`: retains immutable `resolved_definition` and `definition_hash`.
- `lib/phil/artefacts/ingester.ex:91`: restores the stored definition and projects an artefact into Graphiti independently of Reflection output delivery.
- `lib/phil/reflections/store.ex:27` and `lib/phil/artefacts/actions/store_completed.ex:53`: reconstruct the snapshot/hash at commit and enforce immutable retry matching.

Implement explicit historical routing translation in the storage routing representation used by output delivery and artefact projection. Preserve the original snapshot and hash through canonical commit and immutable retry matching. Apply routing translation to both historical snapshot shapes and resumed checkpoints. Simply replacing the Destination during `Definition.from_snapshot/1` would cause commit to regenerate different archival provenance and reject an existing artefact; do not use that shortcut. Do not make current public APIs silently accept arbitrary retired configuration or mutate immutable archival JSON with a blanket replacement.

Prove pending jobs, checkpointed executions, queued deliveries, and pending/failed artefact projections still target the same person's migrated personal graph and recover the original artefact. Include replay against an already stored private artefact, preserving its original definition/hash. Preserve invocation IDs, artefact IDs, source descriptions, Reflection names, and schedule ownership. Historical `operator` must never resolve through the generic shared-name clause after the rename.

ERL changes its configured Destination name to `personal`, while generalisations remains `global`. Their production, identity, ontology, retrieval, delivery retries, and terminal callback behaviour remain unchanged.

### Dependency and fixtures

Phil currently pins Git tag `jido-gralkor-v10.0.0` in `mix.exs:100` and `mix.lock`. During implementation, verify the correction through an isolated local dependency checkout/override. Update the durable pin only to a real published/available revision; do not invent a future tag or silently publish the package to unblock integration.

Update chat-agent/runtime configuration tests, UI catalogue counts/cards/choices, trigger fixtures, and positional `InMemory.captures()` assertions. Private-memory fixtures in `test/web_chat_test.exs:1260` currently create `%Ingest{lens: "operator"}`; new fixtures must use direct capture or actual `personal-chat` ingestion. Historical fixtures must seed real historical record shapes rather than invoke the removed Lens.

Tests previously using `operator` as an unmatched Lens fixture must use a real available Lens that the event does not produce. Preserve two-user and legacy-owner recall tests, disabled Slack capture, no capture-trigger admission, genuine consumer Lens-to-personal processing, and ERL routing.

## 6. Contracts, tests, and documentation

Begin with the relevant Functional trees under the project's change workflow; inspect the current test strategy and focused commands before proposing leaves. Show the complete cumulative proposed tree diff according to the applicable workflow. Add inner trees only when a failing consumer test reveals a need. The original handover was not a test-tree approval; the subsequent end-to-end instruction authorizes in-scope reconciliation, and cumulative substantive tree diffs are shown during implementation.

Affected existing contracts include:

- Functional: `runtime-configuration`, `lens-registration`, `destination-registration`, `destination-graphs`, `destination-search`, `operator-lens-compatibility`, `lens-aware-agent-memory`, `native-memory-round-trip`, `ingested-information-provenance`, `retry-ownership`, `reflection-system`, and `reflection-completion`.
- Integration: `graphiti-episode-provenance`, plus lifecycle/context-rotation seams affected by flushing.
- Unit: `jido-gralkor-runtime`, `plugin`, `gralkor-client-native`, `gralkor-client-in-memory`, `capture-buffer`, `gralkor-application`, `memory-add-action`, Destination storage, and `memory-search-presentation`.
- Journey: `memory-adventure`, with direct capture, genuine personal-chat processing, personal isolation, and ERL delivery.
- Phil: chat-agent, runtime-configuration, runtime-configuration-management, configuration navigation, content ingestion, web chat/private recall, durable Reflection delivery, and migration behaviour.

Rename/rewrite `operator-lens-compatibility` around the intended personal-memory behaviour instead of retaining the old concept as a positive requirement. Keep historical names only where they establish migration/compatibility conditions. Add migration Functional coverage through a real, observable migration seam.

Material existing coverage gaps:

- `test/functional/operator_lens_compatibility_functional_test.exs:119-149` uses canned InMemory capture, memory-add, and recall responses. It does not establish actual storage, ontology use, or recall of the written memory. Its same-graph Lens case also uses the packaged operator Lens again.
- `test/functional/native_memory_round_trip_functional_test.exs:84-113` has a useful real Native/Buffer/Application/GraphitiPool path with deterministic external substitutes, but returns the same fake Graphiti instance for different graph names and seeds recall facts independently of captured writes. Give it separate per-graph state and connect writes to subsequent reads before claiming isolation or round-trip proof.
- `test/functional/ingested_information_provenance_functional_test.exs:692-788` already records actual Graphiti-boundary write arguments and supplies historical episode/fact results. Extend this deterministic seam for direct provenance, real personal-chat provenance, and historical operator markers.

Acceptance matrix:

| Outcome | Required evidence |
|---|---|
| Packaged names | personal-chat and personal present; retired names give migration errors; global and packaged Reflections remain |
| Direct capture | No selected Lens; completed and failed turns flush into personal and can be read back |
| Selected Lens | personal-chat processes a conversation once; no extra direct copy; consumer processes keep their own Destinations |
| Route transitions | Direct, Lens, and then direct turns in one session retain independent ordered batches, with no duplicated turn or mixed route/schema |
| Identity/isolation | Same exact identity across migration; two people cannot retrieve one another's personal memory; punctuation-sensitive IDs remain distinct |
| Historical recall | Old provenance, source IDs, fact relationships, and supported unmarked history remain accessible without an operator Lens registry entry |
| Provenance | New direct writes have no fictitious Lens; real Lens writes identify their process; user descriptions cannot forge writer identity |
| Search | Destination-only/default recall includes new and historical personal memory; Lens filters retain truthful writer semantics and limits |
| Flush/retry | Async/awaited flush, empty transcripts, timeouts, route failures, retries, rotation, runtime snapshots, and shutdown preserve the contract |
| Graph migration | Dry run, conflict refusal, preserved data/UUIDs/schema/completion state, restart after interruption, successful cutover, and rollback on isolated copies |
| Reflection replay | Original completed artefact remains equal; incomplete output resumes; conflicting content still fails; old snapshots cannot target a shared operator graph |
| Phil migration | Stored active config, trigger defaults, both snapshot formats, jobs/checkpoints, independent artefact projections, preserved archival hashes, UI, chat capture, legacy owner recall, and disabled Slack capture |
| Reflection routing | ERL remains personal to its invocation identity with ERLOntology; generalisations remains global; capture adds no Reflection trigger |

Update `MENTAL_MODEL.md`, `CLAUDE.md`, `README.md`, `DESTINATIONS.md`, `CHANGELOG.md`, public moduledocs, and Phil's corresponding docs. Keep canonical docs describing implemented behaviour until implementation changes it. The mental model's World-to-Code Mapping, Ubiquitous Language, Invariants, and Decision Rationale contain the relevant existing lines; tighten those rather than adding a parallel vocabulary. Document API/configuration migration separately from graph migration and historical provenance.

Current test commands are in `TEST_STRATEGY.md`, `mix.exs`, and coding-agent hooks. Use focused Functional runs during RED/GREEN, the full Functional gate when implementation is ready, and the production-like Journey for this substantive API/persistence change. Respect project lifecycle ownership of Unit/Integration and Node checks rather than duplicating hook runs. Phil uses `mix test.unit` and `mix test.fun`; inspect its current strategy and local instructions before running providers or browser gates.

Use isolated build, database, graph, and listener resources. Do not run competing embedded Graphiti test VMs; current startup orphan cleanup can interfere across VMs. Browser-visible Phil changes require view, fix, and view again. Report live/billable Journey authorization or infrastructure gates explicitly; an unrun gate is not a passing gate. Do not perform mutation testing unless explicitly requested.

### Automatic test feedback observed while documenting

The stop hook supplied `.fasset-harness/state/optimistic-feedback/diagnostics/feedback.XKHXEh` after the handover was written. These are observed hook results against the existing implementation, not verification of the proposed rename or an isolated reproduction of their causes:

- Impacted tests, seed `5683`: `636/637 passed, 536 excluded`, one failure. The same-identifier concurrent-write test at `test/gralkor/graphiti_pool_test.exs:377` expected the stale write to return a Python error, but received `:ok`; the failing assertion is at `:649`.
- Stop Unit/Integration tests, seed `640079`: `814/816 passed, 536 excluded`, two failures. The same Graphiti test failed again. `test/gralkor/client/native_test.exs:791` also expected recall to succeed with a configured 75 ms deadline, but received `{:error, :recall_deadline_expired}`; its failing assertion is at `:803`.

At the handover checkpoint, no cause had been established and verification was unperformed. The subsequent isolated diagnostics resolved both fixture failures as recorded in section 9; claim fencing and actual recall deadline expiry remain covered.

## 7. Work organization and completion

Suggested independent ownership after the outer contract is established:

1. Runtime/registry/Destination names and resolution, packaged definitions, public capture contract.
2. Capture adapters, buffer/flushing, storage provenance, search decoding/presentation.
3. Graph migration tooling and verification on isolated stored-data copies.
4. Phil configuration, UI, typed persisted migrations, historical Reflection routing, and consumer verification.

Agree shared-file ownership and API contracts before concurrent edits; adapt to others' changes instead of reverting them. The primary agent reconciles the integrated result, runs the required completion gates, and obtains the applicable final independent review. Package publishing and live deployment are distinct from implementing and proving the change.

The original handover left implementation and verification outstanding; the current status and evidence are recorded above and in section 9. Completion requires implemented behaviour, tested migration tooling, migrated consumer code, accurate trees/docs, and a precise record of passed and unperformed gates. Do not mark the work complete after a name replacement or compile-only check. If an unavailable release pin, a live migration, or an unauthorized Journey remains, name that exact remaining outcome and its reason.

## 8. Suggested goal for the next session

Implement and verify the work in `/Users/eli/code/os/jido_gralkor/WIP_RENAME.md` end to end across jido_gralkor and Phil. Replace the packaged operator Lens with personal-chat and the operator Destination with personal, resolving to personal/<the same identifier>. Establish explicit direct capture and optional genuine Lens processing without duplicate automatic writes; preserve truthful provenance, historical memory, operator isolation, flush/retry semantics, and private ERL delivery. Implement restartable graph and Phil configuration/job compatibility migrations and prove them on isolated data. Update trees, tests, documentation, and consumer integration; follow the project workflows, reconcile parallel work, and report material verification plus every remaining gate. Do not publish, deploy, or mutate live stores without separately scoped authorization.


## 9. Current isolated verification evidence

These results belong to the implementation session. Pending full gates are not implied by focused passes.

| Check | Observed result | Evidence |
|---|---|---|
| Typed capture and compatibility-mode integrity | 18 Functional tests passed | `/tmp/gralkor-capture-mode-green.log` |
| Direct/historical provenance and canonical stored artefacts | 29 Functional tests passed | `/tmp/gralkor-artefact-shape-green.log` |
| Package configuration, packaged Reflection, and Destination registration | 149 focused Functional tests passed | `/private/tmp/jgr-rename-runtime-green2.log` |
| Public memory capabilities and Lens replacement | 76 focused Functional tests passed | `/private/tmp/jgr-rename-public-green2.log` |
| Capture retry ownership | 17 Functional tests passed | `/tmp/gralkor-retry-green.log` |
| Complete migration Functional tree | 44 passed; 100.1 seconds; exit 0; real copies, bounded timeout, late-copy adoption, controlled recovery, client interruption, restored backup, public reads/replay, and guarded rollback | `/private/tmp/gralkor-migration-copy-recovery-green.log` |
| Migration with macOS fixture logging correction | 44 passed; 57.1 seconds; exit 0; backup startup evidence and all data/schema/public-read assertions retained | `/private/tmp/jgr-warning-focused-functional.log` |
| Synthetic backup restored into a separate server | Synchronous RDB SAVE, source shutdown, identical snapshot bytes, distinct server process/run identity, exact restored inventories and operational schema, migration, and three-identity public recall passed | `/private/tmp/gralkor-migration-copy-recovery-restored-evidence.json` |
| Graphiti stale-writer diagnostic | Delayed theft reproduced the fixture race; explicit extraction barrier passed the original-seed diagnostic | `/private/tmp/jgr-rename-stale-delayed-red.log`, `/private/tmp/jgr-rename-stale-green2.log` |
| Native recall deadline diagnostic | Original-seed focused test passed after separating forwarding from fixture timing; production deadline unchanged | `/tmp/gralkor-native-deadline-verified.log` |
| Package Functional suite before shutdown fix | 593 passed, 887 excluded; 172.7 seconds; exit 0, including approved real OpenAI ontology extraction and all migration tests | `/private/tmp/jgr-rename-full-functional.log` |
| Final complete package Functional suite | 597 passed, 887 excluded; 171.5 seconds; exit 0; includes the four added deadline/recovery leaves and macOS fixture logging correction | `/private/tmp/jgr-rename-final-597-functional.log` |
| Package memory Journey before shutdown fix | 44 passed; 266.1 seconds; real approved OpenAI capture, Reflection, recall, isolation, provenance, and replacement lifecycle | `/tmp/gralkor-journey-rename.log` |
| Final package memory Journey | 44 passed; 209.0 seconds; exit 0; owned BEAM and Redis exited and disposable data directory was removed | `/tmp/gralkor-journey-rename-shutdown.log`, `/tmp/gralkor-journey-rename-shutdown.exit` |
| Phil full Functional | 608 passed, 798 excluded; 670.2 seconds | `/private/tmp/phil-rename-full-functional.log` |
| Phil final installed Stop gate | 796 Unit/Integration passed, 620 excluded; 167.6 seconds; hook exit 0; actual dependency `59c3b9da439a545a645ce808bbe7fe861ebb431f` | `/private/tmp/phil-rename-59c3-unit-integration.log`, `/private/tmp/phil-rename-59c3-stop.log` |
| Phil shutdown-corrected package consumer check | 85 affected Functional tests passed; 117.7 seconds; exit 0; fetched dependency revision `48b1de518feab8f5a52438db43434539cd17a08b` | `/private/tmp/phil-rename-final-shutdown-pin-functional-green.log` |
| Package installed Stop gate | Hook exit 0; complete hook-owned Unit/Integration and Node checks passed; successful hook suppresses individual output/counts | `/private/tmp/jgr-rename-stop-feedback.log` |
| Final package installed Stop gate | Hook exit 0 after the final complete Functional pass; complete Unit/Integration and Node checks passed | `/private/tmp/jgr-rename-complete-stop.log` |
| Package final formatting and documentation checks | Package-wide `mix format --check-formatted`, README sync, and `git diff --check` passed | Installed formatter and repository checks |
| Application supervisor shutdown | Existing Functional contract reproduced a surviving server; trap-exit correction passed all 8 lifecycle tests | `/private/tmp/jgr-supervisor-shutdown-red.log`, `/private/tmp/jgr-supervisor-shutdown-green.log` |
| Phil isolated synthetic artefact Journey before final pin | 1 passed; 153.4 seconds; controlled Atlas input and approved OpenAI calls; test handle subsequently absent and no test VM remained | `/private/tmp/phil-rename-synthetic-journey.log` |
| Coordinated rollback | Graph apply, exact Phil target apply, graph rollback, exact original configuration restore, and actual prior application boot/read completed | `/private/tmp/phil-rollback-old-application-evidence.json` |

The latest restored-backup fixture used three synthetic historical graphs. The source and restored RDB files were both 10,056 bytes with SHA-256 `18224e5a57bd1cb8d54751424a2b81cc7b314bfff98540317378979b9b662464`. The source server stopped before an independent server loaded the backup; startup logs confirmed three restored keys. The test compared complete pre-backup and restored graph inventories, then translated target inventories and public reads. Both owned servers and temporary snapshots were removed afterward. Separate tests prove migration-client interruption and controlled server recovery after an uncertain copy. These are synthetic restoration and transport-fault exercises; they do not reproduce the exact native fork hang or validate a deployed backup.

The rollback boot used Phil revision `3f3ecf2db7d6c80ea76ce6297679dedb6219e9e4` and its original package revision `56f97bd496dea3ab43c8888aa69f95c1a743fb32`. Its public search returned the original `complete` artefact with payload `{"summary":"immutable amber"}` from `operator/owner`. Source polling and Slack were disabled. A synthetic placeholder credential caused a nonfatal warmup 401; the historical artefact read and evidence export completed with exit 0. This establishes matching graph/configuration/application rollback, not provider readiness of the old revision.

Phil's post-change Destination, Lens, and trigger screenshots were inspected at `/private/tmp/phil-personal-rename/screenshots/personal-rename-{destinations,lenses,triggers}-after.png`, following the earlier before view.

Trees, executable coverage labels, and the corresponding implementation/docs have been reconciled across both repositories. Phil accounts for 1,416 executable leaves; the capture/storage lane accounts for 750 leaves in 32 trees, and the migration tree has 44 matching executable tests. These coverage audits are distinct from test execution.

Still pending:

1. Finish Phil's isolated synthetic artefact Journey against its verified final dependency; the pin, affected Functional evidence, and final Stop are complete.
2. Final completion reconciliation with that terminal result and the single independent review of the verified change.

The operator explicitly approved all three test gates after automatic approval review requested payload/destination-specific authorization. The approved destination is `api.openai.com`; payloads are response/editor preferences, synthetic codenames/cities/support channels/scheduling conversations/deployment reviews/dependency graphs, controlled Atlas evidence, and generated Reflection/recall content. Normal inference charges and disposable local data are within this approval. Run the complete package Functional suite, package Journey, and Phil's isolated artefact Journey sequentially so their embedded runtimes cannot interfere.

Live-data migration, publication, deployment, and Phil's eleven live-company-service Journey leaves are outside the isolated execution scope.

The first approved package Journey passed all assertions but left its owned embedded server alive after supervisor shutdown. Cleanup identified and stopped only that fixture server. The existing application-shutdown test was strengthened to stop a real supervisor and reproduced the leak. `GraphitiPool` now traps supervisor exit signals so its existing termination cleanup executes. The focused lifecycle suite and final complete Functional, Stop, and Journey gates passed. The final Journey's BEAM PID 65753 and Redis PID 67270 exited, and `/private/var/folders/p_/xnt0_ct14d9g8ccc86wd_dcc0000gn/T/gralkor_memory_adventure_dR414akiZBjNQo5Il5WVFw` was removed. Unrelated pre-existing Redis processes remained intact.

The post-shutdown full Functional rerun exposed an independent FalkorDB `GRAPH.COPY` stall (seed 869025): the server answered PING but held client 615 blocked in COPY for several minutes, and the BEAM stack waited in Python socket receive. The journal remained `copying`, with only the source graph listed. Diagnostic state, journals, and Redis logs are preserved in `/private/tmp/jgr-copy-stall-evidence`; stack samples are `/private/tmp/jgr-functional-stall-sample.txt` and `/private/tmp/jgr-redis-stall-sample.txt`. After preserving evidence, only the task-owned server was stopped to release the call. The suite ended with 589/593 passing: one COPY failure and three downstream failures from the stopped fixture. This historical gate failed. Two hundred subsequent real copy/delete diagnostic cycles passed; the exact native fork-child cause remains unproved because the child stack was not captured.

Migration connections now have validated finite positive read/connect deadlines (30s/5s defaults) and zero automatic retries. Copy intent records the server run identity before dispatch. An uncertain copy retains its journal; a complete matching late target can be adopted, while an absent target on the original server blocks resume and rollback until controlled recovery. The 44-test migration gate verifies this bounded failure and recovery path with an explicit transport fault. It does not claim to fix or reproduce the native fork implementation.

The subsequent full gate (seed 739861) reproduced the native stall and completed with 574/597 passing, 23 migration failures, and exit 2 (`/private/tmp/jgr-rename-complete-functional.log`, 383.1 seconds). The first copy returned the new bounded uncertainty error; the occupied fork slot caused later copies on the same fixture to fail. This time the live child stack was captured in `/private/tmp/jgr-copy-fork-child-reproduced-sample.txt`: `Cron_Run -> _Graph_Copy -> RM_Log -> serverLogRaw -> strftime_l -> tzsetwall_basic -> pthread rwlock wait`. FalkorDB emits this notice before serializing the graph. The disposable fixture now establishes warning-level logging after startup to skip this observed macOS logging path, preserving RDB startup evidence and every migration assertion. Both the focused 44-test gate and the complete 597-test gate passed after this environment correction. The failed gate's VM, Redis server, and fork child all exited through owned teardown.

Phil's final durable dependency is the available upstream revision `59c3b9da439a545a645ce808bbe7fe861ebb431f`; its isolated checkout fetched and compiled that exact revision. Compared with the 85-test Functional checkpoint at `48b1de518feab8f5a52438db43434539cd17a08b`, the only production change is the standalone Python migration helper, which those consumer tests do not invoke. Every other `lib/` and `priv/` file is identical. The final Phil Stop gate reran against the actual final dependency. Its isolated real-provider Journey remains pending.

After correcting the shutdown-related fixture ownership and replacing fixed sleeps in the CaptureBuffer exhaustion-log fixture with terminal-result synchronization, the installed package Stop gate completed with exit 0 (`/private/tmp/jgr-rename-stop-final.log`). Successful hook output is intentionally suppressed. This verifies Unit/Integration and Node at that checkpoint; the migration deadline/recovery additions still require their final gates.
