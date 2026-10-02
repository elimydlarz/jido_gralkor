# Changelog

## [11.1.0] - 2026-10-03

### Changed
- Graphiti runtime bumped to `graphiti-core[falkordb,google-genai] == 0.30.2`. Graphiti now scopes the driver to each `add_episode` call, writes FalkorDB datetimes in UTC, stops storing a `labels` property on entity nodes, fixes the FalkorDB edge full-text search plan, and ranks node-mentions results by descending mention count. The packaged empty-edge-candidate guard is still required; the explicit `reasoning: "none"` is still required for GPT-5.6 and remains explicit for GPT-5.5.
- Gralkor's claim-fenced and direct-writer graph writes store entity types only as (quoted) graph labels, matching graphiti 0.30.2.
- `Gralkor.Client.reflect/5` accepts only `:inference`, `:tool_executor`, `:tools`, and `:tool_context`; other options return `{:error, {:unsupported_reflection_options, keys}}` instead of silently overriding artefact identity, storage, or the retry window.
- `JidoGralkor.Plugin` rejects a Lens that accepts only whole-graph replacement, both as the mounted `:ingestion_lens` and as a per-turn `tool_context[:lens]`, instead of failing later at capture.
- `GraphitiPool.add_episode` reports inference-provider failures as `{:upstream_llm, {:rate_limited | :provider, detail}}`; capture no longer retries them on top of the provider client's own retries.
- `Gralkor.Lens.Storage.Graphiti.search/4` rejects unknown options; a blank or whitespace-only `GRALKOR_DATA_DIR` counts as unset.
- A custom Reflection `:inference` callback must return `{:ok, %{output: map}}`, `{:ok, %{tool_calls: list}}`, or `{:error, reason}`; the former `{:tool_calls, calls}` and bare `{:ok, map}` shapes now fail as `{:invalid_inference_response, _}`. Built-in inference no longer adds `:tools` to the tool context.
- Runtime validation names the offending provenance delimiter, and Chain-of-Thought parsing names the innermost unsupported type.
- Private-graph migration: `advance` persists at most one durable graph phase per call across graphs, `prepare` refuses an existing journal, a journal held by another operation is refused with a clear error, and journals stay owner-only even when a stale temporary file is reused.
- `RUNTIME_CONFIG.md` is folded into the README; the Hex package maintainer is `elimydlarz`.

### Fixed
- A JidoGralkor runtime outlived its AgentServer after a normal stop, so admitted Reflection work kept running and invoked callbacks. The runtime now monitors its owner and stops with it for any reason.
- Plugin hooks delivered through `Jido.AgentServer.call` targeted the hook task instead of the AgentServer, so capture failed with "runtime unavailable". The plugin resolves its owning AgentServer through Jido's registry.
- Built-in Reflection inference crashed on unexpected ReAct terminations; it now returns the termination reason as an error.
- `Gralkor.Client.replace` with a non-graph value now raises the documented "invalid graph data" error.
- The capture flush warning no longer claims a retry that the capture buffer may not perform.
- A Reflection finishing in the instant after its AgentServer stopped could still invoke its callback; outcomes are now reported only while the owner is alive.
- Graphiti failure diagnostics stay on one line even when an exception message spans several lines.
- Migration journal updates no longer follow a symbolic link left at the temporary journal path.

## [11.0.0] - 2026-09-15

- **Breaking:** replace the packaged `operator` Destination with `personal` and the packaged `operator` Lens with `personal-chat`. Private graph identity is `personal/<same operator_id>`; `global` and ERL's extraction ontology remain unchanged.
- Require explicit plugin `capture_destination` and typed runtime-targeted `Gralkor.Capture` requests. Select direct storage or distinct Lens processes, preserving per-turn routes without an automatic duplicate write. Positional capture adapters now raise migration guidance.
- Preserve truthful direct, Lens, Reflection, and historical provenance in public search. Direct authorship trusts persisted `Episodic._gralkor_writer` metadata; marker-like historical text alone remains unchanged and unclassified.
- Add restartable graph migration tooling with retained sources, exact inventories, conflict checks, and guarded rollback. Migration journals bind operations to a canonical endpoint identity, and controlled recovery explicitly rebinds a changed endpoint before further mutations. Coordinate Phil's typed persisted configuration migration and archival Reflection delivery with the migration runbook before deployment.
- Make the stale-writer test's ownership-transfer condition deterministic and separate Native deadline forwarding from Python fixture execution speed.

## [8.0.1] - 2026-08-27

### Changed
- **BREAKING: memory placement is Destination-based.** Each Destination is one graph. `global` names the single shared global graph, `operator` resolves to `operator/<agent.id>`, and application-defined Destination names resolve literally. The former scope/address configuration shape is removed.
- **BREAKING: Lenses and Reflections reference Destinations.** Appending Lenses and Reflections own extraction ontologies; replaceable Lenses own only graph content carrying their reserved Lens marker. Search selects Destinations directly and returns Destination-attributed facts, nodes, episodes, or Reflection artefacts.
- Implicit plugin capture, memory addition, recall, and community building now consistently target `operator/<agent.id>`, so implicit and named `operator` Lens writes share one graph.
- `global` is the normal target for shared application memory. A name such as `global/x` is a separate literal Destination and therefore a separate graph.

### Fixed
- **Graphiti writes failed for GPT-5.6 OpenAI models.** `GraphitiPool` left `LLMConfig.reasoning` at graphiti-core 0.29.3's `auto` sentinel, whose unknown-family fallback selected the unsupported `minimal` tier for `gpt-5.6-luna`. GPT-5.5 and GPT-5.6 clients now receive `none` explicitly; other OpenAI models retain graphiti's automatic selection.
- **Every legacy generalisation write failed.** `Gralkor.Generalise` passed the new generalisation's id as graphiti's `add_episode(uuid: …)`, which *loads an existing* episode to re-extract against — so each write raised `NodeNotFoundError` inside the flush task and nothing reached the `_gen` group. Generalisations are now written as new episodes with graphiti minting the episode uuid.
- **Nothing could read a stored generalisation back.** Both the recall generalisation search and `Gralkor.Client.search_generalisations/3` read graphiti *edges* and tried to decode each fact as the `GEN|v1|` wire format, which derived facts never carry — so both returned nothing on every call. Recall's now reads nodes (`GraphitiPool.search_nodes`, the primitive ERL uses) for semantic relevance; `search_generalisations/3` reads episodes, whose stored body is the only place the envelope exists.
- **A node search never matched a group id containing hyphens.** `GraphitiPool.search_nodes/5` restricted `group_ids` to the caller's raw id while episodes are written under the sanitised one, so ERL recall for any hyphenated operator group returned nothing.
- **The redislite orphan sweep killed live servers owned by the same VM.** `Gralkor.Python.init/1` SIGKILLed every `redislite/bin/redis-server` on each boot, so the second journey module in a run killed the first module's database mid-test. The sweep now runs once per VM — the one moment when every matching server predates it. `pgrep -af` also dropped to `pgrep -f`: on macOS `-a` includes the caller's *ancestors* in the match list.
- **`ontology-extraction` was flaky by construction.** Its entity types carried no description, and graphiti's extractor reads a custom type's description to decide when to mint it (the lesson `Gralkor.LearningEntity` already encodes). 1–2 of its 3 assertions failed per run; with descriptions declared it passes run after run.
- `Gralkor.DistillTest`'s arity assertions now `Code.ensure_loaded!/1` first — `function_exported?/3` answers `false` for a module the VM has not loaded, so random ordering could fail them.
- **Rebuilding the graph's indices rebuilt a database no episode is written to.** `GraphitiPool.build_indices/1` resolved the instance for a hardcoded `"default_db"` group; since every group is its own FalkorDB database, the `memory_build_indices` action never touched a group holding real data. It now rebuilds every group the pool holds an instance for — a group whose instance has not been created yet has its indices built the moment it is.
- **A recall whose deadline expired said nothing.** The expiry now logs a warning naming the session and the budget, as the retry-ownership contract already required.

### Added
- `entity Foo, "when to extract one" do … end` — `Gralkor.Ontology` entities can now declare a description, rendered as the extracted type's own description for graphiti's extractor. Optional; the description must be a literal string.
- `Gralkor.GraphitiPool.search_episodes/4` — graphiti's BM25-over-content episode search, returning `{:ok, [%{content:, source_description:}]}`. The primitive for content Gralkor wrote in a format it must read back verbatim; unlike edge and node search, it does not depend on what an extractor derived.

### Removed
- `Gralkor.Interpret` and recall's second inference pass. Recall now presents every search result verbatim and in search order inside the untrusted memory block, retaining each result's available source wording for the consuming agent to interpret with its own model and conversation context.
- `Gralkor.GraphitiPool.credential_env/1` and `Gralkor.Client.Native.generalise_evaluate_callback/0` — neither had a caller, a test, or a documented consumer.
- `Gralkor.Generalise`'s `:remove_episode_fn` option and its contradicts-removal path. It addressed graphiti by a generalisation id that is not an episode uuid, so it could never have deleted anything. A contradicting generalisation is persisted as an ordinary new episode recording its lineage, matching `Gralkor.Lens.Ingestion.Generalise`.

## [4.1.0] - 2026-07-01

### Changed
- **ERL recall is now unconditional and uses graphiti NODE search.** Every recall runs a parallel learning search over the plugin's built-in `Learning` graphiti custom-entity nodes via `Gralkor.GraphitiPool.search_nodes/5` (graphiti `g.search_` + `NODE_HYBRID_SEARCH_RRF` + `SearchFilters(node_labels: ["Learning"])`), seeded with the raw user query. No LLM classification, no opt-in flag.
- `Gralkor.AgentLearning` is written via `add_episode` with the `Learning` custom entity type (`Gralkor.LearningEntity`) merged onto `entity_types` — graphiti's extractor creates a `Learning`-labelled node (with `problem_kind`/`approach`/`success`/`lesson` attributes) and connects it to the domain entities it extracts. ERL applies even with no consumer ontology configured.
- `Gralkor.GraphitiPool.search_nodes/5` — new NODE-search primitive returning `{:ok, [%{name:, summary:, attributes:}]}`, filterable by `:node_labels`. This is the correct primitive for retrieving custom-entity nodes; edge search (`search/5`) cannot, because its `node_labels` filter matches edges by endpoint and misses standalone nodes.
- `Gralkor.LearningEntity` now carries a class **description** (graphiti uses the Pydantic docstring to decide when to extract the entity) and its attributes are **optional** (per graphiti's custom-entity docs, so extraction never drops the entity on a missing attribute). Custom entity/edge types built from an ontology spec now thread an optional `:description` into the generated Pydantic class `__doc__`.

### Fixed
- **ERL did not work end to end against real graphiti.** Two bugs, both surfaced only by live functional testing (the fake-infra suite was green): (1) the `Learning` custom entity type had no class docstring and used required fields, so graphiti's extractor never created a `Learning` node; (2) recall queried *edges* (`g.search` + `node_labels`), which filters edges by endpoint and so never returns a standalone `Learning` node. Fixed by giving the entity a docstring + optional fields and switching recall to NODE search (`search_nodes/5`). Verified live: `add_episode` now creates a fully-populated `Learning` node and `search_nodes(node_labels: ["Learning"])` retrieves it.
- **ERL learning search silently degraded on every recall (call-signature bug).** The client-wired `learning_search_fn` passed `search_filter:` as a positional arg to `GraphitiPool.search/5`; because that function carries defaults on both `server` (1st) and `opts` (5th), the 4-arg call bound the keyword list to `max_results` and failed the guard. The task raised `FunctionClauseError`, `Recall.await_aux` swallowed it, and the learning search returned `[]` — ERL quietly did nothing. Superseded by the move to `search_nodes/5` (the learning search now passes `node_labels` in opts with the server explicit).
- **All capture flush was broken in production.** `Gralkor.Application.build_flush_callback/2`'s default `add_episode_fn` was `&GraphitiPool.add_episode/5`; since `add_episode` carries defaults on `server` (1st) and `opts` (6th), the 5-arity capture bound `group_id`→`server` and raised `FunctionClauseError` on every flush, exhausting `CaptureBuffer` and writing nothing (not just learnings — all captured memory). Fixed to call `add_episode` with the server supplied explicitly; pinned by an integration test wiring the default callback against a real `GraphitiPool`.

### Changed
- `Gralkor.Interpret.interpret_facts/6` and `build_interpretation_context/5` take the recall query as their second argument. Consumers calling them directly must pass it; `Gralkor.Recall` already does.

### Removed
- `Gralkor.TaskKind` and the `:jido_gralkor, :erl_recall` opt-in flag — a dormant code path no consumer had ever set. The unconditional learning search replaces it.
- `Gralkor.GraphitiPool.search/5`'s `:search_filter` (edge `node_labels`) option — the wrong primitive for custom-entity retrieval, now dead after the move to `search_nodes/5`. `search/5` is now `search/4` (plain edge search).
- `ex-task-kind` test tree.

### Added
- Test-mode recall observability: with `config :jido_gralkor, :test, true`, each auxiliary search (gen, learning) logs its result count and contents (`[gralkor] [test] recall learning search — N result(s): …`), so ERL firing and the exact learning content pulled are visible before interpretation.

### Changed (other)
- Graphiti runtime bumped to `graphiti-core[falkordb,google-genai] >= 0.29.2` — a bug-fix release: FalkorDBLite embedded support with Redis pinning, nul-byte stripping from parameters, and RediSearch escaping fixes. No API changes.

## [4.0.0] - 2026-05-30

### Added
- Custom ontology support. Set `config :jido_gralkor, ontology: MyApp.Ontology` (a module declared with `use Gralkor.Ontology`) to apply a typed entity/edge schema to **all** memory writes — auto-capture and `memory_add` alike — so graphiti extracts and recalls against your own entities instead of generic nodes. Single deployment-wide knob: never a plugin mount opt, agent-state value, or tool argument. Unset → behaviour identical to pre-ontology releases. Programmatic callers can override per-write via `Gralkor.Client.memory_add/4`.

### Changed
- **BREAKING.** Application-env namespace unified under `:jido_gralkor`. The legacy `:gralkor_ex` atom (preserved at 3.0.0 for zero-churn migration) is gone — consumers must rewrite every `config :gralkor_ex, …` line and every `Application.{get,put,delete}_env(:gralkor_ex, …)` call to `:jido_gralkor`. This removes the cosmetic `application :gralkor_ex ... is not available` warning Mix printed at boot because no `:gralkor_ex` OTP application ships.
- Graphiti runtime bumped to `graphiti-core[falkordb,google-genai] >= 0.29.1`.

## [3.0.0] - 2026-05-21

### Changed
- **BREAKING.** Absorbed the former `:gralkor_ex` Hex package. The `Gralkor.*` module namespace (Client, Client.Native, Client.InMemory, Python, GraphitiPool, CaptureBuffer, Recall, Distill, Interpret, Format, Config, Application) is now shipped inside `:jido_gralkor` itself — consumers no longer need a separate `{:gralkor_ex, ...}` line in `mix.exs`. Drop it; keep only `{:jido_gralkor, "~> 3.0"}`. The legacy `:gralkor_ex` package is deprecated on Hex and points here.
- The OTP `mod:` is now `Gralkor.Application`, supervising `Gralkor.Python` → `GraphitiPool` → `CaptureBuffer` when a FalkorDB backend is configured (embedded via `GRALKOR_DATA_DIR` or remote via `config :gralkor_ex, :falkordb`); empty children otherwise.

### Preserved (zero-churn for existing consumers)
- The `:gralkor_ex` Application-env namespace is preserved. Existing `config :gralkor_ex, falkordb: [...]` / `config :gralkor_ex, :interpret_max_output_tokens` / `config :gralkor_ex, client: Gralkor.Client.InMemory` lines in consumer configs continue to work unchanged — the atom is a stable namespace key the embedded code still reads.
- Public API surface (`JidoGralkor.Plugin`, `JidoGralkor.ReAct`, `JidoGralkor.Lifecycle`, `JidoGralkor.ContextRotator`, `JidoGralkor.Canonical`, `JidoGralkor.Actions.*`) and module shapes are unchanged. The merge is purely a packaging consolidation.

## [2.0.1] - 2026-05-21

### Changed
- `:gralkor_ex` pin bumped to `~> 3.1` to pick up `Gralkor.InterpretParseFailed` and the `:interpret_max_output_tokens` app env knob. Operators can now set `:gralkor_ex, :interpret_max_output_tokens` directly to control the interpret pipeline's output budget; see `Configuring Gralkor` in this package's README for the documentation.

## [2.0.0] - 2026-05-18

### Changed
- **BREAKING.** `:gralkor_ex` pin bumped to `~> 3.0`. The upstream renamed `end_session/1` to `flush/1` and added `flush_and_await/2`; consumers building against `:gralkor_ex ~> 2.x` no longer compile against this version.
- **BREAKING.** `JidoGralkor.Lifecycle` no longer owns idle-timer machinery. Its sole responsibility is now the death-triggered flush: on `AgentServer` graceful termination it fires `Gralkor.Client.flush/1` for the active session and returns. Consumers that want idle timeouts should use Jido's built-in `AgentServer` `:idle_timeout` option directly.

### Added
- `JidoGralkor.ContextRotator` — synchronous `rotate_now/2` primitive for in-life context consolidation. Flushes the active Gralkor session via `Gralkor.Client.flush_and_await/2`, installs a fresh thread on the agent, and seeds the rotated thread with the most-recent `keep_last_n` pre-flush entries plus any in-flight turns appended during the flush. The agent process is never stopped; periodic rotation is left to the consumer.
