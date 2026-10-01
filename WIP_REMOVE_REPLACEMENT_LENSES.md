# CR: Remove replacement Lenses; bound FalkorDB waits

**Context.** We are giving up on reliable ingestion of large structured graphs into Graphiti. The experiments are recorded in `tmp/exp/REPORT.md`, which is local and gitignored. They found that LLM extraction tops out around 96% of entities and 69% of calls, even in small sequential batches. Making deterministic replacement graphs visible to Graphiti would need graphiti-native writes, which we will not build, so replacement Lenses have no path to being useful.

From issue #1, this CR closes items 3, 4 and 6 (`max_tokens`, chunking, extraction instructions) as won't-do, and adopts item 1 (an ingest deadline).

---

## 1. Deadlines on remote FalkorDB and on the Python bridge

**Problem**
- The remote client is built with no socket timeout (`graphiti_pool.ex:2208`).
- `asyncio._gralkor_run` blocks on `.result()` with no timeout (`python.ex:153`).
- So a FalkorDB write that never completes blocks its caller forever, with the BEAM and FalkorDB both idle. That is Phil's "never returns" symptom.
- This affects every write path, conversational capture included.
- It was reproduced on FalkorDB 4.20.2, where RediSearch's fork garbage collector deadlocks against graphiti's bulk write.

**Change**
- Add `:remote_falkordb_socket_timeout_ms` (positive integer, default `60_000`). Validate it at startup like `:embedded_falkordb_socket_timeout_ms`, and pass it to the remote `FalkorDB(...)` constructor.
- Give `_gralkor_run` a deadline. On expiry, cancel the coroutine's future and raise. `GraphitiPool.add_episode/6` and `Client.ingest/2` then return `{:error, :timeout}`.
- Log each timeout with the stage it hit. A deadlocked FalkorDB stays locked until it restarts, so retries will also fail; the log has to make that visible.

**Acceptance**
- A FalkorDB test double that never replies makes `add_episode` return `{:error, :timeout}` within the configured deadline.
- An invalid timeout raises `ArgumentError` at startup.

## 2. Remove replacement Lenses completely

**Problem**
- Replacement Lenses write a separate graph shape through `%Gralkor.Graph{}`. Its nodes and relationships have no embeddings and no episode attribution, and their ownership is tracked by `_gralkor_lens`.
- Graphiti resolution and `memory_search` never see them.
- With structured ingestion abandoned, they are surface area with no consumer value.
- Phil's main branch exposes `write: "replace_graph"` in its runtime-configuration UI but never calls `Client.replace`. Its code-graph branch removed the only call site.

**Change.** Delete the replacement path end to end.
- **Modules:** `Gralkor.Replace`, `Gralkor.Graph`, `Gralkor.Lens.Replaceable`.
- **Functions:**
  - `Gralkor.Client.replace/1` and `/2`
  - `Gralkor.Lens.Store.replace_graph/2`
  - the `replace_graph/2` callback in `Gralkor.Lens.Storage`, and its implementations in `Storage.Graphiti` and `Storage.InMemory`
  - `GraphitiPool.replace_graph`
- **Runtime:** remove `write: :replace_graph` support from `JidoGralkor.Runtime` (definition building, around lines 220 and 409).
- **The `:write` key:** with only one write mode left, drop it from Lens definitions entirely. A definition that still supplies `:write`, or `write: :replace_graph`, raises at runtime-configuration validation with migration guidance, as the existing `:search_destinations` removal does.
- **The `_gralkor_lens` marker:** it exists only for replacement ownership, so remove it from code and docs.
- **Docs:**
  - the Lenses bullet in CLAUDE.md's Mental Model, and the line "`_gralkor_lens` continues to mean replacement ownership"
  - the replacement sections in the README and `DESTINATIONS.md`
- **Test trees:** remove the replacement leaves in `test-trees/functional/runtime-configuration_TEST_TREES.md` and `test-trees/unit/jido-gralkor-runtime_TEST_TREES.md`.
- **Tests:**
  - delete `test/functional/lens_graph_replacement_functional_test.exs`
  - strip replacement cases from about 15 other test files: storage, pool, runtime validation, plugin, the functional suites, and the `memory_adventure` journey

**Acceptance**
- None of `replace_graph`, `Gralkor.Graph`, `Gralkor.Replace`, `Replaceable` or `_gralkor_lens` remains in `lib/`, the test trees, the README, CLAUDE.md or `DESTINATIONS.md`.
- A runtime configuration with a `:write` key raises with migration guidance.
- Appending Lenses work unchanged without `:write`.

**Consumer migration (Phil)**
- Remove the `replace_graph` option from `Phil.RuntimeConfiguration` and `RuntimeConfigurationLive`.
- Drop `"write"` from stored Lens definitions before upgrading.
- Check whether any deployed graph holds `_gralkor_lens`-marked nodes. If it does, deleting them is a one-off Cypher cleanup, outside this CR.

---

**Out of scope**
- Pinning FalkorDB versions
- Graphiti-native structural writes
- A previous-episodes option
- `max_tokens`, the edge-extraction cap, and custom extraction instructions

**Suggested order:** do item 2 first, since it is pure removal and shrinks the surface; then item 1. Both go through `change` → test trees → `tdd`.
