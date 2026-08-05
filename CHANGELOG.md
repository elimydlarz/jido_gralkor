# Changelog

## [Unreleased]

### Fixed
- **Recall returned facts unrelated to the query.** `Gralkor.Interpret` was never told what was asked — it judged relevance against the buffered conversation alone. A recall from a session that never carried the query (a fresh session, or a `memory_search` whose query is not the last user turn) therefore filtered against nothing: for "Where does Eli work?" the graph search ranked "Eli works at Anthropic" first and interpretation dropped it in favour of an unrelated fact from the same group. `Recall` now passes the query to `Interpret.interpret_facts/6`, which renders it as a `Request to answer:` section; the conversation is still trimmed oldest-first to the char budget, the request and the facts never are.
- **Every legacy generalisation write failed.** `Gralkor.Generalise` passed the new generalisation's id as graphiti's `add_episode(uuid: …)`, which *loads an existing* episode to re-extract against — so each write raised `NodeNotFoundError` inside the flush task and nothing reached the `_gen` group. Generalisations are now written as new episodes with graphiti minting the episode uuid.
- **Recall never surfaced a generalisation.** The generalisation search read graphiti *edges* and tried to decode each fact as the `GEN|v1|` wire format, which extracted facts never carry; and a generalisation naming one subject yields a node with no edge at all. It now reads nodes (`GraphitiPool.search_nodes`), the same primitive ERL uses.
- **The redislite orphan sweep killed live servers owned by the same VM.** `Gralkor.Python.init/1` SIGKILLed every `redislite/bin/redis-server` on each boot, so the second journey module in a run killed the first module's database mid-test. The sweep now runs once per VM — the one moment when every matching server predates it. `pgrep -af` also dropped to `pgrep -f`: on macOS `-a` includes the caller's *ancestors* in the match list.
- **`ontology-extraction` was flaky by construction.** Its entity types carried no description, and graphiti's extractor reads a custom type's description to decide when to mint it (the lesson `Gralkor.LearningEntity` already encodes). 1–2 of its 3 assertions failed per run; with descriptions declared it passes run after run.
- `Gralkor.DistillTest`'s arity assertions now `Code.ensure_loaded!/1` first — `function_exported?/3` answers `false` for a module the VM has not loaded, so random ordering could fail them.

### Added
- `entity Foo, "when to extract one" do … end` — `Gralkor.Ontology` entities can now declare a description, rendered as the extracted type's own description for graphiti's extractor. Optional; the description must be a literal string.

### Removed
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
