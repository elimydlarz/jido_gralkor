# jido_gralkor

Canonical development and distribution home for Jido-first Gralkor. Ships the JidoGralkor.* plugin/lifecycle modules plus the embedded Gralkor.* adapter (Pythonx-driven graphiti, capture buffer, distill, interpret, recall); the legacy `:gralkor` and `:gralkor_ex` packages redirect consumers here.

**Test trees live under [`test-trees/`](test-trees/)** — the canonical contract between intent and tests. Functional and Journey trees describe application-visible behaviour; Integration and Unit trees describe the inner subjects revealed through TDD.

## Mental Model

- **Lenses** — the application registry at `config :jido_gralkor, :lenses` defines named memory channels. Each definition owns `:name`, an ontology module, `:scope` (`:operator` or `:global`), and an ingestion module implementing `Gralkor.Lens.Ingestion.ingest/2`. The callback receives `%Gralkor.Ingest{}` and a bound `Gralkor.Lens.Store`, and may make zero, one, or many writes. Every Lens resolves to the graphiti group its episodes live in: an operator-local Lens to a group derived from the operator id and Lens name, every global Lens to the shared `global` group with origin-Lens provenance in the original episode submission. Searching a global Lens and searching the reserved `"global"` Lens both query that one unfiltered group. `Gralkor.Client.ingest/1` and `search/1` are the direct consumer boundary. The implicit `"default"` Lens preserves the older deployment-wide `:ontology` and operator group and is always the first Lens searched.
- **Lens-aware plugin flow** — mount with `:default_lens` and optional `:search_lenses`; optionally set `:generalise_lens`. A query may override the selected ingestion Lens through `tool_context[:lens]`; the plugin retains that selection on the request-correlated Jido thread entry so terminal capture remains bound after ReAct releases its transient tool context. `memory_add` and automatic capture use that selected Lens, while `memory_search` always searches the requesting operator's reserved `"default"` destination first, then the configured local targets and optional `"global"` pool. The optional secondary generalisation Lens receives the flushed transcript independently and uses `Gralkor.Lens.Ingestion.Generalise`; it distils durable episodes and lets Graphiti's normal ingestion reconcile graph facts. Its ontology and scope come from its Lens, not a special partition.
- **Implicit-default plugin compatibility** — the plugin detail immediately below describes mounts without `:default_lens`; registered Lens mounts follow the Lens-aware flow above.
- **`JidoGralkor.Plugin`** — owns the `:__memory__` slot, validates `agent_name`, exposes the four memory/admin actions, and never recalls on its own. In implicit-default mode it plants agent/session context and captures through `/5` using the operator's legacy group and deployment ontology. In Lens mode it also plants Lens/search selections and captures through `/6` or `/7`. Both modes canonicalise completed and failed turns; missing user identity and capture failures surface immediately, while either outcome is skipped with a warning when no committed thread supplies session identity.
- **`JidoGralkor.ReAct`** — small helper module for `Jido.AI.Reasoning.ReAct.RequestTransformer` consumers. `maybe_force_memory_search/2` takes a transformer overrides map (whatever the consumer is already returning) plus the ReAct `State` and, on `state.iteration == 1` (the first turn of a ReAct loop), folds `tool_choice: %{type: "function", function: %{name: "memory_search"}}` into the overrides' `:llm_opts`. On subsequent iterations it returns the overrides untouched so the LLM is free to answer or call further tools. Acknowledged workaround: ReAct's `tool_choice` is a single config value applied uniformly across the loop; this helper is the cheapest way to pin it for one iteration without forking the strategy. A first-class `:preamble_tool` config in `Jido.AI.Reasoning.ReAct.Config` would supersede it.
- **`JidoGralkor.Lifecycle`** — pass-through `Jido.AgentServer.Lifecycle` callbacks plus graceful-stop flushing. `terminate/2` reads the committed Jido thread id and starts `Gralkor.Client.flush/1` without blocking termination; a missing thread causes no call, and background failures are logged. Jido's AgentServer owns idle-timeout policy.
- **`JidoGralkor.Canonical`** — the adapter-only module that translates a Jido/ReAct turn into Gralkor's canonical message shape. Takes `user_query` at face value — whatever string was registered with the request is what gets persisted — because the plugin and the rest of the pipeline keep `:query` the user's actual words (no envelope stripping is needed or performed here; harness-injected context is added at prompt-build time in the `RequestTransformer`, not in the query). Filters events that aren't memory-worthy, and renders surviving `:llm_completed` / `:tool_completed` events as `behaviour` messages with content the distillation LLM can read (`"thought: …"`, `"tool NAME → RESULT"`). The turn outcome terminates the message list: `{:completed, answer}` becomes the trailing `"assistant"` message; `{:failed, error}` becomes a terminal `"behaviour"` message `"request failed: …"` so the failure is visible to downstream distillation rather than silently swallowed. Returns `[]` when nothing is worth persisting; the plugin uses that to skip the capture call entirely.
- **`JidoGralkor.Actions.MemorySearch`** — the ReAct search tool. It short-circuits blank queries and missing sessions; Lens-aware mounts call `Gralkor.Client.search/1` even when their additional target list is empty, while implicit-default mounts use legacy `Gralkor.Client.impl().recall/4`. Errors propagate and successful Lens results are joined into the action result.
- **`JidoGralkor.Actions.MemoryAdd`** — the fire-and-forget write tool. Its background task calls `Gralkor.Client.ingest/1` when context selects a Lens and uses legacy `memory_add/3` otherwise; failures are logged and the action immediately returns `"Ingesting."`.

## Dependencies

Five direct Hex deps (six with `:ex_doc` for dev docs):

- `{:jido, "~> 2.2"}` — `Jido.Plugin`, `Jido.Action`, `Jido.Signal` (struct + pattern match).
- `{:jido_ai, "~> 2.1"}` — `Jido.AI.Request.get_request/2` (used once in the plugin to look up the user query for a completed `request_id`).
- `{:pythonx, "~> 0.4"}` — embeds CPython in the BEAM so the embedded Gralkor pipelines can drive `graphiti-core` directly. `Gralkor.Python.init/1` materialises the venv and initialises the interpreter at boot via `Pythonx.uv_init/2` from `priv/python/pyproject.toml` (the graphiti-core version requirement), read into `@pyproject_toml` at compile time via `@external_resource` — guarded idempotent against re-init. Consumers configure **nothing** about Python; there is no `:pythonx, :uv_init` block in any consumer config (the dep's own `config/config.exs` does not propagate to a consumer's runtime app env, so owning the manifest in the package — shipped via the `priv` entry in `mix.exs` `files:` — is the only way to keep Python an internal concern). The venv lands in PythonX's uv cache (not `priv/`), built at runtime on first boot. The manifest reads `"graphiti-core[falkordb,google-genai]>=0.29.2"` and covers **both** supported inference providers: graphiti-core requires `openai` unconditionally (`Requires-Dist: openai>=1.91.0`, verified against installed 0.29.3 METADATA) and publishes no `openai` extra, so the OpenAI LLM, embedder, and reranker classes import from this manifest as-is; naming a non-existent extra only makes uv warn on every resolve. `Gralkor.Python.smoke_import_provider_clients/1` imports a given provider's LLM, embedder, and reranker classes to prove that.
- `{:req_llm, "~> 1.0"}` — LLM client used by the embedded Distill + Interpret pipelines (provider-portable via `response_model`-bearing Pydantic schemas).
- `{:jason, "~> 1.4"}` — JSON parsing for the embedded pipelines.

**Embedded Gralkor adapter.** `Gralkor.*` contains both legacy pipelines and the Lens boundary. Lens capture uses `capture/6` or `/7`, batches by Lens, and flushes through `Client.ingest/1`; Lens ingestion owns any learning or distillation beyond its configured process. The implicit-default compatibility path uses `capture/5`, `memory_add/3`, `recall/4`, unconditional AgentLearning during legacy flush, optional `:generalise_on_flush`, the separate `_gen` partition, and deployment-wide `:ontology`. Both paths share Pythonx, GraphitiPool, CaptureBuffer, ontology materialisation, and lifecycle flushing.

## Configuring Gralkor

`:jido_gralkor` is the integration point for operators who run a Jido agent on top of Gralkor. All operator-facing knobs live under the `:jido_gralkor` application env.

**Lenses.** `:lenses` is a list of application-owned keyword definitions with `:name`, `:ontology`, `:scope`, and `:ingestion`. `JidoGralkor.Plugin` selects registered names through `:default_lens`, `:search_targets`, and optional `:generalise_lens`; see README `Configure Lenses` for the consumer API. Registry and mount validation fail fast. The deployment-wide `:ontology` and `:generalise_on_flush` settings below describe the implicit-default compatibility pipeline.

Pick **one** of the two backends:

**Embedded FalkorDB (development / local).** Set `GRALKOR_DATA_DIR` to a directory the BEAM can write to. The adapter constructs an in-process `falkordblite` instance, which spawns a `redis-server` grandchild under that directory.

```bash
GRALKOR_DATA_DIR=/var/lib/gralkor mix start
```

**Remote FalkorDB (production).** Set `:jido_gralkor, :falkordb` in `config/runtime.exs` to a keyword list with at least `:host` and `:port`; optionally `:username`, `:password`, and `:ssl` (default `false`; set `true` for FalkorDB Cloud or any TLS-fronted endpoint). The adapter connects directly via the network and does not import `redislite` or spawn any local redis-server.

```elixir
# config/runtime.exs
config :jido_gralkor,
  falkordb: [
    host: System.fetch_env!("FALKORDB_HOST"),
    port: String.to_integer(System.fetch_env!("FALKORDB_PORT")),
    username: System.get_env("FALKORDB_USERNAME"),
    password: System.get_env("FALKORDB_PASSWORD"),
    ssl: System.get_env("FALKORDB_SSL") == "true"
  ]
```

Remote wins when both are configured. Misconfiguration (non-keyword value, missing host/port, blank host, non-positive port) raises `ArgumentError` at app start before any child is supervised — operator typos surface immediately, not under the first user request.

**Interpret output budget (optional).** Set `:jido_gralkor, :interpret_max_output_tokens` to a positive integer to override the per-recall LLM output ceiling used by the interpret pipeline. Default is `2000`; raise it if your agent's recall queries surface many candidate facts and you observe `Gralkor.InterpretParseFailed` (the parser refuses truncated responses rather than passing through half-JSON). Lower it to cap latency and cost on narrower workloads.

```elixir
# config/runtime.exs
config :jido_gralkor, interpret_max_output_tokens: 2000
```

**Implicit-default auto-generalise on flush (optional).** Set `:jido_gralkor, :generalise_on_flush` to `true` to fire legacy `Gralkor.Generalise` after each successful implicit-default capture flush. Registered Lens mounts use `generalise_lens` instead. `:generalise_min_confidence` (default `0.3`) applies to both generalisation pipelines.

```elixir
# config/runtime.exs
config :jido_gralkor, generalise_on_flush: true
config :jido_gralkor, generalise_min_confidence: 0.5
```

**ERL recall (experiential learning on every recall — unconditional, no flag).** There is no `:erl_recall` knob. On every recall, `Gralkor.Client.Native` wires a `learning_search_fn` into the `Gralkor.Recall` opts that calls `Gralkor.GraphitiPool.search_nodes/5` with `node_labels: ["Learning"]` — a graphiti **NODE** search (`g.search_` + `NODE_HYBRID_SEARCH_RRF` + `SearchFilters(node_labels: ["Learning"])`) restricting results to the plugin's built-in `Learning` custom-entity nodes (`Gralkor.LearningEntity`, merged additively onto every learning write's `entity_types`, regardless of the configured ontology or its absence). **Node search, not edge search:** a `Learning` is a custom-entity *node*; `GraphitiPool.search/5` (edge search) filters edges by endpoint label and so misses standalone `Learning` nodes — using it returned `[]` on every recall (a bug found only by live functional testing). Each returned node is formatted from its `name`/`summary`/`attributes`. Seeded with the raw user query (no LLM classification, no `TaskKind`), it runs in parallel with the main and gen searches under the same 5s `await_aux` yield, degrades to `[]` on failure/timeout, and its results are combined with the regular facts before interpretation — so the interpreter surfaces the `Learning` nodes that came from the same kind of problem, biased toward succeeded approaches (the bias lives in the node's summary/attributes, not a query primitive). For graphiti to actually create the `Learning` node, `Gralkor.LearningEntity` declares a class **description** (graphiti uses the Pydantic docstring to decide when to extract the entity) and **optional** attributes (per graphiti's custom-entity docs); without the docstring the extractor never mints the node. Deleting `Gralkor.TaskKind` and the `:erl_recall` flag removed a dormant code path that no consumer had ever set; the unconditional path is what ERL now means.

**Implicit-default ontology (optional).** `:jido_gralkor, :ontology` is the deployment-wide schema for legacy capture and `memory_add`. Registered Lenses instead select their own ontology. Unset preserves generic extraction; invalid modules raise at the write boundary.

```elixir
# config/runtime.exs
config :jido_gralkor, ontology: MyApp.Ontology
```

**Inference providers.** Optional model overrides (`GRALKOR_LLM_MODEL`, `GRALKOR_EMBEDDER_MODEL`) are read straight from `System.get_env/1` by `Gralkor.Config`, which stays provider-agnostic: it preserves the general `%{provider:, id:}` model shape and splits only the first colon. `Gralkor.GraphitiPool` owns provider policy through `@supported_providers [:openai, :google]` and `@credential_env %{openai: "OPENAI_API_KEY", google: "GOOGLE_API_KEY"}`, exposed as `supported_providers/0` and `credential_env/1`. Defaults are `google:gemini-3.1-flash-lite` (llm) and `google:gemini-embedding-2-preview` (embedder).

- `validate_native_models!/2` runs before any inference client is constructed. It raises `ArgumentError` when either spec names a provider outside the supported set, naming both specs and the supported providers; and raises when the credential for a provider a spec **selects** is absent or blank, naming the variable and the role (`"llm"` or `"embedder"`). A provider selected by neither role needs no credential, so an all-Google pair needs only `GOOGLE_API_KEY`.
- `shared_client_spec/2` is the pure per-role decision — no Pythonx, no credentials read — so `default_construct_shared_clients/2` has nothing left to decide. The **llm** role's provider builds the LLM client **and the cross-encoder/reranker** (the reranker has no spec of its own); the **embedder** role's provider builds the embedder. A Google embedder carries `batch_size: 1` (the gemini-embedding-2-preview batching defect, getzep/graphiti#1467); an OpenAI embedder carries no batch size.
- `default_construct_shared_clients/2` dispatches on that spec to `GeminiClient`/`GeminiEmbedder`/`GeminiRerankerClient` or `OpenAIClient`/`OpenAIEmbedder`/`OpenAIRerankerClient` per role. Mixing roles is supported: an OpenAI LLM with a Google embedder builds an OpenAI LLM, an OpenAI reranker, and a Google embedder, and needs both `OPENAI_API_KEY` and `GOOGLE_API_KEY`. Nothing checks cross-provider embedding-dimension compatibility — there is no such check.
- A deployment that never opted into the native runtime (neither `:falkordb` nor `GRALKOR_DATA_DIR`, or `Gralkor.Client.InMemory` pinned) starts no pool, so no provider validation happens at all.

BEAM-side ReqLLM calls in `Gralkor.Client.Native` use `Config.llm_model()`, so they follow the llm role's provider and remain provider-portable; the focused interpretation functional suite deliberately calls OpenAI without starting Graphiti. Deterministic Lens tests pin both `client: Gralkor.Client.InMemory` and `lens_storage: Gralkor.Lens.Storage.InMemory`.

## Testing

Legacy tests use `Gralkor.Client.InMemory` and reset it per scenario. Lens tests additionally configure `lens_storage: Gralkor.Lens.Storage.InMemory` and start a fresh storage process per test; pinning only the client does not intercept `Client.ingest/1` or `search/1`.

Any test that starts a `Gralkor.GraphitiPool` needs a credential present for each provider its model specs select, because `validate_native_models!/2` refuses to start without one — even when client construction is stubbed and no provider is ever called. `Gralkor.TestEnv.load/1` therefore sets an obvious placeholder for `GOOGLE_API_KEY` and `OPENAI_API_KEY` when the variable is genuinely absent, after loading `.env`, so a real key always wins and the functional suites keep calling real providers.

```bash
mix test            # default run: unit + integration, excluding :functional and :journey — no real LLM/graphiti calls
mix test.unit       # only :unit (excludes integration, functional, journey)
mix test.integration
mix test.functional # application-visible feature behaviour; some suites use real LLM/graphiti boundaries
mix test.journey    # broad whole-application Functional workflows; some require external services
```

Functional tests describe application-visible behaviour and may use deterministic substitutes or focused live boundaries. Journey tests are the broad workflow form of Functional coverage. Real LLM and graphiti-core extraction calls remain confined to these opt-in suites; a default `mix test` is deterministic. The boundary contract those tiers used to be the sole proof of — which graphiti `add_episode` kwargs an ontology populates — is now pinned deterministically by [`test-trees/unit/ontology-graphiti-spec_TEST_TREES.md`](test-trees/unit/ontology-graphiti-spec_TEST_TREES.md) (`Gralkor.GraphitiPool.graphiti_boundary_spec/1`, pure, no Pythonx). The functional `ontology-extraction` suite remains the proof that a real LLM honours the declared schema.

`test/functional/interpret_epistemic_humility_test.exs` is the focused real-model proof for interpretation behavior. It loads `OPENAI_API_KEY` from `.env`, calls OpenAI `gpt-4.1-mini` through ReqLLM at temperature `0.0`, and covers varied source types, adversarial conflicting accounts, ordinary memories without provenance, and relevance filtering. It starts no Graphiti or FalkorDB runtime. Missing credentials fail fast rather than skip.

### Mutation testing

`{:muzak, git: "git@github.com:elimydlarz/muzak.git", branch: "elixir-1.19", only: :test}` — upstream `1.1.1` is unmaintained since 2022 and breaks on Elixir 1.19; the fork replaces Muzak's frozen 2400-line copy of `Code.Formatter` with a thin wrapper over the public `Code.string_to_quoted_with_comments!/2` + `Code.quoted_to_algebra/2`, fixes the `ExUnit.Server.modules_loaded` arity change, and disables the `test_helper` autorun so it doesn't crash on teardown.

**Why a private SSH git dep, not Hex:** upstream Muzak is licensed **CC-BY-NC-ND-4.0** — the **NoDerivatives** clause forbids *distributing* a modified version, so the patched fork can't be published to Hex or kept in a public repo. The fork lives in the **private** repo `elimydlarz/muzak`; CC permits producing adaptations for private, non-commercial use. Consequence: `MIX_ENV=test mix deps.get` (and therefore `mix test`) needs SSH access to that private repo — outside collaborators without access can't fetch the test deps. The **NonCommercial** clause also applies if this is ever used commercially (Muzak Pro is the licensed path for that). Do not publish this dep or make the fork public.

```bash
mix muzak                      # sample up to 1000 mutations across lib/, run the suite (excl. :functional/:journey) against each
mix muzak --only lib/path.ex   # scope to one file (also --only lib/path.ex:LINE)
mix muzak --mutations N        # cap the sample size (fast local check)
mix muzak --seed N             # reproducible mutation sample
```

A mutation that no test fails on is a **survivor** — a gap in the suite. Each mutation restarts the app stack, so full runs take tens of minutes; scope with `--only` for fast feedback. The runner relies on `test_helper.exs` keeping `InMemory.start_link` idempotent (it re-requires the helper per mutation).

## Test Trees

See [`test-trees/`](test-trees/) — the canonical contract between intent and tests for this project.

## Pending cleanups

- **`test/jido_gralkor/actions/error_encoder_compat_test.exs`** — added to pin the
  jido_ai 2.1.0 encoder bug where `normalize_error`'s `Map.drop` on a struct
  reason left `__struct__` in `:details`, crashing `Jason.encode!`. Fixed upstream
  on `main` in commit `d60699c0` (refactor of `Jido.AI.Error.normalize/4`,
  2026-05-21); not yet released. **When `:jido_ai > 2.1.0` is published and our
  pin is bumped, simplify or delete this test** — its primary motivation will be
  gone. The `Gralkor.GraphitiPool.for/2` `:infinity` timeout (the real Issue A
  root cause) stays regardless; it's unrelated to the encoder fix.
