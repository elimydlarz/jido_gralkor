# jido_gralkor

Drop-in long-term memory for a [Jido](https://hex.pm/packages/jido) agent. One Hex package: the Jido plugin and ReAct tools on top of an embedded Gralkor memory adapter — Graphiti + FalkorDB driven directly from the BEAM via [Pythonx](https://github.com/livebook-dev/pythonx), no external server to run.

You write your agent's prompt, model, and business tools. `jido_gralkor` covers session identity, recall, capture, the `memory_search` / `memory_add` ReAct tools, a small helper that pins `tool_choice` to `memory_search` on the first ReAct iteration so the agent itself authors its memory queries, a graceful-shutdown flush, a context-rotation primitive for long-running agents, and **Lenses**: named, independently configurable ingestion and search channels, each with its own ontology, scope, and consumer-defined ingestion process.

As of `3.0.0` the former `:gralkor_ex` Hex package is folded into this one. Consumers no longer need a separate `{:gralkor_ex, ...}` line — `{:jido_gralkor, "~> 4.1"}` is the whole memory stack.

## Install

```elixir
def deps do
  [
    {:jido_gralkor, "~> 4.1"}
  ]
end
```

Then fetch:

```bash
mix deps.get
```

This transitively pulls `:jido`, `:jido_ai`, `:pythonx`, `:req_llm`, and `:jason`. Pythonx materialises its venv (with `graphiti-core` + `falkordblite` from PyPI) on first boot — ~3 s the first time, ~21 ms thereafter.

## Required configuration

Three things the consumer must set up.

**1. A FalkorDB backend.** Graphiti runs in-process via Pythonx and connects to FalkorDB either as an embedded `falkordblite` child or over the network. Pick one:

```bash
# Embedded — falkordblite spawns a redis-server grandchild under this dir
export GRALKOR_DATA_DIR=/var/lib/<your-app>/gralkor   # writable
export GOOGLE_API_KEY=...                              # or ANTHROPIC / OPENAI / GROQ
```

```elixir
# Remote — point at a managed FalkorDB. config/runtime.exs
config :jido_gralkor,
  falkordb: [
    host: System.fetch_env!("FALKORDB_HOST"),
    port: String.to_integer(System.fetch_env!("FALKORDB_PORT")),
    username: System.get_env("FALKORDB_USERNAME"),
    password: System.get_env("FALKORDB_PASSWORD"),
    ssl: System.get_env("FALKORDB_SSL") == "true"
  ]
```

Remote wins when both are set. `:ssl` defaults to `false`; set `true` for FalkorDB Cloud or any TLS-fronted endpoint. Misconfigured `:falkordb` (non-keyword, missing host/port, blank host, non-positive port) raises `ArgumentError` at app start.

**2. In-memory client in tests.** Swap the adapter for the in-memory twin:

```elixir
# config/test.exs
config :jido_gralkor, client: Gralkor.Client.InMemory
```

And start the twin once in `test/test_helper.exs`:

```elixir
{:ok, _} = Gralkor.Client.InMemory.start_link()
ExUnit.start()
```

When `:jido_gralkor, :client` is pinned to `Gralkor.Client.InMemory`, the native supervision tree (Pythonx → GraphitiPool → CaptureBuffer) does not start. No FalkorDB backend required in tests.

**3. `Jido.Thread.Plugin` on your `use Jido` supervisor.** The plugin reads `session_id` from `agent.state[:__thread__].id`, so the thread plugin must be active:

```elixir
defmodule MyApp.Jido do
  use Jido, default_plugins: [Jido.Thread.Plugin, Jido.Identity.Plugin]
end
```

`:jido_gralkor` auto-supervises its native runtime (Python → GraphitiPool → CaptureBuffer) when a FalkorDB backend is configured — no separate `Gralkor.Server` to wire into your supervision tree, and no readiness gate to add. By the time `Application.start/2` returns, `Gralkor.Client` is ready.

## Wire it on your agent

```elixir
defmodule MyApp.ChatAgent do
  use Jido.Agent,
    name: "my_chat",
    strategy:
      {Jido.AI.Reasoning.ReAct.Strategy,
       tools: [
         JidoGralkor.Actions.MemorySearch,
         JidoGralkor.Actions.MemoryAdd
         # ... your other tools
       ],
       system_prompt: """
       You are a helpful assistant with long-term memory.

       Use memory_search when answering benefits from past context.
       Use memory_add to record explicit insights you want to preserve
       beyond the conversation that's already being auto-captured.
       """,
       request_transformer: MyApp.ChatAgent.RequestTransformer},
    default_plugins: %{__memory__: false},
    plugins: [
      {JidoGralkor.Plugin,
       %{
         agent_name: "Susu",
         default_lens: "observations",
         search_targets: ["observations", "global"],
         generalise_lens: "generalisations"
       }}
    ]

  # Optional: pin tool_choice to memory_search on iteration 1 so the agent
  # itself authors a focused recall query in-thread.
  defmodule RequestTransformer do
    @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

    @impl true
    def transform_request(_messages, overrides, _runtime_context, state) do
      JidoGralkor.ReAct.maybe_force_memory_search(overrides, state)
    end
  end
end
```

The plugin claims Jido's `:__memory__` slot. On `ai.react.query`, it plants `:session_id` (when a thread is committed), `:agent_name`, the selected `:lens`, and `:search_targets` on the signal's `tool_context`. Recall itself is the LLM's job — `JidoGralkor.ReAct.maybe_force_memory_search/2` is the cheapest way to force it on iteration 1. Capture runs automatically on completion and failure: the ReAct event trace is normalised into Gralkor's canonical `[%Gralkor.Message{role, content}]` shape via `JidoGralkor.Canonical` — `user` for the user query, `behaviour` for intermediate thinking / tool calls / tool results, `assistant` for the final answer on completed turns, or a terminal `"request failed: …"` `behaviour` on failed turns so the failure stays visible to downstream distillation.

Set `tool_context[:lens]` on an individual query to override `default_lens` for that turn. The override becomes authoritative for both `memory_add` and automatic capture. If `generalise_lens` is configured, the same completed turn is also submitted to that Lens without duplicating it in session context.

The plugin reads `user_name` per-turn from `agent.state[:user_name]` — your consumer's responsibility to populate (e.g. via `on_before_cmd` from the signal's `tool_context`) so distill renders user lines under the human's actual name rather than a generic "User".

## What happens at runtime

**Session identity.** `session_id` is the current Jido thread id (read from `agent.state[:__thread__].id`, populated by `Jido.Thread.Plugin`). The plugin does not mint its own identifier — Jido's thread lifecycle is the single source of truth.

**Lens partitioning.** An operator-scoped Lens writes to a partition derived from the operator id and Lens name, so different operators and different local Lenses remain isolated. Every global Lens writes to the one shared `global` partition. Global writes retain their originating Lens name as provenance, but global search deliberately queries the whole pool: use the reserved `"global"` search target, not the name of a global Lens.

**First-turn bootstrap.** On the very first query of a fresh agent, the thread isn't yet committed (the ReAct strategy's `ThreadAgent.append` runs after the plugin hook). The plugin plants only `:agent_name` (no `:session_id`) and lets capture establish the session when the turn completes. `memory_search` called in that same first turn short-circuits with an explicit "did not run" non-result so the LLM cannot read an empty payload as "no memory exists" and confidently lie.

**Death-triggered flush.** `JidoGralkor.Lifecycle` is an optional `Jido.AgentServer.Lifecycle` implementation. When wired as `lifecycle_mod:` on the agent, graceful termination of the AgentServer fires `Gralkor.Client.flush/1` for the active thread so an orphaned agent doesn't strand its capture buffer. No idle-timer machinery — Jido's `AgentServer` owns `:idle_timeout` directly.

**Context rotation.** `JidoGralkor.ContextRotator.rotate_now/2` synchronously flushes the active session via `flush_and_await/2`, installs a fresh Jido thread, and seeds the rotated thread with the most-recent `:keep_last_n` pre-flush entries plus any turns that landed during the flush. The agent process is never stopped. Use it from a `/new` chat command or a small wrapper GenServer that fires on an interval.

**Fail-fast.** Gralkor errors raise. Your supervision tree decides how to react.

**`memory_add` is async.** The tool returns `"Ingesting."` immediately and does the storage call in a background `Task`. Graphiti's entity/edge extraction can take tens of seconds; you don't want the agent waiting. Failures are logged; best-effort storage is the contract.

## Declaring a custom ontology

By default jido_gralkor passes no ontology to graphiti — it extracts generic entities and edges. To shape extraction against your domain, declare a `Gralkor.Ontology` module and set it as a deployment-wide config value.

```elixir
defmodule MyApp.Ontology do
  use Gralkor.Ontology, entities: :strict, relationships: :scoped

  entity User do
    field :handle,   :string, required: true, doc: "stable login handle"
    field :timezone, :string,                  doc: "IANA tz"
  end

  entity Preference do
    field :description, :string, required: true
  end

  from User do
    prefers Preference do
      field :since, :string, doc: "date first observed"
    end

    trusts User
  end
end
```

- `entity Foo do field … end` declares an entity. `field :name, :type, opts` supports `:string | :integer | :float | :boolean`, plus `required: true` and `doc:` (rendered as the Pydantic field description).
- `from Source do verb Target [do field … end] end` declares outgoing relationships from `Source`. The verb's name becomes the edge type in graphiti (`prefers` → `"PREFERS"`, `relates_to` → `"RELATES_TO"`). The optional `do` block carries edge properties.
- Same verb in multiple `from` blocks becomes one edge type with multiple endpoint pairs.
- `entities: :strict` excludes graphiti's generic `Entity` extraction — only your declared types survive. `entities: :open` lets graphiti extract generic Entity nodes alongside yours.
- `relationships: :scoped` populates graphiti's `edge_type_map` from your declared `(src, dst)` pairs, so named edges only fire between declared endpoints. `relationships: :open` drops the map; graphiti's default applies. Either way, graphiti always extracts edge candidates — generic fall-through edges between unconstrained pairs are not closed off.
- Both opts are required at `use` — no defaults; pick deliberately.

Configure it once for the deployment:

```elixir
# config/runtime.exs
config :jido_gralkor, ontology: MyApp.Ontology
```

That's it — the plugin mount stays `%{agent_name: "Susu"}`, with no ontology threaded through it. `Gralkor.Client` resolves the configured ontology on **every** write — capture flushes plus the `memory_add` ReAct tool — so all ingestion shares one schema. graphiti receives `entity_types`, `edge_types`, `edge_type_map`, and `excluded_entity_types` translated from the module's compile-time payload (built once per ontology module, cached by name). A programmatic caller that needs a different ontology for a single add can pass it as the 4th argument to `Gralkor.Client.memory_add/4`.

## Generalisation

`Gralkor.Generalise` hypothesises cross-episode patterns from a flushed transcript, reconciles them against what it already knows, and persists the survivors. Generalisations are stored in a separate graphiti partition (`"#{group_id}_gen"`) and surfaced alongside regular facts during recall with a `<generalisation>` prefix so the interpret LLM can treat them as higher-level patterns. The capability is always available — call `Gralkor.Client.generalise/2` directly, search it with `Gralkor.Client.search_generalisations/3`, and it is injected into recall automatically.

### Optional: run generalisation automatically on flush

Off by default. Set `:generalise_on_flush` to `true` to have a successful capture flush fire generalisation fire-and-forget (it never blocks the turn; failures are logged, not raised):

```elixir
# config/runtime.exs
config :jido_gralkor, generalise_on_flush: true
```

When `false` or unset, no generalisation runs on flush — you drive it yourself via `Gralkor.Client.generalise/2`.

### Optional: confidence threshold

Generalise persists the strongest hypotheses above a configurable confidence threshold (default `0.3`). Raise it to be more conservative, lower to capture more:

```elixir
# config/runtime.exs
config :jido_gralkor, generalise_min_confidence: 0.5
```

### Custom ontologies

When a deployment-wide ontology is configured (`config :jido_gralkor, ontology: MyApp.Ontology`), generalisation writes are extracted under that same ontology — generalisations are typed consistently with captured memory. With no ontology configured, generalisations are written untyped, as before.

## Experiential learning (ERL) recall

Every captured turn is distilled into a flat `Gralkor.AgentLearning` record (`problem_kind`, `approach`, `success`, `lesson`) and written to the same `group_id` as the conversation — unconditionally at flush, via `add_episode` with the plugin's built-in `Learning` graphiti custom entity type (`Gralkor.LearningEntity`) merged onto the write's `entity_types`. graphiti's extractor then creates a `Learning`-labelled **node** carrying those attributes, and connects it to the domain entities it extracts from the same text. This works even with no consumer ontology configured. (For graphiti to mint the node, the `Learning` entity type declares a class description and optional attributes, per graphiti's custom-entity docs.)

### Unconditional learning search on every recall

There is no opt-in flag. Every recall runs a parallel learning search alongside the main search, seeded with the raw user query and scoped to only `Learning` nodes via a graphiti **node search** (`Gralkor.GraphitiPool.search_nodes/5` → `g.search_` with `SearchFilters(node_labels: ["Learning"])`) — so the interpreter surfaces the learnings that came from the same kind of problem, biased toward approaches that succeeded (the bias lives in the learning node's summary/attributes, not a query primitive). Node search, not edge search: a `Learning` is a custom-entity node, and edge search's node-label filter matches edges by endpoint and would miss it. The learning search shares a 5s yield deadline with the generalisation search and degrades to the regular facts if it fails or times out. No LLM classification, no `TaskKind`: the previous `:erl_recall` opt-in flag and its query classifier have been removed — the unconditional path is what ERL now means.

## Testing against the in-memory twin

`Gralkor.Client.InMemory` is a real implementation of `Gralkor.Client` (not a mock) that stores canned responses and records every call. Your agent's integration tests can hit it without any network:

```elixir
setup do
  Gralkor.Client.InMemory.reset()
  :ok
end

test "agent recalls stored context" do
  Gralkor.Client.InMemory.configure_recall({:ok, "<gralkor-memory>known fact</gralkor-memory>"})
  Gralkor.Client.InMemory.configure_capture(:ok)
  # ... exercise your agent, assert on responses, inspect recorded calls
end
```

The same `Gralkor.ClientContract` macro suite is run against both the in-memory twin and the production `Gralkor.Client.Native` adapter, so both satisfy an identical contract.

Maintainers can exercise the interpretation prompt against a real low-cost model with `mix test.functional test/functional/interpret_epistemic_humility_test.exs`. The suite loads `OPENAI_API_KEY` from `.env`, uses OpenAI `gpt-4.1-mini` through ReqLLM at temperature `0.0`, and starts no Graphiti or FalkorDB runtime. It verifies source preservation across varied accounts, conflict handling without truth adjudication, restraint when provenance is absent, and relevance filtering.

## What's in the library

The Jido glue:

- `JidoGralkor.Plugin` — `use Jido.Plugin, state_key: :__memory__, singleton: true`. Handles `ai.react.query` (planting session+agent on tool_context) and `ai.request.completed` / `ai.request.failed` (capture).
- `JidoGralkor.ReAct` — `maybe_force_memory_search/2` helper. Folds `tool_choice: %{type: "function", function: %{name: "memory_search"}}` into ReAct overrides on iteration 1; passes through unchanged on iterations 2+.
- `JidoGralkor.Canonical` — normalises a Jido/ReAct turn into the canonical `[%Gralkor.Message{role, content}]` shape.
- `JidoGralkor.Lifecycle` — `Jido.AgentServer.Lifecycle` impl whose sole job is the death-triggered flush.
- `JidoGralkor.ContextRotator` — synchronous `rotate_now/2` for in-life context consolidation.
- `JidoGralkor.Actions.MemorySearch` — the ReAct tool that calls `Gralkor.Client.recall/4`. Short-circuits when no thread is committed or the query is blank.
- `JidoGralkor.Actions.MemoryAdd` — fire-and-forget ReAct tool.
- `JidoGralkor.Actions.MemoryBuildIndices` — admin tool. Description tells the LLM `DO NOT CALL` unless the user asked. Whole-graph index rebuild.
- `JidoGralkor.Actions.MemoryBuildCommunities` — admin tool. Same `DO NOT CALL` guard. Runs Graphiti community detection on this agent's partition.

The embedded Gralkor adapter (under `lib/gralkor/`):

- `Gralkor.Client` — behaviour, `sanitize_group_id/1`, `impl/0` app-env resolver.
- `Gralkor.Client.Native` — production adapter; wires `Recall`, `CaptureBuffer`, `GraphitiPool`, `Generalise`, and `req_llm`.
- `Gralkor.Client.InMemory` — test twin.
- `Gralkor.Ontology` — compile-time DSL for declaring graphiti custom-entity ontologies (`entity`/`field`/`from`/verb macros).
- `Gralkor.Generalise` — hypothesise → evaluate → persist pipeline. On flush, reviews the distilled transcript, hypothesises cross-episode patterns via LLM, searches existing generalisations in a separate `:gen` graphiti partition to rule candidates in or out, and saves the strongest. Generalisations form a hierarchy (broadens / narrows) with deduplication.
- `Gralkor.Generalisation` — struct and wire format (`GEN|v1|{json}\ncontent`) for storing generalisations as graphiti episodes with controlled UUIDs (enabling update via re-extraction and delete via `remove_episode`).
- `Gralkor.Application`, `Gralkor.Python`, `Gralkor.GraphitiPool`, `Gralkor.CaptureBuffer`, `Gralkor.Recall`, `Gralkor.Distill`, `Gralkor.Interpret`, `Gralkor.Format`, `Gralkor.Config`, `Gralkor.Message`, `Gralkor.InterpretParseFailed`, `Gralkor.GeneralisationParseFailed` — the embedded pipelines (capture buffer, distill, interpret, recall, generalise) that drive Graphiti.

Detailed behaviour for every module lives in [`CLAUDE.md`](https://github.com/elimydlarz/jido_gralkor/blob/main/CLAUDE.md) under `## Test Trees`.

## Publishing (maintainers)

`:jido_gralkor` is published to the public Hex registry, owned by the `gralkor` Hex organization. Future releases use a `gralkor`-scoped org key (`GRALKOR_HEX_TOKEN`) loaded from the workspace `.env`; see the workspace `publish` skill for the full release flow.

```bash
./scripts/publish.sh patch   # or minor | major | current
```

Bumps `@version` in `mix.exs`, runs `mix hex.publish --yes`, commits the bump, and tags `jido-gralkor-v<version>` locally. The tag is **lightweight**, so `git push --follow-tags` will *not* push it (that only pushes annotated tags) — push the release tag explicitly:

```bash
git push                                 # the version-bump commit
git push origin jido-gralkor-v<version>  # the release tag
```

## License

MIT.
