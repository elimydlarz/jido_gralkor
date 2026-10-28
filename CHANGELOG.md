# Changelog

## [12.0.0] - 2026-10-28

One simplified search. This is a breaking release; migration guidance follows each entry.

### Changed
- `Gralkor.Client.search/1,2` takes `%Gralkor.Search{operator_id, query, destinations, entity_types, edge_types}` and always returns everything relevant: `{:ok, [%{destination: name, facts: [...], nodes: [...], episodes: [...]}]}`, one map per Destination in selected order (default every accessible registered Destination). Each Destination is searched by ONE Graphiti `search_` call (the `COMBINED_HYBRID_SEARCH_RRF` recipe without its community layer: edges and nodes by BM25 plus cosine similarity with reciprocal rank fusion, episodes by BM25; the query is embedded once) with one `SearchFilters(node_labels: entity_types, edge_types: edge_types)`. Each kind keeps relevance order and is capped per Destination at 20 facts, 20 nodes, and 5 episodes (`Gralkor.Search.limits/0`). **Migrate:** replace the flat `%{destination:, fact: | node: | episode: | artefact:}` list with each Destination map's `facts`, `nodes`, and `episodes`.
- `entity_types` restricts nodes to those labels and restricts facts to edges whose source and target entities both carry one of them; `edge_types` restricts facts; neither restricts episodes.
- Every fact also carries its edge's `relationship` name and its `source_node` and `target_node` as `%{uuid:, name:}` (all `nil` in the in-memory test backend), so a consumer can render "Commit X CHANGES Function Y". Existing fact fields are unchanged.
- Episodes keep their structured shapes: direct, Lens, and Reflection episodes, the last carrying `artefact: %{id:, payload:}` and its `reflection` writer, so Reflection artefacts arrive whole. A Reflection episode appears only once its extraction has durably completed; that filter now applies to the episodes Graphiti ranks within the search's shared limit rather than to every episode in the graph.
- `JidoGralkor.Actions.MemorySearch` runs the one search and renders a `Facts` section (fact bullets under Lens, Reflection, or direct-source headings), an `Entities` section, and a compact `Episodes` section (a writer label and an excerpt of at most 280 characters; Reflection artefacts summarised by identifier and a payload excerpt). An empty result reads `No matching memory.`; the omission notice reads `Omitted (response limit): facts N, entities M, episodes K.` **Migrate:** update anything that matched the old text.
- The packaged `generalisations` Reflection's related-memory retrieval uses the same `Client.search/2` with the ingested content as the query and passes the per-Destination results to inference. It still searches every accessible registered Destination; where generalisations are written is unchanged.
- `Gralkor.Destination.Storage`'s `search` callback is now `search(destination, operator_id, query, opts)` returning `{:ok, %{facts:, nodes:, episodes:}}` (opts carry `:limits` and optional `:entity_types`/`:edge_types`). **Migrate:** custom Destination storages implement search/4.

### Removed
- `Gralkor.Search` fields `result_type` (`:facts`, `:nodes`, `:episodes`, `:artefacts`), `lenses`, `artefact_id`, and `max_results`. They remain struct keys defaulting to `nil` only so that setting one raises `ArgumentError` naming the field with migration guidance. **Migrate:** drop `result_type` and read the kind you need; drop `lenses` and tell writers apart by each episode's or fact source's `lens`; drop `artefact_id` and match `episode.artefact.id` among a Destination's episodes (query with the artefact's content or id); drop `max_results`.
- Artefact search, including its historical-duplicate convergence and conflict reporting.
- `MemorySearch`'s `lenses` parameter. **Migrate:** keep `destinations`.
- `GraphitiPool.search_episodes/3,4,5` and `GraphitiPool.search_nodes/5`, replaced by `GraphitiPool.search_memory/5`.

### Fixed
- Facts a Lens graph replacement inserts are found by search whatever `group_id` the caller stored on them, as 11.2.0's fact search found them. The one search runs on the Destination's own graph and no longer also filters by the stored `group_id`.
- A search with more than one entity type no longer fails on FalkorDB: graphiti-core 0.31.2 renders several labels as `n:A|B`, which FalkorDB rejects, and Gralkor now rewrites that clause as `(n:A OR n:B)` for the FalkorDB provider.

## [11.2.0] - 2026-10-27

### Changed
- Graphiti runtime bumped to `graphiti-core[falkordb,google-genai] == 0.31.2`. Graphiti's OpenAI defaults are now `gpt-6-luna` (main and small) and `gpt-4.1-mini` (reranker), and its `auto` reasoning effort sends `none` for GPT-5.1 and later majors.
- jido_gralkor no longer derives an OpenAI reasoning tier (`none` for GPT-5.5 and GPT-5.6): an unset `GRALKOR_LLM_REASONING` keeps Graphiti's own `auto`. A model that rejects `none` (such as `gpt-6-astra`) needs `GRALKOR_LLM_REASONING=low` or higher.
- An unconfigured reranker is built for the LLM's provider with Graphiti's default reranker model and its own client; the OpenAI reranker no longer reuses the LLM client.
- The embedded empty-edge-candidate guard is removed: graphiti-core 0.31.2 no longer searches edges with an empty `edge_uuids` candidate filter (it filters duplicate candidates by endpoints).
- `GraphitiPool`'s `:construct_shared_clients` substitute receives the single decided client spec (`shared_client_spec/1`) instead of the LLM and embedder specs; `validate_native_models!/1` takes the complete inference settings.

### Added
- Optional inference settings, each unset meaning Graphiti's own default: `GRALKOR_RERANKER_MODEL` (the reranker's own provider and model); `GRALKOR_LLM_ROUTES` (JSON routing Graphiti prompt groups or group-qualified prompts to their own model and tuning through Graphiti's `LLMRuntime`); `GRALKOR_LLM_TEMPERATURE`, `GRALKOR_LLM_MAX_TOKENS`, `GRALKOR_LLM_REASONING` and `GRALKOR_LLM_VERBOSITY` (OpenAI), and `GRALKOR_LLM_THINKING_BUDGET` (Google; any integer of at least -1, `0` turning thinking off and `-1` asking for a dynamic budget, also as a route's `thinking_budget`) for the `GRALKOR_LLM_MODEL` client; `GRALKOR_EMBEDDER_DIMENSION`; and `GRALKOR_EMBEDDER_BATCH_SIZE` (Google; unset keeps one input per request).
- Startup raises before any inference client is constructed for a malformed route or tuning value (naming the variable or key, field, and value), a tuning setting the model's provider does not accept (naming the setting and provider), or a missing credential for any provider a reranker or route selects (naming the role).

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
