# Personal memory migration

This unreleased API uses the `personal-chat` Lens and `personal` Destination. The latter resolves to `personal/<same operator_id>`. Direct capture selects a Destination explicitly and has no Lens authorship; selecting `personal-chat` runs Store ingestion once without an extra direct write. See [README.md](README.md#explicit-capture-and-migration) for the typed capture API.

Configuration changes do not move stored graphs. Use this tooling on disposable restored data first. Publication, deployment, and live-store execution require separately scoped authorization.

## Preserve identity and history

For each exact persisted identity, the migration maps:

```text
operator/<identifier> -> personal/<same identifier>
g_<UTF-8 hex of old logical name> -> g_<UTF-8 hex of new logical name>
```

Keep `owner`, `dashboard:<account UUID>`, punctuation, case, and every other identifier byte unchanged. Do not derive identities from display names or supply resolved graph names as identifiers. Former lossy underscore graph names need a separate explicit mapping; this tooling never guesses them.

The mechanism is FalkorDB `GRAPH.COPY`, followed by restartable group-identity updates on the copied graph. The source remains intact. There is no re-ingestion or extraction. The complete source and translated target inventories must match, including node and relationship identities, endpoints, episode references, immutable content, embeddings, timestamps, source provenance, `_gralkor_lens`, community data, claim generations, completion markers, indexes, and constraints. Records without a group identity remain unchanged; conflicting group identities are rejected.

The isolated verification environment reports Graphiti 0.29.3, Python FalkorDB client 1.7.1, falkordblite 0.10.0, Redis 8.6.2, and FalkorDB module 4.18.3. Verify the deployed versions and repeat the procedure on their restored copy before a live cutover. The manifest records the local client-library versions and connected server versions. Command references: [GRAPH.COPY](https://docs.falkordb.com/commands/graph.copy.html) and [GRAPH.CONSTRAINT](https://docs.falkordb.com/commands/graph.constraint.html).

## Inventory and prepare

Use `mix gralkor.migrate_personal <operation> <request.json>` or the exported `Gralkor.PersonalGraphMigration` functions. The Mix task loads configuration and initializes Python as needed; it does not start application consumers. Every request must supply a specific TCP endpoint or Unix socket. Connections never fall back to the application's configured store.

Create an explicit request for the disposable restored endpoint:

```json
{
  "connection": {"host": "127.0.0.1", "port": 16379},
  "operator_ids": ["owner", "dashboard:account-uuid"],
  "configuration_references": {
    "destinations": ["team-notes"],
    "lenses": ["organisational-content"],
    "phil_configuration_manifest": "/absolute/path/phil-personal-configuration.json",
    "previous_application_revision": "record-the-exact-existing-revision"
  },
  "journal_path": "/absolute/path/personal-graphs.json"
}
```

`destinations` and `lenses` in configuration references are the complete consumer-defined names across every affected runtime. Include the exact saved configuration and revision references needed for rollback. The example identities and endpoint are placeholders to replace from the inventory. Connection fields also support `username`, `password`, `ssl`, `unix_socket_path`, `db`, `socket_timeout`, and `socket_connect_timeout`.

```sh
mix gralkor.migrate_personal plan /absolute/path/request.json
mix gralkor.migrate_personal prepare /absolute/path/request.json
```

`plan/3` reads graph existence, full data/schema inventories, versions, and supplied configuration references without creating graphs or a journal. `prepare/4` refuses missing sources, existing targets, consumer `personal` or `personal/…` Destinations, and a consumer `personal-chat` Lens before exclusively creating its journal. Resolve conflicts explicitly; never merge a shared application graph into private memory or silently replace a consumer ingestion process.

Preparation can precede quiescence for inspection, but source changes invalidate that inventory. After writers are stopped and drained, take consistent backups and prepare a fresh journal from the final state if anything changed. Use a new journal path; an existing journal is never overwritten by preparation. Journals contain the complete private graph inventory and are created with owner-only file access.

## Quiescent cutover

Stop admission across every application and scheduler that can write these graphs. Drain capture buffers, asynchronous memory additions, Reflection production and delivery, and artefact projection workers. For capture, inspect both queued turns and active flush workers: `flush/1` consumes the buffered entry while its write may still be running. Report `capture_buffers: 0` only after both are drained. Inspect terminal failures and outstanding work; `CaptureBuffer.flush_all/0` returning `:ok` is insufficient evidence that every write succeeded. Stop all old consumers so they cannot recreate the retired namespace. Retain the original graphs, consistent backups, configuration manifest, application revision, and dependency revision.

The apply request supplies actual observed quiescence evidence:

```json
{
  "connection": {"host": "127.0.0.1", "port": 16379},
  "journal_path": "/absolute/path/personal-graphs.json",
  "quiescence": {
    "admission_stopped": true,
    "capture_buffers": 0,
    "asynchronous_additions": 0,
    "reflection_workers": 0,
    "queued_deliveries": 0,
    "schedulers": 0,
    "consuming_runtimes": 0,
    "failed_work": 0
  }
}
```

These counters are the operator's evidence from every consuming system; the migration cannot discover remote application workers. Any absent/nonzero counter, active server-time episode claim lease, source divergence, or conflicting target blocks mutation.

```sh
mix gralkor.migrate_personal apply /absolute/path/apply-request.json
```

`apply/3` completes the persisted phases. `advance/3` advances copy/rewrite work in bounded increments for interruption exercises. The journal records copy intent before issuing `GRAPH.COPY`, followed by copied graph, rewritten node groups, rewritten relationship groups, and verification states. The journal is locked, integrity-checked, atomically replaced, and fsynced between steps. Repeating apply after interruption resumes the recorded work; repeating verified apply confirms the same inventories. Do not edit a journal to bypass a conflict. The integrity checksum detects changes and corruption; it is not an authentication signature.

Only the journal that recorded copy intent may resume a matching target after an interruption. Independent migration processes must use the same journal and quiescence boundary. Never run competing migrations through different journals against the same identities.

## Verify and activate together

The journal's `verified` phase means graph data and schema match. It does not activate consumer configuration or prove application readiness. Before resuming writers:

1. Verify historical public reads through `destinations: ["personal"]` and selector-free search for each original identity, including two punctuation-sensitive identities. Historical `operator` Lens markers remain unchanged, and unmarked records retain their actual unknown authorship. A `personal-chat` filter includes only genuine writes from that Lens.
2. Verify completed artefact equality and replay using the original operator, invocation, Reflection, and artefact identifiers. Incomplete outputs must remain hidden until their original delivery resumes and records completion; never mark them complete merely to make them searchable. Verify fact-to-episode references and private ERL isolation.
3. Validate and apply the exact Phil configuration manifest while consumers remain stopped. Update typed Destination references to `personal` and explicit trigger selections to `personal-chat`; preserve missing entries, empty arrays, legacy booleans, other selections, and schedule ownership.
4. Activate the corrected application and a real available package revision together. Restart consuming runtimes and Graphiti pools to invalidate cached graph instances. Inspect readiness, historical recall, queued work, and failures before enabling admission.

Phil's implementation is documented in its `PERSONAL_MEMORY_MIGRATION.md`. Its `load_or_seed!/0` validates and migrates active persisted configuration before startup, so do not use it as a dry-run reader. Read the original row through the Repo, prepare `PersonalMemoryMigration.manifest/1`, validate its target with `RuntimeConfiguration.complete_preflight!/1`, and apply with `PersonalMemoryMigration.apply!/1`.

Archived Reflection snapshots and their hashes are immutable. Phil translates only the storage output used by delivery and artefact projection, including both historical snapshot shapes and resumed checkpoints. Canonical commit retains the original snapshot and hash. Migration does not change account, invocation, artefact, or schedule identity, introduce dashboard capture triggers, or enable Slack conversation capture.

## Rollback the graph, configuration, and application

Keep admission stopped. Use the same endpoint, journal, and truthful quiescence evidence:

```sh
mix gralkor.migrate_personal rollback /absolute/path/apply-request.json
```

`rollback/3` validates every source and target before deleting only matching migration-owned targets. It retains the unchanged sources and records its progress, so interruption or repeated rollback is safe. A changed target is preserved and reported as a conflict. Once new writers have modified the target, this pre-admission rollback no longer applies: stop and plan recovery from the retained data rather than discarding new writes.

Restore the exact original Phil configuration with `PersonalMemoryMigration.rollback!/1`, which locks the active row and refuses intervening changes. Restore the previous application **and dependency** revision before restarting; the corrected startup would otherwise migrate that original configuration again. Verify the original private graph through the previous application's public search and inspect durable jobs before enabling writers. Restoring graph names alone, configuration alone, or code alone is not a complete rollback.

## Verification scope

The package Functional migration tree covers real disposable FalkorDB copies, preservation, conflicts, interrupted progress, public historical recall, artefact delivery, and guarded rollback. Capture/provenance Functional tests cover exclusive routes, identity bindings, truthful history, flush/retry behavior, and malformed stored records. The single real-provider Journey adds direct capture, personal-chat capture, private ERL, shared memory, and replacement in one operator lifecycle. Phil owns persisted configuration, historical job/checkpoint/projection, UI, and actual previous-application rollback checks.

For each candidate revision, record the terminal results of the complete Functional suite, the single Journey, and the hook-owned Unit/Integration checks separately. The tree coverage described here does not certify that those gates have passed.

These are isolated verification procedures. They do not migrate any live store, publish a package, or deploy Phil.
