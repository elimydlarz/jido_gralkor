# jido_gralkor

Canonical development and distribution home for Jido-first Gralkor. Ships the JidoGralkor.* plugin/lifecycle modules plus the embedded Gralkor.* adapter (Pythonx-driven graphiti, capture buffer, distill, interpret, recall); the legacy `:gralkor` and `:gralkor_ex` packages redirect consumers here.

**Test trees live under [`test-trees/`](test-trees/)** — the canonical contract between intent and tests. Functional and Journey trees describe application-visible behaviour; Integration and Unit trees describe the inner subjects revealed through TDD.

## Mental Model

- **Destinations** — `config :jido_gralkor, :destinations` defines first-class names with `operator/path` or `global/path` addresses and an optional ontology. Lenses and Reflections reference Destinations by name; multiple may save to the same Destination. Search names Destinations directly and supports facts, nodes, episodes, and artefacts. See [`DESTINATIONS.md`](DESTINATIONS.md).
- **Lenses** — `config :jido_gralkor, :lenses` defines named ingestion behavior. Appending definitions carry `:name`, `:destination`, and `:ingestion`; replaceable definitions carry `:name`, `:destination`, `write: :replace_graph`, and `:graph_format`. Replacement changes only content carrying that Lens's `_gralkor_lens` marker at the Destination.
- **Reflections** — `config :jido_gralkor, :reflections` declares named asynchronous post-ingestion processes, each referencing a Destination and repository YAML Chain of Thought. `generalisations` and `erl` are packaged defaults; the packaged experiential-learning Destination carries `Gralkor.Reflection.ERLOntology` and its `Learning` entity.
- **Lens-aware plugin flow** — mount with `:ingestion_lens` and optional `:search_destinations`. A query may override the selected ingestion Lens through `tool_context[:lens]`; `memory_add` and automatic capture use that Lens, while `memory_search` searches the selected Destinations.
- **Implicit-operator plugin compatibility** — the plugin detail immediately below describes mounts without `:ingestion_lens`; registered Lens mounts follow the Lens-aware flow above.
- **`JidoGralkor.Plugin`** — owns the `:__memory__` slot, validates `agent_name`, exposes the four memory/admin actions, and never recalls on its own. In implicit-operator mode it plants agent/session context and captures through `/5` using the packaged operator Destination. In Lens mode it also plants Lens/Destination selections and captures through `/6` or `/7`. Both modes canonicalise completed and failed turns; missing user identity and capture failures surface immediately, while either outcome is skipped with a warning when no committed thread supplies session identity.
- **`JidoGralkor.ReAct`** — small helper module for `Jido.AI.Reasoning.ReAct.RequestTransformer` consumers. `maybe_force_memory_search/2` takes a transformer overrides map (whatever the consumer is already returning) plus the ReAct `State` and, on `state.iteration == 1` (the first turn of a ReAct loop), folds `tool_choice: %{type: "function", function: %{name: "memory_search"}}` into the overrides' `:llm_opts`. On subsequent iterations it returns the overrides untouched so the LLM is free to answer or call further tools. Acknowledged workaround: ReAct's `tool_choice` is a single config value applied uniformly across the loop; this helper is the cheapest way to pin it for one iteration without forking the strategy. A first-class `:preamble_tool` config in `Jido.AI.Reasoning.ReAct.Config` would supersede it.
- **`JidoGralkor.Lifecycle`** — pass-through `Jido.AgentServer.Lifecycle` callbacks plus graceful-stop flushing. `terminate/2` reads the committed Jido thread id and starts `Gralkor.Client.flush/1` without blocking termination; a missing thread causes no call, and background failures are logged. Jido's AgentServer owns idle-timeout policy.
- **`JidoGralkor.Canonical`** — the adapter-only module that translates a Jido/ReAct turn into Gralkor's canonical message shape. Takes `user_query` at face value — whatever string was registered with the request is what gets persisted — because the plugin and the rest of the pipeline keep `:query` the user's actual words (no envelope stripping is needed or performed here; harness-injected context is added at prompt-build time in the `RequestTransformer`, not in the query). Filters events that aren't memory-worthy, and renders surviving `:llm_completed` / `:tool_completed` events as `behaviour` messages with content the distillation LLM can read (`"thought: …"`, `"tool NAME → RESULT"`). The turn outcome terminates the message list: `{:completed, answer}` becomes the trailing `"assistant"` message; `{:failed, error}` becomes a terminal `"behaviour"` message `"request failed: …"` so the failure is visible to downstream distillation rather than silently swallowed. Returns `[]` when nothing is worth persisting; the plugin uses that to skip the capture call entirely.
- **`JidoGralkor.Actions.MemorySearch`** — the ReAct search tool. It short-circuits blank queries and missing sessions; Lens-aware mounts call `Gralkor.Client.search/1` with their Destination selection, while implicit-operator mounts use legacy `Gralkor.Client.impl().recall/4`. Errors propagate and successful results identify their Destination.
- **`JidoGralkor.Actions.MemoryAdd`** — the fire-and-forget write tool. Its background task calls `Gralkor.Client.ingest/1` when context selects a Lens and uses legacy `memory_add/3` otherwise; failures are logged and the action immediately returns `"Ingesting."`.

## Dependencies

Six direct runtime Hex deps (seven with `:ex_doc` for dev docs):

- `{:jido, "~> 2.2"}` — `Jido.Plugin`, `Jido.Action`, `Jido.Signal` (struct + pattern match).
- `{:jido_ai, "~> 2.1"}` — `Jido.AI.Request.get_request/2` (used once in the plugin to look up the user query for a completed `request_id`).
- `{:pythonx, "~> 0.4"}` — embeds CPython in the BEAM so the embedded Gralkor pipelines can drive `graphiti-core` directly. `Gralkor.Python.init/1` materialises the venv and initialises the interpreter at boot via `Pythonx.uv_init/2` from `priv/python/pyproject.toml` (the graphiti-core version requirement), read into `@pyproject_toml` at compile time via `@external_resource` — guarded idempotent against re-init. Consumers configure **nothing** about Python; there is no `:pythonx, :uv_init` block in any consumer config (the dep's own `config/config.exs` does not propagate to a consumer's runtime app env, so owning the manifest in the package — shipped via the `priv` entry in `mix.exs` `files:` — is the only way to keep Python an internal concern). The venv lands in PythonX's uv cache (not `priv/`), built at runtime on first boot. The manifest reads `"graphiti-core[falkordb,google-genai]>=0.29.2"` and covers **both** supported inference providers: graphiti-core requires `openai` unconditionally (`Requires-Dist: openai>=1.91.0`, verified against installed 0.29.3 METADATA) and publishes no `openai` extra, so the OpenAI LLM, embedder, and reranker classes import from this manifest as-is; naming a non-existent extra only makes uv warn on every resolve. `Gralkor.Python.init/1` smoke-imports every provider accepted by `Gralkor.GraphitiPool` before reporting ready; `smoke_import_provider_clients/1` is the per-provider boundary it uses.
- `{:req_llm, "~> 1.0"}` — LLM client used by the embedded Distill + Interpret pipelines (provider-portable via `response_model`-bearing Pydantic schemas).
- `{:jason, "~> 1.4"}` — JSON parsing for the embedded pipelines.
- `{:yaml_elixir, "~> 2.12"}` — loads repository CoT declarations. `mix.exs` packages `priv`, including the built-in Reflection YAML files.

**Embedded Gralkor adapter.** `Gralkor.*` contains the compatibility adapter, independent Lens boundary, and Reflection subsystem. Lens capture uses `capture/6`, `/7`, or the internal `/8` context-carrying form, batches by Lens, and flushes through `Client.ingest_with_representation/1`. Completed lensed representations preserve a shared evidence id plus their Lens identity. The CaptureBuffer schedules Reflections asynchronously only after every intended Lens has succeeded. The implicit-operator compatibility path remains `capture/5`, `memory_add/3`, and `recall/4`; it uses library-owned `Gralkor.DefaultOntology` and does not produce Reflection input.

## Configuring Gralkor

`:jido_gralkor` is the integration point for operators who run a Jido agent on top of Gralkor. All operator-facing knobs live under the `:jido_gralkor` application env.

**Destinations and Lenses.** `:destinations` entries use `:name`, `:address`, and optional `:ontology`. `:lenses` entries reference one through `:destination` and add either an `:ingestion` process or replaceable graph settings. `JidoGralkor.Plugin` selects ingestion by `:ingestion_lens` and search by `:search_destinations`.

**Reflections.** `:reflections` is a list of `name:`, `destination:`, and `chain_of_thought:` definitions. Omitting it loads packaged `generalisations` and `erl`; supplying it replaces those defaults. `:reflection_root` defaults to `Application.app_dir(:jido_gralkor)` and resolves relative YAML paths; `:reflection_storage` defaults to `Gralkor.Reflection.Storage.Graphiti`. Invalid names, Destinations, paths, YAML steps, interpolations, or output schemas fail validation before processing.

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

**Recall interpretation is query-aware.** `Gralkor.Recall` hands the recall query to `Gralkor.Interpret.interpret_facts/6`, which renders it as a `Request to answer:` section between the conversation context and the facts. Before that the model judged relevance against the buffered conversation alone, so any recall from a session that never carried the query — a fresh session, or a `memory_search` whose query is not the last thing the user said — filtered against nothing and returned arbitrary facts even though the search had ranked the right ones first. The conversation is still dropped oldest-first to fit the char budget; the request and the facts never are.

**Implicit-default ontology.** Jido Gralkor's packaged operator Destination carries `Gralkor.DefaultOntology`, the open generic extraction contract used by legacy capture, `memory_add/3`, recall, and the implicit `"operator"` Lens. There is no deployment-wide `:ontology` setting and no `memory_add/4` override. Custom schemas belong on registered Destinations.

**Inference providers.** Optional model overrides (`GRALKOR_LLM_MODEL`, `GRALKOR_EMBEDDER_MODEL`) are read straight from `System.get_env/1` by `Gralkor.Config`, which stays provider-agnostic: it preserves the general `%{provider:, id:}` model shape, splits only the first colon, and trims surrounding whitespace from the override and both components. Whitespace-only overrides use the defaults; a component that is blank after trimming raises. `Gralkor.GraphitiPool` owns provider policy through `@supported_providers [:openai, :google]` and `@credential_env %{openai: "OPENAI_API_KEY", google: "GOOGLE_API_KEY"}`, exposed as `supported_providers/0`. Defaults are `google:gemini-3.1-flash-lite` (llm) and `google:gemini-embedding-2-preview` (embedder).

- `validate_native_models!/2` runs before any inference client is constructed. It raises `ArgumentError` when either spec names a provider outside the supported set, naming both specs and the supported providers; and raises when the credential for a provider a spec **selects** is absent or blank, naming the variable and the role (`"llm"` or `"embedder"`). A provider selected by neither role needs no credential, so an all-Google pair needs only `GOOGLE_API_KEY`.
- `shared_client_spec/2` is the pure per-role decision — no Pythonx, no credentials read — so `default_construct_shared_clients/2` has nothing left to decide. The **llm** role's provider builds the LLM client **and the cross-encoder/reranker** (the reranker has no spec of its own); the **embedder** role's provider builds the embedder. GPT-5.5 and GPT-5.6 OpenAI LLM specs carry `reasoning: "none"` explicitly because those families reject graphiti-core 0.29.3's unknown-family `minimal` default; other OpenAI specs retain its `auto` selection. A Google embedder carries `batch_size: 1` (the gemini-embedding-2-preview batching defect, getzep/graphiti#1467); an OpenAI embedder carries no batch size.
- `api_key!/1` reads each provider's credential on the BEAM side and every constructor takes it as an explicit argument (`genai.Client(api_key=…)`, `LLMConfig(api_key=…)`, `OpenAIEmbedderConfig(api_key=…)`). Erlang's `os:putenv` keeps its own table and never reaches the C environment, so a key set from Elixir — a consumer's `runtime.exs`, or `Gralkor.TestEnv.load/1` reading `.env` — is invisible to the embedded interpreter's `os.environ`; letting the Python clients read the variable themselves works only for keys exported into the OS process before boot.
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
mix test.all        # all Unit, Integration, Functional, Journey, and Node tests
```

Functional tests describe application-visible behaviour and may use deterministic substitutes or focused live boundaries. Journey tests are the broad workflow form of Functional coverage. `mix test.all` runs Unit, Integration, Functional, and Journey tests through ExUnit, then runs every Node test; both runners finish and print their normal output when either reports failures. Real LLM and graphiti-core extraction calls remain confined to these opt-in suites; a default `mix test` is deterministic. The boundary contract those tiers used to be the sole proof of — which graphiti `add_episode` kwargs an ontology populates — is now pinned deterministically by [`test-trees/unit/ontology-graphiti-spec_TEST_TREES.md`](test-trees/unit/ontology-graphiti-spec_TEST_TREES.md) (`Gralkor.GraphitiPool.graphiti_boundary_spec/1`, pure, no Pythonx). The functional `ontology-extraction` suite remains the proof that a real LLM honours the declared schema.

`.env.example` pins `GRALKOR_LLM_MODEL=openai:gpt-4.1` and `GRALKOR_EMBEDDER_MODEL=openai:text-embedding-3-small`, so every suite that reaches a real provider runs on `OPENAI_API_KEY` alone; the package defaults remain Google, and `GOOGLE_API_KEY` is needed only when a role is pointed back at Google. The LLM-backed ontology and Jido-memory suites build their `GraphitiPool` child spec from `Gralkor.Config.llm_model/0` and `embedder_model/0` rather than naming a provider, so they follow whatever those variables select. Reflection functional coverage exercises the YAML runner's exact schemas, interpolation, tool loop, scheduling, destinations, and search; a focused live boundary must use the real key loaded from `.env`, never a mock credential.

`gpt-4.1-mini` is too weak for the ontology-extraction assertions — it produced `User` but no `Preference` node from the fixture, failing the strict and open cases every time, which is why `gpt-4.1` is pinned. The suite used to be flaky on `gpt-4.1` as well (1–2 of its 3 tests failing per run) for a reason that turned out not to be plain LLM variance: its entity types carried **no description**, and graphiti's extractor reads a custom entity type's description to decide when to mint it. `Gralkor.Ontology` now accepts `entity Foo, "…" do … end`; with `User` and `Preference` each saying when to extract them, the three tests pass run after run. Whether the assertions were stabler on the Google defaults remains unmeasured.

**A whole-suite `mix test.journey` is meaningful again.** Journey modules used to have to be judged one at a time, because each module's `start_supervised(Gralkor.Python)` SIGKILLed every `redislite/bin/redis-server` it could find — including the live server an earlier module still owned, which then lost its database mid-test on a refused unix socket. The sweep is now once per VM (`Gralkor.Python.sweep_orphans_once/2`): only the first boot runs it, the one moment when every matching server predates this VM. The remaining constraint is across VMs — do not run two test VMs against the embedded backend at the same time, because the sweep still cannot tell another VM's live server from an orphan.

`test/functional/interpret_epistemic_humility_test.exs` is the focused real-model proof for interpretation behaviour. It loads `OPENAI_API_KEY` from `.env`, calls OpenAI `gpt-5.6-sol` through ReqLLM, and covers varied source types, adversarial conflicting accounts, ordinary memories without provenance, and relevance filtering. It starts no Graphiti or FalkorDB runtime, and missing credentials fail fast rather than skip. **The instrument has to be at least as capable as the model a consumer's agent runs on**, or a failure says nothing about the instruction under test: the thing being measured is production English — `Gralkor.Interpret.epistemic_instruction/0` — whose behaviour only a model can reveal. `gpt-4.1-mini` collapsed the adversarial conflicting-accounts case into one asserted fact about one run in four even after the instruction was sharpened, and `gpt-4.1` passed but sits well below what deployments actually use. `gpt-5.6-sol` is a reasoning model, so it drops sampling parameters; the suite passes no temperature and relies on the instruction rather than on decoding settings. A green run still says only that a capable model complies — no other model has been measured, and consumers recall on whatever they configure.

### Mutation testing

**Operator-only:** Coding agents must not run mutation testing unless the operator explicitly initiates it. Do not use mutation testing as routine TDD, verification, sync, or completion work.

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
