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
export GOOGLE_API_KEY=...
```

Native Graphiti currently supports Google for both its LLM and embedder. The
defaults are `google:gemini-3.1-flash-lite` and
`google:gemini-embedding-2-preview`; optional `GRALKOR_LLM_MODEL` and
`GRALKOR_EMBEDDER_MODEL` overrides must therefore also use the `google:`
provider prefix. Startup fails before constructing Python clients when either
override names another provider. Direct ReqLLM calls may still use an explicit
non-Google model—for example, the focused interpretation functional suite uses
OpenAI without starting Graphiti.

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
config :jido_gralkor,
  client: Gralkor.Client.InMemory,
  lens_storage: Gralkor.Lens.Storage.InMemory
```

Start the legacy client twin once in `test/test_helper.exs`:

```elixir
{:ok, _} = Gralkor.Client.InMemory.start_link()
ExUnit.start()
```

Lens tests should also start a fresh storage process in setup so state is isolated:

```elixir
setup do
  start_supervised!(Gralkor.Lens.Storage.InMemory)
  :ok
end
```

When the client and Lens storage use these in-memory adapters, the native supervision tree (Pythonx → GraphitiPool → CaptureBuffer) does not start and Lens calls do not reach Graphiti. No FalkorDB backend is required.

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

**Lens partitioning.** An operator-scoped Lens writes to a partition derived from the operator id and Lens name, so different operators and different local Lenses remain isolated. Every global Lens writes to the one shared `global` partition. The Lens store records a global episode's originating Lens in the source description supplied with the same Graphiti `add_episode` call; it does not mutate the graph afterward. Global search deliberately queries the whole pool: use the reserved `"global"` search target, not the name of a global Lens.

**First-turn bootstrap.** On the very first query of a fresh agent, the thread isn't yet committed (the ReAct strategy's `ThreadAgent.append` runs after the plugin hook). The plugin plants `:agent_name` plus configured `:lens` and `:search_targets`, but no `:session_id`; completed and failed turn capture are both skipped with a warning until a committed thread supplies that identity. `memory_search` called in that same first turn short-circuits with an explicit "did not run" non-result so the LLM cannot read an empty payload as "no memory exists" and confidently lie.

**Death-triggered flush.** `JidoGralkor.Lifecycle` is an optional `Jido.AgentServer.Lifecycle` implementation. When wired as `lifecycle_mod:` on the agent, graceful termination of the AgentServer fires `Gralkor.Client.flush/1` for the active thread so an orphaned agent doesn't strand its capture buffer. No idle-timer machinery — Jido's `AgentServer` owns `:idle_timeout` directly.

**Context rotation.** `JidoGralkor.ContextRotator.rotate_now/2` synchronously flushes the active session via `flush_and_await/2`, installs a fresh Jido thread, and seeds the rotated thread with the most-recent `:keep_last_n` pre-flush entries plus any turns that landed during the flush. The agent process is never stopped. Use it from a `/new` chat command or a small wrapper GenServer that fires on an interval.

**Fail-fast.** Gralkor errors raise. Your supervision tree decides how to react.

**`memory_add` is async.** The tool returns `"Ingesting."` immediately and does the storage call in a background `Task`. Graphiti's entity/edge extraction can take tens of seconds; you don't want the agent waiting. Failures are logged; best-effort storage is the contract.

## Configure Lenses

A Lens is an application-owned memory channel. Its definition supplies a name, a graphiti ontology, a scope, and the ingestion process Gralkor invokes when content is sent through it. Register as many Lenses as your application needs:

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

```elixir
# config/runtime.exs
config :jido_gralkor,
  lenses: [
    [
      name: "observations",
      ontology: MyApp.Ontology,
      scope: :operator,
      ingestion: Gralkor.Lens.Ingestion.Store
    ],
    [
      name: "decisions",
      ontology: MyApp.Ontology,
      scope: :operator,
      ingestion: MyApp.DecisionIngestion
    ],
    [
      name: "generalisations",
      ontology: MyApp.Ontology,
      scope: :global,
      ingestion: Gralkor.Lens.Ingestion.Generalise
    ]
  ]
```

`:operator` Lenses are local to the operator and isolated from every other local Lens. `:global` Lenses all write into the same shared global pool. Each global episode records the Lens it arrived through, but searches of `"global"` are intentionally unfiltered and return relevant memory from the whole pool.

`Gralkor.Lens.Ingestion.Store` is the built-in straight-through process. A consumer can define any other ingestion process by implementing one callback:

```elixir
defmodule MyApp.DecisionIngestion do
  @behaviour Gralkor.Lens.Ingestion

  @impl true
  def ingest(request, store) do
    with {:ok, decisions} <- MyApp.Decisions.extract(request.content) do
      Enum.reduce_while(decisions, :ok, fn decision, :ok ->
        case Gralkor.Lens.Store.add(store, decision, request.source_description) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end
end
```

The callback receives the original `%Gralkor.Ingest{}` request and a Lens-bound `%Gralkor.Lens.Store{}`. It decides whether to make zero, one, or many writes and can use `Gralkor.Lens.Store.add/3`, `search/3`, and `remove/2`. The store, rather than consumer code, owns the physical partition, selected ontology, and global provenance.

The plugin mount chooses how an agent uses the registered Lenses:

```elixir
{JidoGralkor.Plugin,
 %{
   agent_name: "Susu",
   default_lens: "observations",
   search_targets: ["observations", "global"],
   generalise_lens: "generalisations"
 }}
```

- `default_lens` receives `memory_add` calls and automatic capture unless a turn supplies `tool_context[:lens]`.
- `search_targets` is an optional list of additional local Lens names and/or the reserved `"global"` target. Every Lens-aware search always includes the requesting operator's reserved `"default"` destination first; configured targets are additive. Omitting the option or using `[]` therefore searches only `"default"`. Naming `"default"` explicitly does not search it twice. A named global Lens is ingestion provenance, not a search filter, so it cannot be used as a target.
- `generalise_lens` is optional. It submits each flushed transcript to a second Lens independently of the primary capture Lens.

Consumers that ingest or search outside an agent call the same public boundary directly:

```elixir
:ok =
  Gralkor.Client.ingest(%Gralkor.Ingest{
    operator_id: "operator-42",
    lens: "decisions",
    content: "We chose Friday.",
    source_description: "release planning"
  })

{:ok, memories} =
  Gralkor.Client.search(%Gralkor.Search{
    operator_id: "operator-42",
    query: "When should we release?",
    targets: ["decisions", "global"],
    max_results: 10
  })
```

`Gralkor.Search.targets` has the same additive meaning as the plugin option: the operator's reserved `"default"` destination is always searched first. The result limit applies independently to default and every additional destination, and results retain destination order.

Registry and plugin configuration fail fast for blank, duplicate, reserved, or malformed Lens definitions and for unknown or unsound search targets. If no Lens configuration is used, the implicit `"default"` Lens preserves the existing operator partition and deployment-wide `:ontology` behavior.

### Ontology DSL

Each Lens ontology is a module declared with `Gralkor.Ontology`:

- `entity Foo do field … end` declares an entity. `field :name, :type, opts` supports `:string | :integer | :float | :boolean`, plus `required: true` and `doc:` (rendered as the Pydantic field description).
- `from Source do verb Target [do field … end] end` declares outgoing relationships from `Source`. The verb's name becomes the edge type in graphiti (`prefers` → `"PREFERS"`, `relates_to` → `"RELATES_TO"`). The optional `do` block carries edge properties.
- Same verb in multiple `from` blocks becomes one edge type with multiple endpoint pairs.
- `entities: :strict` excludes graphiti's generic `Entity` extraction — only your declared types survive. `entities: :open` lets graphiti extract generic Entity nodes alongside yours.
- `relationships: :scoped` populates graphiti's `edge_type_map` from your declared `(src, dst)` pairs, so named edges only fire between declared endpoints. `relationships: :open` drops the map; graphiti's default applies. Either way, graphiti always extracts edge candidates — generic fall-through edges between unconstrained pairs are not closed off.
- Both opts are required at `use` — no defaults; pick deliberately.

On each store write, graphiti receives the selected Lens ontology's `entity_types`, `edge_types`, `edge_type_map`, and `excluded_entity_types`, translated from the module's compile-time payload.

## Generalisation

`Gralkor.Lens.Ingestion.Generalise` is a built-in ingestion process for an ordinary Lens. It distils zero or more durable, confidence-scored generalisations from the submitted transcript and submits each survivor through the Lens-bound store. Graphiti's normal `add_episode` pipeline owns entity/edge extraction and reconciliation of repeated or contradicted facts while retaining source episodes as provenance; the Lens process does not duplicate that graph logic or replace/remove source episodes itself. The Lens definition determines both ontology and scope; generalisation has no special partitioning rule.

To run it automatically after capture, register a Lens with `ingestion: Gralkor.Lens.Ingestion.Generalise` and select its name as the plugin's `generalise_lens`. To invoke it without the plugin, submit a normal `%Gralkor.Ingest{lens: "generalisations", ...}` request. This is independent of the agent replying: any consumer surface can ingest through the same request.

### Optional: confidence threshold

Generalise persists the strongest hypotheses above a configurable confidence threshold (default `0.3`). Raise it to be more conservative, lower to capture more:

```elixir
# config/runtime.exs
config :jido_gralkor, generalise_min_confidence: 0.5
```

The older `Gralkor.Client.generalise/2` and `search_generalisations/3` APIs remain available for compatibility. Lens-based consumers should prefer the unified ingest/search boundary above.

## Experiential learning (legacy default pipeline)

When the implicit `"default"` Lens uses the legacy capture pipeline, every captured turn is also distilled into a flat `Gralkor.AgentLearning` record (`problem_kind`, `approach`, `success`, `lesson`) and written to the same operator partition. A custom Lens ingestion process owns any equivalent learning behavior it needs.

### Unconditional learning search on every recall

There is no opt-in flag. Every recall runs a parallel learning search alongside the main search, seeded with the raw user query and scoped to only `Learning` nodes via a graphiti **node search** (`Gralkor.GraphitiPool.search_nodes/5` → `g.search_` with `SearchFilters(node_labels: ["Learning"])`) — so the interpreter surfaces the learnings that came from the same kind of problem, biased toward approaches that succeeded (the bias lives in the learning node's summary/attributes, not a query primitive). Node search, not edge search: a `Learning` is a custom-entity node, and edge search's node-label filter matches edges by endpoint and would miss it. The learning search shares a 5s yield deadline with the generalisation search and degrades to the regular facts if it fails or times out. No LLM classification, no `TaskKind`: the previous `:erl_recall` opt-in flag and its query classifier have been removed — the unconditional path is what ERL now means.

## Testing against the in-memory twin

`Gralkor.Client.InMemory` is a real implementation of `Gralkor.Client` (not a mock) that stores canned responses and records every call. Your agent's integration tests can hit it without any network:

For Lens-aware calls, pair it with `Gralkor.Lens.Storage.InMemory` as shown in Required configuration; `Client.ingest/1` and `search/1` use the Lens storage boundary directly.

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

- `JidoGralkor.Plugin` — `use Jido.Plugin, state_key: :__memory__, singleton: true`. Handles `ai.react.query` (planting session, agent, selected Lens, and search targets) and `ai.request.completed` / `ai.request.failed` (capture).
- `JidoGralkor.ReAct` — `maybe_force_memory_search/2` helper. Folds `tool_choice: %{type: "function", function: %{name: "memory_search"}}` into ReAct overrides on iteration 1; passes through unchanged on iterations 2+.
- `JidoGralkor.Canonical` — normalises a Jido/ReAct turn into the canonical `[%Gralkor.Message{role, content}]` shape.
- `JidoGralkor.Lifecycle` — `Jido.AgentServer.Lifecycle` impl whose sole job is the death-triggered flush.
- `JidoGralkor.ContextRotator` — synchronous `rotate_now/2` for in-life context consolidation.
- `JidoGralkor.Actions.MemorySearch` — the ReAct tool that calls `Gralkor.Client.search/1` for configured Lens targets and falls back to legacy `recall/4` when no Lens search is configured. It short-circuits when no thread is committed or the query is blank.
- `JidoGralkor.Actions.MemoryAdd` — fire-and-forget ReAct tool.
- `JidoGralkor.Actions.MemoryBuildIndices` — admin tool. Description tells the LLM `DO NOT CALL` unless the user asked. Whole-graph index rebuild.
- `JidoGralkor.Actions.MemoryBuildCommunities` — admin tool. Same `DO NOT CALL` guard. Runs Graphiti community detection on this agent's partition.

The embedded Gralkor adapter (under `lib/gralkor/`):

- `Gralkor.Client` — legacy adapter behaviour plus the public `ingest/1` and `search/1` Lens boundary.
- `Gralkor.Client.Native` — production adapter; wires `Recall`, `CaptureBuffer`, `GraphitiPool`, `Generalise`, and `req_llm`.
- `Gralkor.Client.InMemory` — test twin.
- `Gralkor.Lens`, `Gralkor.Ingest`, `Gralkor.Search` — the resolved Lens model and consumer request values.
- `Gralkor.Lens.Store` / `Gralkor.Lens.Storage.Graphiti` — the ingestion capability and its collision-safe local/shared-global Graphiti placement.
- `Gralkor.Lens.Ingestion.Store` / `Generalise` — built-in straight-through and generalising ingestion processes.
- `Gralkor.Ontology` — compile-time DSL for declaring graphiti custom-entity ontologies (`entity`/`field`/`from`/verb macros).
- `Gralkor.Generalise` — hypothesise → evaluate → persist pipeline used by the generalising Lens ingestion process and retained legacy API.
- `Gralkor.Generalisation` — struct and wire format (`GEN|v1|{json}\ncontent`) for storing generalisations as graphiti episodes with controlled UUIDs (enabling update via re-extraction and delete via `remove_episode`).
- `Gralkor.Application`, `Gralkor.Python`, `Gralkor.GraphitiPool`, `Gralkor.CaptureBuffer`, `Gralkor.Recall`, `Gralkor.Distill`, `Gralkor.Interpret`, `Gralkor.Format`, `Gralkor.Config`, `Gralkor.Message`, `Gralkor.InterpretParseFailed`, `Gralkor.GeneralisationParseFailed` — the embedded pipelines (capture buffer, distill, interpret, recall, generalise) that drive Graphiti.

The behavioural contract lives in [`test-trees/`](https://github.com/elimydlarz/jido_gralkor/tree/main/test-trees); [`CLAUDE.md`](https://github.com/elimydlarz/jido_gralkor/blob/main/CLAUDE.md) carries the maintainer-facing mental model and project guidance.

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
