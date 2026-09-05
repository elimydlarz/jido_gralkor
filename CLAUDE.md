# jido_gralkor

Canonical development and distribution home for Jido-first Gralkor. Ships the JidoGralkor.* plugin/lifecycle modules plus the embedded Gralkor.* adapter (Pythonx-driven graphiti, capture buffer, distill, recall); the legacy `:gralkor` and `:gralkor_ex` packages redirect consumers here.

**Test trees live under [`test-trees/`](test-trees/)** — the canonical contract between intent and tests. Functional and Journey trees describe application-visible behaviour; Integration and Unit trees describe the inner subjects revealed through TDD.

## Mental Model

- **Destinations** — each Destination resolves to one logical graph ID. `global` is shared, `operator` resolves to `operator/<agent.id>`, and an application Destination resolves to its exact name; application names under the reserved `operator/` namespace are rejected. Graphiti encodes that logical ID exactly once as `g_` plus lowercase hexadecimal bytes. Definitions contain only `:name`; Lenses and Reflection Destination outputs reference Destinations and select the ontology for their writes. Search defaults to episodes across every accessible registered Destination, accepts optional per-call Destination and Lens selectors, and retains explicit facts, nodes, and artefacts as advanced result types. See [`DESTINATIONS.md`](DESTINATIONS.md).
- **Runtime configuration** — every `JidoGralkor.Plugin` mount supplies a complete `:runtime_config` containing consumer Destinations, Lenses, and inline Reflections. Its linked `JidoGralkor.Runtime` owns one atomic snapshot beneath that `Jido.AgentServer`; package-owned definitions are always present. Runtime-targeted APIs accept the owning AgentServer PID, never fall back to application registries, and resolve all selectors for one search from one snapshot. Replacements target one agent, and consumer supervision recreates failed agents from the consumer's durable configuration.
- **Lenses** — appending runtime definitions carry `:name`, `:destination`, `write: :append`, and `:ingestion`, with optional `:ontology`; replaceable definitions carry only `:name`, `:destination`, and `write: :replace_graph`. `%Gralkor.Graph{nodes:, relationships:}` is the sole replacement representation. Replacement changes only content carrying that Lens's `_gralkor_lens` marker at the Destination. Lens and Reflection names containing the episode-provenance delimiter `" [lens: "` are rejected.
- **Reflections** — runtime configuration declares named synthesis processes with an inline structured Chain of Thought and exactly one Destination output. `Gralkor.Client.reflect/5` admits work through the consuming agent and immediately returns the invocation ID; the agent runtime independently produces and delivers the artefact, retries 5xx failures exponentially for up to twenty-four hours, abandons 4xx failures immediately, and invokes the per-submission callback with the terminal outcome. `%Gralkor.Artefact{}` contains exactly `id` and `payload`; `generalisations` and `erl` are always-installed packaged definitions.
- **Lens-aware plugin flow** — mount with `:ingestion_lens`. A query may override the selected ingestion Lens through `tool_context[:lens]`; `memory_add` and automatic capture use that Lens. Each `memory_search` invocation independently supplies optional `destinations` and `lenses` selectors; the removed mount option `:search_destinations` raises with migration guidance.
- **Implicit-operator plugin compatibility** — the plugin detail immediately below describes mounts without `:ingestion_lens`; registered Lens mounts follow the Lens-aware flow above.
- **`JidoGralkor.Plugin`** — owns the `:__memory__` slot, validates `agent_name` and the complete runtime configuration, starts the linked runtime child, exposes the four memory/admin actions, and never recalls on its own. In implicit-operator mode it plants agent/session/runtime context and captures through `/5` using the packaged operator Destination. In Lens mode it also plants the ingestion Lens and captures through the runtime-targeted boundary. Both modes canonicalise completed and failed turns; missing user identity and capture failures surface immediately, while either outcome is skipped with a warning when no committed thread supplies session identity.
- **`JidoGralkor.ReAct`** — small helper module for `Jido.AI.Reasoning.ReAct.RequestTransformer` consumers. `maybe_force_memory_search/2` takes a transformer overrides map (whatever the consumer is already returning) plus the ReAct `State` and, on `state.iteration == 1` (the first turn of a ReAct loop), folds `tool_choice: %{type: "function", function: %{name: "memory_search"}}` into the overrides' `:llm_opts`. On subsequent iterations it returns the overrides untouched so the LLM is free to answer or call further tools. Acknowledged workaround: ReAct's `tool_choice` is a single config value applied uniformly across the loop; this helper is the cheapest way to pin it for one iteration without forking the strategy. A first-class `:preamble_tool` config in `Jido.AI.Reasoning.ReAct.Config` would supersede it.
- **`JidoGralkor.Lifecycle`** — pass-through `Jido.AgentServer.Lifecycle` callbacks plus graceful-stop flushing. `terminate/2` reads the committed Jido thread id and schedules `Gralkor.Client.flush/1` before returning; Lens resolution finishes before the ingestion worker starts, while termination does not await ingestion. A missing thread causes no call, and flush failures are logged. Jido's AgentServer owns idle-timeout policy.
- **`JidoGralkor.Canonical`** — the adapter-only module that translates a Jido/ReAct turn into Gralkor's canonical message shape. Takes `user_query` at face value — whatever string was registered with the request is what gets persisted — because the plugin and the rest of the pipeline keep `:query` the user's actual words (no envelope stripping is needed or performed here; harness-injected context is added at prompt-build time in the `RequestTransformer`, not in the query). Filters events that aren't memory-worthy, and renders surviving `:llm_completed` / `:tool_completed` events as `behaviour` messages with content the distillation LLM can read (`"thought: …"`, `"tool NAME → RESULT"`). The turn outcome terminates the message list: `{:completed, answer}` becomes the trailing `"assistant"` message; `{:failed, error}` becomes a terminal `"behaviour"` message `"request failed: …"` so the failure is visible to downstream distillation rather than silently swallowed. Returns `[]` when nothing is worth persisting; the plugin uses that to skip the capture call entirely.
- **`JidoGralkor.Actions.MemorySearch`** — the sole ReAct search path. It short-circuits only blank queries and otherwise calls the runtime-targeted `Gralkor.Client.search/2` for the current operator, including before a conversation thread is committed. Optional per-call `destinations` and `lenses` select by OR within each list and intersection across lists; successful episode results identify their Destination and originating Lens or declaring Reflection, and errors propagate unchanged.
- **`JidoGralkor.Actions.MemoryAdd`** — the fire-and-forget write tool. Its background task calls the runtime-targeted `Gralkor.Client.ingest/2` when context selects a Lens and uses `memory_add/3` against the graph `operator/<agent.id>` otherwise; failures are logged and the action immediately returns `"Ingesting."`.

## Dependencies

Four direct runtime Hex deps (five with `:ex_doc` for dev docs, six with the test-only `:muzak` dependency):

- `{:jido, "~> 2.2"}` — `Jido.Plugin`, `Jido.Action`, `Jido.Signal` (struct + pattern match).
- `{:jido_ai, "~> 2.3"}` — `Jido.AI.Request.get_request/2` (used once in the plugin to look up the user query for a completed `request_id`).
- `{:pythonx, "~> 0.4"}` — embeds CPython in the BEAM so the embedded Gralkor pipelines can drive `graphiti-core` directly. `Gralkor.Python.init/1` materialises the venv and initialises the interpreter at boot via `Pythonx.uv_init/2` from `priv/python/pyproject.toml`, read into `@pyproject_toml` at compile time via `@external_resource` — guarded idempotent against re-init. Consumers configure **nothing** about Python; there is no `:pythonx, :uv_init` block in any consumer config. The venv lands in PythonX's uv cache (not `priv/`), built at runtime on first boot. The manifest pins `"graphiti-core[falkordb,google-genai]==0.29.3"` while the embedded boundary guards that release's empty-edge-candidate duplicate search; graphiti-core requires `openai` unconditionally and publishes no `openai` extra, so both supported provider stacks import from this manifest as-is. `Gralkor.Python.init/1` smoke-imports every provider accepted by `Gralkor.GraphitiPool` before reporting ready.
- `{:jason, "~> 1.4"}` — JSON parsing for the embedded pipelines.

**Embedded Gralkor adapter.** `Gralkor.*` contains the compatibility adapter, independent Lens boundary, and Reflection subsystem. Lens capture uses `capture/6` or `/7`, validates a non-blank operator before buffering, batches by Lens, and flushes through `Client.ingest_with_representation/1`. Every completed lensed representation has exactly its own `id`, `lens`, `content`, and `result`, under one cryptographically collision-resistant ingestion ID minted per buffered ingestion and retained across its flush retries; direct ingestion validates a non-blank operator ID and caller-supplied replay-stable ingestion ID before Lens storage. Lens ingestion and capture complete independently of Reflections. The implicit-operator compatibility path remains `capture/5`, `memory_add/3`, and `recall/4`; current writes carry trusted `operator` Lens provenance as a ` [lens: operator]` source-description suffix. `_gralkor_lens` is replacement ownership, not episode provenance.

## Configuring Gralkor

`:jido_gralkor` application configuration owns deployment concerns such as FalkorDB, inference providers, and adapters. Each consuming agent's JidoGralkor plugin mount owns domain configuration through one complete `:runtime_config` map.

**Destinations and Lenses.** `runtime_config.destinations` entries use only `:name`. Most shared application memory should use the packaged `global` Destination; another permitted name creates another logical graph, while `operator/` remains reserved. `runtime_config.lenses` entries reference a Destination and declare either `write: :append`, an ingestion process, and optional ontology, or `write: :replace_graph`. `JidoGralkor.Plugin` selects ingestion by `:ingestion_lens`; each MemorySearch call selects retrieval independently through optional `destinations` and `lenses`.

**Reflections.** `runtime_config.reflections` definitions contain `:name`, one inline structured `:chain_of_thought`, and exactly one Destination output whose optional ontology defaults to `Gralkor.DefaultOntology`. Packaged `generalisations` and `erl` remain installed alongside consumer definitions. A consumer calls `Gralkor.Client.reflect/5` with its AgentServer, name, invocation, one-argument callback, and inference/tool options; admission returns the invocation ID without waiting. The runtime owns production, Destination delivery, retry, abandonment, and terminal callback. Destination identity and ontology come from the declaring Reflection's output rather than the producer-independent artefact.

Before packaged generalisation inference, one default episode search through the targeted agent runtime reads every accessible registered Destination using all current representation content. The same search supplies related Lens-authored observations and prior Reflection-authored generalisations separately from the current representations. The packaged prompt directs a no-lineage generalisation to level 1 and an evolved generalisation to one level above its highest lineage snapshot. The structured output contract validates lineage types and shape; Gralkor preserves model-produced lineage without independently comparing it with related memory. When a consumer supplies tools and tool context, tool execution augments that context with the invocation's `operator_id`.

Pick **one** of the two backends:

**Embedded FalkorDB (development / local).** Set `GRALKOR_DATA_DIR` to a directory the BEAM can write to. The adapter constructs an in-process `falkordblite` instance, which spawns a `redis-server` grandchild under that directory. `GraphitiPool` admits one embedded `add_episode` at a time through the shared connection while searches bypass admission; remote writes remain concurrent except that deterministic UUID writes serialize through graph-backed renewable claims across runtimes. `:embedded_falkordb_socket_timeout_ms` defaults to `60_000`, is validated as a positive integer at embedded startup, and reaches `AsyncFalkorDB` as seconds. The embedded add boundary also suppresses graphiti-core 0.29.3's vector/full-text duplicate search when its edge UUID candidate list is empty.

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

**Recall presentation is model-free.** `Gralkor.Recall` wraps every fact returned by graph search verbatim and in order inside an untrusted memory block, retaining available source wording. It does not load buffered turns, filter or rewrite results, or make a second inference call; the consuming agent interprets the memory with its own model and conversation context.

**Implicit-default ontology.** Jido Gralkor's packaged `operator` Lens carries `Gralkor.DefaultOntology`, the open generic extraction contract used by implicit capture and explicit memory addition. There is no deployment-wide `:ontology` setting and no `memory_add/4` override. Custom schemas belong on appending Lenses and Reflections; Destinations remain schema-free graph identities.

**Inference providers.** Optional model overrides (`GRALKOR_LLM_MODEL`, `GRALKOR_EMBEDDER_MODEL`) are read straight from `System.get_env/1` by `Gralkor.Config`, which stays provider-agnostic: it preserves the general `%{provider:, id:}` model shape, splits only the first colon, and trims surrounding whitespace from the override and both components. Whitespace-only overrides use the defaults; a component that is blank after trimming raises. `Gralkor.GraphitiPool` owns provider policy through `@supported_providers [:openai, :google]` and `@credential_env %{openai: "OPENAI_API_KEY", google: "GOOGLE_API_KEY"}`, exposed as `supported_providers/0`. Defaults are `google:gemini-3.1-flash-lite` (llm) and `google:gemini-embedding-2-preview` (embedder).

- `validate_native_models!/2` runs before any inference client is constructed. It raises `ArgumentError` when either spec names a provider outside the supported set, naming both specs and the supported providers; and raises when the credential for a provider a spec **selects** is absent or blank, naming the variable and the role (`"llm"` or `"embedder"`). A provider selected by neither role needs no credential, so an all-Google pair needs only `GOOGLE_API_KEY`.
- `shared_client_spec/2` is the pure per-role decision — no Pythonx, no credentials read — so `default_construct_shared_clients/2` has nothing left to decide. The **llm** role's provider builds the LLM client **and the cross-encoder/reranker** (the reranker has no spec of its own); the **embedder** role's provider builds the embedder. GPT-5.5 and GPT-5.6 OpenAI LLM specs carry `reasoning: "none"` explicitly because those families reject graphiti-core 0.29.3's unknown-family `minimal` default; other OpenAI specs retain its `auto` selection. A Google embedder carries `batch_size: 1` (the gemini-embedding-2-preview batching defect, getzep/graphiti#1467); an OpenAI embedder carries no batch size.
- `api_key!/1` reads each provider's credential on the BEAM side and every constructor takes it as an explicit argument (`genai.Client(api_key=…)`, `LLMConfig(api_key=…)`, `OpenAIEmbedderConfig(api_key=…)`). Erlang's `os:putenv` keeps its own table and never reaches the C environment, so a key set from Elixir — a consumer's `runtime.exs`, or `Gralkor.TestEnv.load/1` reading `.env` — is invisible to the embedded interpreter's `os.environ`; letting the Python clients read the variable themselves works only for keys exported into the OS process before boot.
- `default_construct_shared_clients/2` dispatches on that spec to `GeminiClient`/`GeminiEmbedder`/`GeminiRerankerClient` or `OpenAIClient`/`OpenAIEmbedder`/`OpenAIRerankerClient` per role. Mixing roles is supported: an OpenAI LLM with a Google embedder builds an OpenAI LLM, an OpenAI reranker, and a Google embedder, and needs both `OPENAI_API_KEY` and `GOOGLE_API_KEY`. Nothing checks cross-provider embedding-dimension compatibility — there is no such check.
- A deployment that never opted into the native runtime (neither `:falkordb` nor `GRALKOR_DATA_DIR`, or `Gralkor.Client.InMemory` pinned) starts no pool, so no provider validation happens at all.

Deterministic Lens tests pin both `client: Gralkor.Client.InMemory` and `lens_storage: Gralkor.Lens.Storage.InMemory`.

## Testing

Legacy tests use `Gralkor.Client.InMemory` and reset it per scenario. Lens tests additionally configure `lens_storage: Gralkor.Lens.Storage.InMemory` and start a fresh storage process per test; pinning only the client does not intercept `Client.ingest/1` or `search/1`.

Any test that starts a `Gralkor.GraphitiPool` needs a credential present for each provider its model specs select, because `validate_native_models!/2` refuses to start without one — even when client construction is stubbed and no provider is called. `Gralkor.TestEnv.load/1` therefore sets an obvious placeholder for `GOOGLE_API_KEY` and `OPENAI_API_KEY` when the variable is genuinely absent, after loading `.env`; a real configured key always wins.

```bash
mix test            # default run: unit + integration, excluding :functional and :journey — no real LLM/graphiti calls
mix test.unit       # Unit/default tests (excludes integration, functional, journey)
mix test.integration
mix test.functional # application-visible feature behaviour; some suites use real LLM/graphiti boundaries
mix test.journey    # broad whole-application Functional workflows; some require external services
mix test.changed    # changed or related Unit, Integration, and Functional tests; excludes Journey
mix test.fast       # changed or related Unit and Integration tests; excludes Functional and Journey
mix test.all        # all Unit, Integration, Functional, Journey, and Node tests
```

Do not manually run Unit or Integration tests during ordinary development; saved-file feedback owns impacted ExUnit tests plus the Node contract tests, and Stop owns their complete suites. Do not manually run `mix test.fast`, `mix test`, `node --test`, or `mix test.all` during ordinary development. Run only the current focused Functional test during Functional RED and GREEN. Run `mix test.functional` when implementation appears finished. Run `mix test.journey` after a Journey tree or test change or a substantive production change.

Functional tests describe application-visible behaviour and may use deterministic substitutes or focused live boundaries. Journey tests are the broad workflow form of Functional coverage. `mix test.all` runs Unit, Integration, Functional, and Journey tests through ExUnit, then runs every Node test; both runners finish and print their normal output when either reports failures. Real LLM and graphiti-core extraction calls remain confined to these opt-in suites; a default `mix test` is deterministic. The boundary contract those tiers used to be the sole proof of — which graphiti `add_episode` kwargs an ontology populates — is now pinned deterministically by [`test-trees/unit/ontology-graphiti-spec_TEST_TREES.md`](test-trees/unit/ontology-graphiti-spec_TEST_TREES.md) (`Gralkor.GraphitiPool.graphiti_boundary_spec/1`, pure, no Pythonx). The functional `ontology-extraction` suite remains the proof that a real LLM honours the declared schema. Reflection Functional coverage uses inline structured definitions and deterministic inference substitutes.

`.env.example` pins `GRALKOR_LLM_MODEL=openai:gpt-4.1` and `GRALKOR_EMBEDDER_MODEL=openai:text-embedding-3-small`, so every suite that reaches a real provider runs on `OPENAI_API_KEY` alone; the package defaults remain Google, and `GOOGLE_API_KEY` is needed only when a role is pointed back at Google. The LLM-backed ontology and Jido-memory suites build their `GraphitiPool` child spec from `Gralkor.Config.llm_model/0` and `embedder_model/0` rather than naming a provider, so they follow whatever those variables select. Reflection Functional coverage is deterministic and exercises inline schemas, interpolation, the tool loop, asynchronous consumer invocation, Destinations, and search without an external inference call.

`gpt-4.1-mini` is too weak for the ontology-extraction assertions — it produced `User` but no `Preference` node from the fixture, failing the strict and open cases every time, which is why `gpt-4.1` is pinned. The suite used to be flaky on `gpt-4.1` as well (1–2 of its 3 tests failing per run) for a reason that turned out not to be plain LLM variance: its entity types carried **no description**, and graphiti's extractor reads a custom entity type's description to decide when to mint it. `Gralkor.Ontology` now accepts `entity Foo, "…" do … end`; with `User` and `Preference` each saying when to extract them, the three tests pass run after run. Whether the assertions were stabler on the Google defaults remains unmeasured.

**A whole-suite `mix test.journey` is meaningful again.** Journey modules used to have to be judged one at a time, because each module's `start_supervised(Gralkor.Python)` SIGKILLed every `redislite/bin/redis-server` it could find — including the live server an earlier module still owned, which then lost its database mid-test on a refused unix socket. The sweep is now once per VM (`Gralkor.Python.sweep_orphans_once/2`): only the first boot runs it, the one moment when every matching server predates this VM. The remaining constraint is across VMs — do not run two test VMs against the embedded backend at the same time, because the sweep still cannot tell another VM's live server from an orphan.

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
