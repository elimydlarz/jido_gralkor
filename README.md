# jido_gralkor

Drop-in long-term memory for a [Jido](https://hex.pm/packages/jido) agent. One Hex package: the Jido plugin and ReAct tools on top of an embedded Gralkor memory adapter — Graphiti driven directly from the BEAM via [Pythonx](https://github.com/livebook-dev/pythonx), with no separate Gralkor service to deploy. Storage uses either an embedded FalkorDB child or a remote FalkorDB deployment.

You write your agent's prompt, model, and business tools. `jido_gralkor` covers session identity, recall, capture, the `memory_search` / `memory_add` ReAct tools, a small helper that pins `tool_choice` to `memory_search` on the first ReAct iteration so the agent itself authors its memory queries, a graceful-shutdown flush, a context-rotation primitive for long-running agents, **Destinations** for named graphs, **Lenses** for ingestion, and **Reflections** for consumer-invoked synthesis.

This is the canonical home for new Gralkor development: Gralkor is Jido-first. As of `3.0.0` the former `:gralkor_ex` Hex package is folded into this one, and the legacy `:gralkor` and `:gralkor_ex` packages direct consumers here. Consumers need only `{:jido_gralkor, "~> 8.0"}` for the whole memory stack.

## Install

```elixir
def deps do
  [
    {:jido_gralkor, "~> 8.0"}
  ]
end
```

Then fetch:

```bash
mix deps.get
```

The package requires Elixir `~> 1.18` and has runtime dependencies on `:jido`, `:jido_ai`, `:pythonx`, `:jason`, and `:yaml_elixir`. On the first native-runtime boot, Pythonx materialises a managed Python 3.12 environment with `graphiti-core` and `falkordblite`; consumers do not install Python themselves, but the boot needs package-download access and a writable cache.

## Required configuration

Four things the consumer must set up.

**1. A FalkorDB backend.** Graphiti runs in-process via Pythonx and connects to FalkorDB either as an embedded `falkordblite` child or over the network. Pick one:

```bash
# Embedded — falkordblite spawns a redis-server grandchild under this dir
export GRALKOR_DATA_DIR=/var/lib/<your-app>/gralkor   # writable
export GOOGLE_API_KEY=...                             # the default LLM and embedder are Google
```

Native Graphiti supports `google:` and `openai:` models, and each of its two
roles picks its provider independently. `GRALKOR_LLM_MODEL` selects the LLM
(default `google:gemini-3.1-flash-lite`) and `GRALKOR_EMBEDDER_MODEL` selects
the embedder (default `google:gemini-embedding-2-preview`). The
cross-encoder/reranker has no spec of its own and follows the LLM role's
provider.

Mixing the two roles is supported. An OpenAI LLM with a Google embedder builds
an OpenAI LLM client, an OpenAI reranker, and a Google embedder:

```bash
export GRALKOR_LLM_MODEL=openai:gpt-4.1-mini
export GRALKOR_EMBEDDER_MODEL=google:gemini-embedding-2-preview
export OPENAI_API_KEY=...   # the llm role selected openai
export GOOGLE_API_KEY=...   # the embedder role selected google
```

Set only the credential(s) for the providers your two specs actually select: an
all-Google pair needs `GOOGLE_API_KEY` alone, an all-OpenAI pair needs
`OPENAI_API_KEY` alone. Startup raises `ArgumentError` before any inference
client is constructed when a spec names a provider outside `:openai` / `:google`
(naming both specs and the supported providers), or when the credential for a
provider a spec selects is missing or blank (naming the variable and the role,
`"llm"` or `"embedder"`). Nothing checks that an LLM and an embedder from
different providers are otherwise compatible — embedding dimensions and the like
are yours to keep consistent.

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

Embedded runtimes admit one `add_episode` mutation at a time through their shared local connection while searches remain concurrent. The remote backend retains concurrent writes. To allow a long embedded query more than the 60-second default read timeout, configure the timeout in milliseconds:

```elixir
config :jido_gralkor,
  embedded_falkordb_socket_timeout_ms: 120_000
```

The setting is passed to the embedded Redis client as `socket_timeout`; it is ignored by remote FalkorDB. A zero, negative, or non-integer value raises `ArgumentError` when the embedded runtime starts.

**2. In-memory client in tests.** Swap the adapter for the in-memory twin:

```elixir
# config/test.exs
config :jido_gralkor,
  client: Gralkor.Client.InMemory,
  destination_storage: Gralkor.Destination.Storage.InMemory,
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
  start_supervised!(Gralkor.Destination.Storage.InMemory)
  :ok
end
```

When the client and storage layers use these in-memory adapters, the native supervision tree (Pythonx → GraphitiPool → CaptureBuffer) does not start and Lens or Reflection storage calls do not reach Graphiti. No FalkorDB backend is required.

**3. `Jido.Thread.Plugin` on your `use Jido` supervisor.** The plugin reads `session_id` from `agent.state[:__thread__].id`, so the thread plugin must be active:

```elixir
defmodule MyApp.Jido do
  use Jido,
    otp_app: :my_app,
    default_plugins: [Jido.Thread.Plugin, Jido.Identity.Plugin]
end
```

**4. A non-blank human name in agent state.** Before any completed or failed turn is captured, populate `agent.state[:user_name]` with the current human's name (for example, from the request's tool context in `on_before_cmd/2`). The plugin deliberately has no generic `"User"` fallback: a missing or blank value raises `ArgumentError` before capture.

`:jido_gralkor` auto-supervises its native runtime (Python → GraphitiPool → CaptureBuffer) when a FalkorDB backend is configured — no separate `Gralkor.Server` to wire into your supervision tree, and no readiness gate to add. By the time `Application.start/2` returns, `Gralkor.Client` is ready. Graceful application shutdown waits for active Lens flush work and flushes buffered capture before CaptureBuffer stops. Reflection execution is not supervised or scheduled by Jido Gralkor; the consuming application decides when to invoke it.

## Configuration reference

Everything `:jido_gralkor` reads, in one place. Nothing else is configurable — Python, the venv, and the Graphiti client are internal concerns with no consumer-facing knobs.

### Application environment (`config :jido_gralkor, …`)

| Key | Type | Default | What it does |
| --- | --- | --- | --- |
| `:falkordb` | keyword: `:host`, `:port`, optional `:username`, `:password`, `:ssl` | unset | Remote FalkorDB connection. Wins over the embedded backend when both are set. `:ssl` defaults to `false`. Invalid shape raises `ArgumentError` at app start. See [Required configuration](#required-configuration). |
| `:embedded_falkordb_socket_timeout_ms` | positive integer | `60_000` | Socket read timeout for the embedded FalkorDB connection, converted to seconds for `AsyncFalkorDB`. Ignored by remote FalkorDB. Invalid values raise `ArgumentError` when the embedded runtime starts. |
| `:destinations` | list of keyword definitions | packaged `operator` and `global` Destinations | The Destination registry. Each application definition has only `:name`; its exact name is a shared logical graph ID. `global` is the single shared global graph, while `operator` resolves to `operator/<operator id>`; application names beginning `operator/` are rejected. See [Destinations](DESTINATIONS.md). |
| `:lenses` | list of keyword definitions | `[]` | The Lens registry. Appending Lenses use `:name`, `:destination`, and `:ingestion`, with optional `:ontology` (default `Gralkor.DefaultOntology`) and `write: :append`; replaceable Lenses use `:name`, `:destination`, `write: :replace_graph`, and `:graph_format`. Blank, duplicate, reserved (`"operator"`, `"global"`), retired (`"default"`), provenance-delimiter-containing (`" [lens: "`), or malformed definitions raise. See [Configure Lenses](#configure-lenses). |
| `:client` | module implementing `Gralkor.Client` | `Gralkor.Client.Native` | The adapter. Set to `Gralkor.Client.InMemory` in tests; that value also suppresses the native supervision tree (Pythonx → GraphitiPool → CaptureBuffer). |
| `:lens_storage` | module | `Gralkor.Lens.Storage.Graphiti` | Physical storage behind `Gralkor.Lens.Store`. Set to `Gralkor.Lens.Storage.InMemory` in tests — pinning `:client` alone does **not** intercept `Client.ingest/1`, `replace/1`, or `search/1`. |
| `:destination_storage` | module implementing `Gralkor.Destination.Storage` | `Gralkor.Destination.Storage.Graphiti` | The single memory boundary behind `Client.search/1` and Reflection Destination outputs. Artefact writes create-or-confirm by stable `artefact.id`. Set to `Gralkor.Destination.Storage.InMemory` in tests. |
| `:reflections` | list of keyword definitions | built-in `generalisations` and `erl` declarations | The Reflection registry. Each definition has a unique non-blank `:name` that does not contain the reserved `" [lens: "` provenance delimiter, a repository-relative YAML `:chain_of_thought` path, and an `:outputs` list containing exactly one Destination output plus at most one return output. Supplying the key replaces the built-in declarations. See [Configure Reflections](#configure-reflections). |
| `:reflection_root` | path | application package root | Root used to resolve Reflection YAML paths. The default makes the packaged `priv/reflections/*.yaml` files work after installation; set it when an application keeps custom CoTs under another repository directory. |
| `:recall_deadline_ms` | positive integer | `12_000` | Wall-clock budget for a whole recall search and presentation. On expiry the recall task is killed and `recall/4` returns `{:error, :recall_deadline_expired}`. |
| `:test` | boolean | `false` | Verbose diagnostic logging: recall queries, returned facts, and flushed capture bodies are written to the log. Debugging aid — leave it off in production, where it would log memory contents. |

```elixir
# config/runtime.exs — everything optional, shown with its default
config :jido_gralkor,
  embedded_falkordb_socket_timeout_ms: 60_000,
  recall_deadline_ms: 12_000
```

`:reflection_storage` is retired and causes startup to fail. Consumers deliver a Reflection's required Destination output through `:destination_storage`, which is the single memory boundary for both search and Reflection output.

The implicit `"operator"` Lens and legacy `capture/5`, `memory_add/3`, and `recall/4` need no ontology configuration. The Lens uses the packaged operator Destination and the library-owned `Gralkor.DefaultOntology`. Application-specific extraction schemas belong on appending Lenses or Reflections.

`recall/4` presents every fact returned by memory search verbatim and in order inside an untrusted memory block, retaining any source wording carried by each fact. Recall makes no second inference call: the consuming agent decides how to interpret the returned memory with its own model.

### Environment variables

| Variable | Default | What it does |
| --- | --- | --- |
| `GRALKOR_DATA_DIR` | unset | Writable directory for the embedded `falkordblite` backend (it spawns a `redis-server` grandchild there). Ignored when `:falkordb` is configured. With neither set, no native runtime starts. |
| `GOOGLE_API_KEY` / `OPENAI_API_KEY` | — | Provider credentials for Graphiti's Python-side clients. Which one you need follows from the two model specs: each of `GRALKOR_LLM_MODEL` and `GRALKOR_EMBEDDER_MODEL` selects a provider, and only a provider some role selects needs its key. A provider selected by neither role needs no key at all. When the native runtime starts, a missing or blank key for a selected provider raises `ArgumentError` before any inference client is constructed, naming the variable and the role (`"llm"` or `"embedder"`). |
| `GRALKOR_LLM_MODEL` | `google:gemini-3.1-flash-lite` | `"provider:model"` spec for the Graphiti LLM. `google:` and `openai:` are supported; another provider raises at native startup, naming both specs and the supported providers. This role's provider also builds the cross-encoder/reranker. GPT-5.5 and GPT-5.6 clients receive `reasoning: "none"` explicitly so Graphiti writes do not inherit an incompatible reasoning tier. |
| `GRALKOR_EMBEDDER_MODEL` | `google:gemini-embedding-2-preview` | Same form and same supported providers, for the embedder — chosen independently of the LLM role, so `openai:` LLM + `google:` embedder is a valid pair (it needs both keys). A Google embedder is constructed with `batch_size: 1`; the OpenAI embedder takes no batch size. |

### Plugin mount options

```elixir
{JidoGralkor.Plugin, %{agent_name: "Susu", ingestion_lens: "observations", …}}
```

| Option | Required | Default | What it does |
| --- | --- | --- | --- |
| `:agent_name` | yes | — | Non-blank string naming the agent in captured transcripts. Anything else raises at mount. |
| `:ingestion_lens` | no | unset (implicit-operator mode) | Registered Lens name receiving `memory_add` and automatic capture. The removed `:default_lens` option raises and identifies this replacement. |

Per-turn, `tool_context[:lens]` overrides `:ingestion_lens` for that query; the plugin retains the selection on the request's thread entry so later capture stays bound to it.

Search selection is invocation-local, not a plugin mount option. `memory_search` accepts optional `destinations` and `lenses`; the removed `:search_destinations` mount option raises with migration guidance.

### `JidoGralkor.ContextRotator.rotate_now/2`

| Option | Default | What it does |
| --- | --- | --- |
| `:flush_timeout_ms` | `30_000` | How long the synchronous pre-rotation flush may take. |
| `:keep_last_n` | `4` | Most-recent pre-flush thread entries seeded into the rotated thread. `0` drops everything that existed before the flush; turns that land during the flush are always carried over. |

## A complete configuration

Everything above, in one deployment. Three files.

**Ontologies are modules referenced by writers.** Define an ontology as ordinary compiled Elixir in your own `lib/`, then select it on each appending Lens or Reflection Destination output that should extract with it. Destinations only name graphs.

```elixir
# lib/my_app/ontologies.ex — compiled code. Named by writer definitions below.
defmodule MyApp.Ontology do
  use Gralkor.Ontology, entities: :strict, relationships: :scoped

  entity Teammate, "A person the agent works with." do
    field :handle,   :string, required: true, doc: "stable login handle"
    field :timezone, :string,                 doc: "IANA tz"
  end

  entity WorkingPreference, "A way a teammate prefers to work." do
    field :description, :string, required: true
  end

  from Teammate do
    prefers WorkingPreference do
      field :since, :string, doc: "date first observed"
    end
  end
end
```

```elixir
# config/runtime.exs
import Config

config :jido_gralkor,
  # Backend — pick one. Remote wins if both are present.
  falkordb: [
    host: System.fetch_env!("FALKORDB_HOST"),
    port: String.to_integer(System.fetch_env!("FALKORDB_PORT")),
    username: System.get_env("FALKORDB_USERNAME"),
    password: System.get_env("FALKORDB_PASSWORD"),
    ssl: System.get_env("FALKORDB_SSL") == "true"
  ],

  # The Lens registry selects ingestion behavior and a Destination.
  lenses: [
    [
      name: "observations",
      destination: "global",
      ontology: MyApp.Ontology,
      ingestion: Gralkor.Lens.Ingestion.Store
    ],
    [
      name: "decisions",
      destination: "global",
      ontology: MyApp.Ontology,
      ingestion: MyApp.DecisionIngestion
    ]
  ],

  # Optional custom Reflection declarations. Omit this key to use the two
  # packaged declarations shown here.
  reflections: [
    [
      name: "generalisations",
      chain_of_thought: "priv/reflections/generalisations.yaml",
      outputs: [
        [kind: :destination, destination: "global"]
      ]
    ],
    [
      name: "erl",
      chain_of_thought: "priv/reflections/erl.yaml",
      outputs: [
        [
          kind: :destination,
          destination: "operator",
          ontology: Gralkor.Reflection.ERLOntology
        ]
      ]
    ]
  ],

  # Tuning — optional, shown at its default.
  recall_deadline_ms: 12_000

```

```elixir
# lib/my_app/chat_agent.ex — the mount selects among the registered names.
plugins: [
  {JidoGralkor.Plugin,
   %{
     agent_name: "Susu",
     ingestion_lens: "observations"
   }}
]
```

That mount writes captured turns and `memory_add` calls through the `"observations"` Lens to `global`. Memory search independently defaults to every accessible registered Destination and may narrow each call by Destination and Lens. Ingestion does not invoke Reflections; a consumer that wants synthesis explicitly selects and runs a Reflection at the point its own workflow requires.

**Ontology placement.** Appending Lenses and Reflection Destination outputs default to Jido Gralkor's open `Gralkor.DefaultOntology`. Packaged ERL explicitly uses `Gralkor.Reflection.ERLOntology`. Applications attach custom ontology modules to their writers. If an older deployment set `config :jido_gralkor, :ontology`, remove it and select the module on each Lens or Reflection Destination output that needs it.

## Wire it on your agent

```elixir
defmodule MyApp.ChatAgent do
  use Jido.Agent,
    name: "my_chat",
    schema: [user_name: [type: :string, required: true]],
    strategy:
      {Jido.AI.Reasoning.ReAct.Strategy,
       tools: [
         JidoGralkor.Actions.MemorySearch,
         JidoGralkor.Actions.MemoryAdd,
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
         ingestion_lens: "observations"
       }}
    ]

  # Optional: pin tool_choice to memory_search on iteration 1 so the agent
  # itself authors a focused recall query in-thread.
  defmodule RequestTransformer do
    @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

    @impl true
    def transform_request(_request, state, _config, _runtime_context) do
      {:ok, JidoGralkor.ReAct.maybe_force_memory_search(%{}, state)}
    end
  end
end
```

The plugin claims Jido's `:__memory__` slot. On `ai.react.query`, it plants `:session_id` (when a thread is committed), `:agent_name`, and the selected ingestion `:lens` on the signal's `tool_context`. Search selectors come from each `memory_search` call. Recall itself is the LLM's job — `JidoGralkor.ReAct.maybe_force_memory_search/2` is the cheapest way to force it on iteration 1. Capture runs automatically on completion and failure: the ReAct event trace is normalised into Gralkor's canonical `[%Gralkor.Message{role, content}]` shape via `JidoGralkor.Canonical` — `user` for the user query, `behaviour` for intermediate thinking / tool calls / tool results, `assistant` for the final answer on completed turns, or a terminal `"request failed: …"` `behaviour` on failed turns so the failure stays visible to downstream distillation.

Set `tool_context[:lens]` on an individual query to override `ingestion_lens` for that turn. The plugin retains the selection on the request's Jido thread entry, making it authoritative for both `memory_add` and later completion or failure capture after ReAct has released its transient tool context.

The plugin reads `user_name` per-turn from `agent.state[:user_name]`. Populate it before each request (for example, via `on_before_cmd/2` from the signal's `tool_context`) so distill renders user lines under the correct human identity. Missing and blank names raise; there is no generic fallback.

## What happens at runtime

**Session identity.** `session_id` is the current Jido thread id (read from `agent.state[:__thread__].id`, populated by `Jido.Thread.Plugin`). The plugin does not mint its own identifier — Jido's thread lifecycle is the single source of truth.

**Destinations.** Every Lens and every Reflection Destination output references a registered Destination, which resolves to one logical graph ID: `global`, `operator/<operator id>`, or an application Destination's exact shared name. Application names beginning `operator/` are reserved for operator-local graphs and rejected. At the Graphiti boundary, each logical ID is encoded exactly once as `g_` followed by the lowercase hexadecimal encoding of every original byte. Appending Lenses and Destination outputs govern their own extraction. Multiple writers may save to the same Destination. Replacement writes inject `_gralkor_lens` into supplied nodes and relationships so a replaceable Lens changes only its own content there.

The physical encoding replaces the former lossy `-` and `/` to `_` normalisation. Graphs stored under old physical names are not read or migrated automatically; migrate them only from known logical Destination/operator IDs, or re-ingest their source content, because underscores cannot recover the original ID.

**Reflection invocation.** Lens-aware capture requires a non-blank operator before buffering, and CaptureBuffer assigns each buffered ingestion one cryptographically collision-resistant ID that it reuses across flush retries. Capture and ordinary `Gralkor.Client.ingest/1` calls stop after Lens ingestion; neither invokes a Reflection. The consuming application owns the event, job, or request that selects a configured Reflection, calls `Gralkor.Reflection.Runner.run/2`, and delivers the resulting artefact to its declared outputs. Direct invocations supply their own replay-stable invocation ID and any completed lensed representations the Reflection should inspect.

**First-turn bootstrap.** On the very first query of a fresh agent, the thread isn't yet committed (the ReAct strategy's `ThreadAgent.append` runs after the plugin hook). The plugin plants `:agent_name` plus the configured ingestion `:lens`, but no `:session_id`; completed and failed turn capture are both skipped with a warning until a committed thread supplies that identity. `memory_search` still searches for the current operator because public Search does not depend on conversation-session identity.

**Death-triggered flush.** `JidoGralkor.Lifecycle` is an optional `Jido.AgentServer.Lifecycle` implementation. When wired as `lifecycle_mod:` on the agent, graceful termination of the AgentServer calls the configured client's `flush/1` callback for the active thread so an orphaned agent doesn't strand its capture buffer. The plugin mount alone does not enable this lifecycle. No idle-timer machinery — Jido's `AgentServer` owns `:idle_timeout` directly.

```elixir
{:ok, pid} =
  MyApp.Jido.start_agent(
    MyApp.ChatAgent,
    id: "operator-42",
    initial_state: %{user_name: current_user.name},
    lifecycle_mod: JidoGralkor.Lifecycle
  )
```

**Context rotation.** `JidoGralkor.ContextRotator.rotate_now/2` synchronously flushes the active session via `flush_and_await/2`, installs a fresh Jido thread, and seeds the rotated thread with the most-recent `:keep_last_n` pre-flush entries plus any turns that landed during the flush. It returns `:ok` when there is no committed thread and `{:error, reason}` when state reading, flushing, or thread installation fails. The agent process is never stopped. Use it from a `/new` chat command or a small wrapper GenServer that fires on an interval.

**Error contracts.** Invalid configuration, invalid Lens requests, and automatic plugin-capture failures raise. Valid explicit `Gralkor.Client.ingest/1`, `replace/1`, `search/1`, and adapter operations return tagged success/error tuples; the ReAct search action propagates those errors. The asynchronous `memory_add` action logs background failures and still returns immediately, as described below.

**`memory_add` is async.** The tool returns `"Ingesting."` immediately and does the storage call in a background `Task`. Graphiti's entity/edge extraction can take tens of seconds; you don't want the agent waiting. Failures are logged; best-effort storage is the contract.

## Configure Lenses

A Lens is an application-owned memory ingestion channel that targets a Destination. An appending Lens selects its extraction ontology; its write mode sends content through an ingestion process. A whole-graph replacement Lens replaces its own graph content at the Destination.

Appending is the default write mode. An appending Lens names its Destination and the ingestion process Gralkor invokes when content is sent through it; `write: :append` may be stated explicitly or omitted.

The ontology is a module you compile into your own application — declared once in `lib/`, then named by each appending Lens that should extract with it:

```elixir
# lib/my_app/ontology.ex
defmodule MyApp.Ontology do
  use Gralkor.Ontology, entities: :strict, relationships: :scoped

  entity Teammate, "A person the agent works with." do
    field :handle,   :string, required: true, doc: "stable login handle"
    field :timezone, :string,                  doc: "IANA tz"
  end

  entity WorkingPreference, "A way a teammate prefers to work." do
    field :description, :string, required: true
  end

  from Teammate do
    prefers WorkingPreference do
      field :since, :string, doc: "date first observed"
    end

    trusts Teammate
  end
end
```

Point as many Lenses as your application needs at `global`, `operator`, or an application Destination. Several Lenses may use the same Destination with different ontologies:

```elixir
# config/runtime.exs
config :jido_gralkor,
  lenses: [
    [
      name: "observations",
      destination: "global",
      ontology: MyApp.Ontology,
      ingestion: Gralkor.Lens.Ingestion.Store
    ],
    [
      name: "decisions",
      destination: "global",
      ontology: MyApp.Ontology,
      ingestion: MyApp.DecisionIngestion
    ]
  ]
```

A replaceable Lens declares `write: :replace_graph` and the graph format it accepts instead of `:ingestion`:

```elixir
config :jido_gralkor,
  lenses: [
    [
      name: "systems",
      destination: "global",
      write: :replace_graph,
      graph_format: :property_graph
    ]
  ]
```

Destination names control visibility: `operator` resolves a separate `operator/<operator id>` graph for each operator; `global` and application Destination names resolve to one shared graph each.

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

The callback receives the original `%Gralkor.Ingest{}` request and a Lens-bound `%Gralkor.Lens.Store{}`. It decides whether to make zero, one, or many writes and can use `Gralkor.Lens.Store.add/3` and `search/3`. The selected Destination supplies the graph; the Lens supplies the ontology. `Client.ingest/1` accepts appending Lenses and raises for replaceable Lenses; `Client.replace/1` accepts replaceable Lenses and raises for appending Lenses.

The plugin mount chooses how an agent uses the registered Lenses:

```elixir
{JidoGralkor.Plugin,
 %{
   agent_name: "Susu",
   ingestion_lens: "observations"
 }}
```

- `ingestion_lens` receives `memory_add` calls and automatic capture unless a turn supplies `tool_context[:lens]`.

Search is independent of that mount. With only a query, `memory_search` searches episodes in every accessible registered Destination. Optional selectors narrow one invocation; names are ORed within each list and the two lists intersect:

```elixir
%{
  query: "What did earlier rollouts teach us?",
  destinations: ["global", "release-notes"],
  lenses: ["observations", "decisions"]
}
```

This includes episodes only when their Destination is either selected Destination and their originating Lens is either selected Lens. Selecting a Lens never adds its Destination. A Lens selector applies only to episode results; direct callers may still explicitly request facts, nodes, or Reflection artefacts without a Lens selector.

Consumers that ingest, replace, or search outside an agent call the same public boundary directly:

```elixir
:ok =
  Gralkor.Client.ingest(%Gralkor.Ingest{
    id: "release-planning-2026-08-28",
    operator_id: "operator-42",
    lens: "decisions",
    source_kind: :conversation,
    content: "We chose Friday.",
    source_description: "release planning"
  })

{:ok, memories} =
  Gralkor.Client.search(%Gralkor.Search{
    operator_id: "operator-42",
    query: "When should we release?",
    destinations: ["global"],
    lenses: ["decisions"],
    max_results: 20
  })

:ok =
  Gralkor.Client.replace(%Gralkor.Replace{
    operator_id: "operator-42",
    lens: "systems",
    graph: %Gralkor.Graph{
      format: :property_graph,
      data: %{
        nodes: [
          %{id: "payments", labels: ["System"], properties: %{name: "Payments"}},
          %{id: "ledger", labels: ["System"], properties: %{name: "Ledger"}}
        ],
        relationships: [
          %{
            from: "payments",
            to: "ledger",
            type: "DEPENDS_ON",
            properties: %{protocol: "events"}
          }
        ]
      }
    }
  })
```

Every ingestion requires a non-blank `operator_id`, a non-blank replay-stable `id`, and deterministic provenance through `source_kind`. Both identifiers are validated before Lens storage begins. A consumer may use that ingestion ID as a related Reflection invocation ID; `Gralkor.Reflection.Runner` derives the artefact ID from the operator ID, invocation ID, and Reflection name. Reusing an ingestion ID does not deduplicate the Lens episode write.

The supported source kinds are:

- `:conversation` accepts speaker-attributed text and becomes a Graphiti message episode.
- `:document` accepts text and becomes a Graphiti text episode.
- `:structured_record` accepts a JSON-compatible map or list, which Gralkor JSON-encodes for a Graphiti JSON episode.

`source_kind` says where the information came from; it is not a credibility, truth, opinion, or speculation rating. Gralkor validates the kind and its content shape before invoking a Lens or Graphiti. Automatic turn capture declares `:conversation`; callers using `Gralkor.Ingest` or `memory_add/4` declare the kind themselves, while legacy `memory_add/3` remains a document-text compatibility call. The same Graphiti extraction call receives static guidance to retain attribution and epistemic wording such as uncertainty or speculation—Gralkor does not run a second presentation-classification inference. Fact results resolve their originating episodes and append the episode identifier, source kind, and source description on recall.

Appending Lens episodes record writer provenance by suffixing their source description with ` [lens: <Lens name>]`; Reflection episodes use the exact source description `reflection:<Reflection name>`. Both registries reject names containing the Lens delimiter so these forms stay unambiguous. This episode-writer provenance is separate from `_gralkor_lens`, which owns replacement-graph nodes and relationships.

Search defaults to stored episodes across every accessible registered Destination: the current operator's private `operator/<operator id>` logical graph plus every shared Destination. Supplying `destinations` narrows the graphs; supplying `lenses` narrows writers; OR applies within either list and both dimensions must match when both are present. Destination searches run concurrently while results retain selected Destination order. `max_results` defaults to `20`, must be a positive integer, and applies independently after writer filtering in every Destination. Each episode identifies its Destination plus its originating Lens or declaring Reflection; raw legacy episodes that carry neither trusted writer marker are omitted before that limit rather than assigned invented provenance. Direct callers may explicitly request `:facts`, `:nodes`, or `:artefacts` without Lens selectors; node searches accept `entity_types`, fact searches accept `edge_types`, and artefact searches may narrow by `artefact_id`. The `memory_search` action returns attributed episode results as JSON.

`:property_graph` is the supported replacement format. Every node requires a unique, non-blank string `:id`, a list of non-blank string `:labels`, and a `:properties` map. Every relationship requires `:from` and `:to` identifiers naming supplied nodes, a non-blank string `:type`, and a `:properties` map. This payload is the whole current graph for the Lens; partial node and relationship operations are not supported.

Replacement changes only content owned by that Lens at its Destination. Gralkor overwrites any supplied `_gralkor_lens` property with the selected Lens name on every inserted node and relationship. Content saved through another Lens or Reflection, or carrying no Lens ownership, remains unchanged. An empty graph removes all graph content owned by the selected Lens. The supplied graph format must match the Lens's configured `:graph_format`.

Invalid Lens names, write modes, formats, and graph data raise `ArgumentError`; graph data is fully validated before storage mutation begins. Once a valid replacement starts, deletion and insertion are not transactional: an import error is returned, and content already removed or inserted is not rolled back.

Registry and plugin configuration fail fast for blank, duplicate, reserved, retired, or malformed Lens definitions and for unknown Lens names. The retired `"default"` Lens name raises with guidance to use `"operator"`; it is not an alias. If no Lens configuration is used, the implicit `"operator"` Lens writes to `operator/<operator id>` and uses Jido Gralkor's built-in generic extraction contract.

### Ontology DSL

Each writer ontology is a module declared with `Gralkor.Ontology`:

- `entity Foo do field … end` declares an entity. `field :name, :type, opts` supports `:string | :integer | :float | :boolean`, plus `required: true` and `doc:` (rendered as the Pydantic field description).
- `entity Foo, "when to extract one" do … end` adds a description, rendered as the extracted type's own description. Graphiti's extractor reads it to decide when to mint the entity, so a type whose name alone is ambiguous — `Preference`, `Pattern`, `Learning` — is extracted far more reliably with one. The description must be a literal string.
- `from Source do verb Target [do field … end] end` declares outgoing relationships from `Source`. The verb's name becomes the edge type in graphiti (`prefers` → `"PREFERS"`, `relates_to` → `"RELATES_TO"`). The optional `do` block carries edge properties.
- Same verb in multiple `from` blocks becomes one edge type with multiple endpoint pairs.
- `entities: :strict` excludes graphiti's generic `Entity` extraction — only your declared types survive. `entities: :open` lets graphiti extract generic Entity nodes alongside yours.
- `relationships: :scoped` populates graphiti's `edge_type_map` from your declared `(src, dst)` pairs, so named edges only fire between declared endpoints. `relationships: :open` drops the map; graphiti's default applies. Either way, graphiti always extracts edge candidates — generic fall-through edges between unconstrained pairs are not closed off.
- Both opts are required at `use` — no defaults; pick deliberately.

**Protected field names.** Entity and edge *type* names are unrestricted — pick whatever suits your domain. Field names are not: graphiti rejects any custom entity attribute whose name collides with a field on its own `EntityNode`, namely `uuid`, `name`, `group_id`, `labels`, `created_at`, `summary`, `attributes`, and `name_embedding`. The DSL does not currently catch this at compile time, so `field :name, :string` compiles and then raises `EntityTypeValidationError` from Python on the first write through the Lens that selected the ontology. Name fields for what they hold — `handle`, `title`, `statement` — rather than reaching for `name` or `summary`.

On each store write, graphiti receives the selected Lens or Reflection ontology's `entity_types`, `edge_types`, `edge_type_map`, and `excluded_entity_types`, translated from the module's compile-time payload.

## Configure Reflections

A Reflection is a named synthesis process declared with a repository YAML Chain of Thought and an `outputs` list. The registry loads and validates declarations; it does not decide when they run.

Every Reflection declares exactly one `:destination` output and at most one `:return` output. The Destination output names the memory Destination and extraction ontology. A return output names a consumer module implementing `Gralkor.Artefact.ReturnHandler`. These declarations are resolved output targets: after `Gralkor.Reflection.Runner` produces an artefact, the consumer decides when and how to call `Gralkor.Destination.Storage.put_artefact/4` and the handler's standard `return/3` callback. Jido Gralkor does not schedule, supervise, retry, or journal Reflection execution or output delivery.

The package supplies two declarations by default:

- `generalisations` uses `priv/reflections/generalisations.yaml` and declares a `global` Destination output using `Gralkor.DefaultOntology`.
- `erl` uses `priv/reflections/erl.yaml` and declares an `operator` Destination output using `Gralkor.Reflection.ERLOntology`, whose `Learning` entity declares optional `problem_kind`, `approach`, `success`, and `lesson` fields.

Before packaged generalisation inference begins, Gralkor performs one default episode search across every accessible registered Destination. Its query contains every current representation, so the same search returns related Lens-authored observations and existing Reflection-authored generalisations; inference receives those results separately from the current representations. A related-memory search failure fails that Reflection before inference without changing the completed ingestion.

The packaged process inspects current and related observations with prior generalisations, then carries forward, combines, broadens, narrows, splits, replaces, or otherwise revises generalisations as those observations warrant. Each stored generalisation contains exactly `content`, evolution-depth `level`, and `evolves_from`. `evolves_from` contains only the influencing prior generalisations, each snapshotted as exactly its `content` and `level`; historical predecessors and snapshots remain unchanged. A generalisation with no snapshots is level `1`; otherwise its level is one greater than the highest referenced level.

Set `:reflections` to replace those defaults, and set `:reflection_root` when their YAML paths resolve from somewhere other than the installed application root. A Destination output's optional `:ontology` defaults to `Gralkor.DefaultOntology`.

```elixir
config :jido_gralkor,
  reflection_root: File.cwd!(),
  reflections: [
    [
      name: "release-review",
      chain_of_thought: "priv/reflections/release-review.yaml",
      outputs: [
        [
          kind: :destination,
          destination: "global",
          ontology: MyApp.ReleaseOntology
        ],
        [kind: :return, handler: MyApp.ReleaseReviews]
      ]
    ]
  ]
```

The return handler is intentionally small because Gralkor owns the mapping and callback name:

```elixir
defmodule MyApp.ReleaseReviews do
  @behaviour Gralkor.Artefact.ReturnHandler

  @impl true
  def return(operator_id, invocation_id, %Gralkor.Artefact{} = artefact) do
    MyApp.deliver_release_review(operator_id, invocation_id, artefact)
  end
end
```

A consumer selects and invokes a configured Reflection synchronously, then orchestrates each declared output explicitly:

```elixir
alias Gralkor.Destination.Storage
alias Gralkor.Reflection.Registry
alias Gralkor.Reflection.Runner

operator_id = "operator-42"
invocation_id = "release-2026-09-02"

reflection =
  Enum.find(Registry.configured!(), &(&1.name == "release-review")) ||
    raise "unknown Reflection"

invocation = %{
  id: invocation_id,
  operator_id: operator_id,
  invocation_context: %{reason: "release decision"},
  representations: completed_representations
}

{:ok, artefact} =
  Runner.run(
    reflection,
    invocation,
    tools: host_tools,
    tool_context: host_tool_context
  )

Enum.each(reflection.outputs, fn
  %{kind: :destination} = output ->
    :ok = Storage.put_artefact(output, reflection.name, operator_id, artefact)

  %{kind: :return, handler: handler} ->
    :ok = handler.return(operator_id, invocation_id, artefact)
end)
```

Each YAML file contains an ordered, non-empty `steps` list. A step declares a `label`, natural-language `directions`, and an exact structured `output` schema. Later directions may interpolate prior outputs with `{{output_name}}`. At runtime each step receives the invocation ID, invocation context, completed lensed representations, host tools, and tool context. The model may direct tool calls described by the custom directions; tool results return to the same step before it produces its structured output. That output is validated exactly, made available to later interpolation, and the final step becomes one `%Gralkor.Artefact{}` whose fields are exactly `id` and `payload`. Producer identity remains execution provenance and is not embedded in the artefact.

Registry-backed client operations resolve current application configuration per call, and `Registry.configured!/0` resolves the current Reflection declarations each time the consumer calls it. Mounted plugins retain their resolved ingestion Lens and each MemorySearch invocation carries its own selectors. Remount a plugin to change its mount settings; restart the application after changing startup-owned capture or backend configuration.

Multiple Reflections and Lenses may save to the same Destination. Search selects Destinations directly:

```elixir
{:ok, artefacts} =
  Gralkor.Client.search(%Gralkor.Search{
    operator_id: "operator-42",
    query: "What release approaches have worked?",
    destinations: ["operator"],
    result_type: :artefacts,
    max_results: 20
  })

{:ok, [artefact]} =
  Gralkor.Client.search(%Gralkor.Search{
    operator_id: "operator-42",
    query: "",
    destinations: ["operator"],
    result_type: :artefacts,
    artefact_id: "reflection-123"
  })
```

`result_type: :artefacts` returns artefacts from the selected Destinations, and `artefact_id` optionally narrows the lookup to one exact artefact. The deterministic UUID derives from the operator ID, invocation ID, and Reflection name, but the artefact itself contains no producer identity. Before extraction, Graphiti waits for a graph uniqueness constraint and acquires a graph-backed UUID claim with a renewable lease, so independent application runtimes serialize equal work and reject conflicting immutable content before Graphiti's upsert can overwrite it. Lease expiry and renewal use the graph server's clock; every ownership transfer advances a generation. For a claimed deterministic UUID, the episode, every extracted entity and edge, and its extraction-completion marker persist in one generation-fenced FalkorDB query, so loss of ownership aborts the complete graph-effect set before it commits. Until that marker exists, canonical lookup retains the episode only as resumable storage state and artefact search excludes it. Repeating an equal marked write is a successful confirmation without extraction; an equal unmarked deterministic episode re-enters normal extraction without rerunning the Runner. Artefact search uses ranked completed episodes to select up to the requested number of artefact identifiers, then enumerates every completed episode carrying those identifiers independently of BM25. It collapses equal historical duplicates by artefact ID, preserves the selected ranking, and reports an artefact conflict if any completed duplicate under a selected ID disagrees.

Reflection artefact episodes written before the extraction-completion marker existed remain hidden because an absent marker cannot distinguish a fully extracted legacy write from a partial write. Invoke the original Reflection again with the same stable invocation ID and deliver its artefact to the same Destination to establish the marker; unmarked legacy episodes remain non-searchable. An operator-authored migration may mark a legacy episode only after independently verifying that its extraction completed and its immutable artefact content is the intended canonical value. This does not migrate an episode left under the former physical graph-ID encoding.

## Testing against the in-memory twin

`Gralkor.Client.InMemory` is a real implementation of `Gralkor.Client` (not a mock) that stores canned responses and records every call. Your agent's integration tests can hit it without any network:

For Lens-aware ingest and replacement calls, pair it with `Gralkor.Lens.Storage.InMemory` as shown in Required configuration. Destination search uses `Gralkor.Destination.Storage.InMemory` instead.

```elixir
setup do
  Gralkor.Client.InMemory.reset()
  :ok
end

test "agent recalls stored context" do
  Gralkor.Client.InMemory.set_recall({:ok, "<gralkor-memory>known fact</gralkor-memory>"})
  Gralkor.Client.InMemory.set_capture(:ok)
  # ... exercise your agent, assert on responses, inspect recorded calls
end
```

The shared `Gralkor.ClientContract` macro suite exercises the in-memory twin. The production `Gralkor.Client.Native` adapter proves the same public port separately in its adapter tests.

Maintainers can use the project test aliases according to the feedback speed and runtime boundary they need:

```bash
mix test              # Unit and Integration; excludes Functional and Journey
mix test.unit         # Unit
mix test.integration  # Integration
mix test.functional   # Functional; may call real model providers
mix test.journey      # Journey
mix test.fast         # stale/affected Unit and Integration
mix test.changed      # stale/affected Unit, Integration, and Functional; excludes Journey
mix test.all          # Unit, Integration, Functional, Journey, and Node tests
```

Functional tests require their documented provider credentials and can send test inputs to external model providers. `mix test.fast` is the routine local feedback command; use `mix test.changed` only when the affected Functional boundary is intentionally available.

## What's in the library

The Jido glue:

- `JidoGralkor.Plugin` — `use Jido.Plugin, state_key: :__memory__, singleton: true`. Handles `ai.react.query` (planting session, agent, and selected ingestion Lens) and `ai.request.completed` / `ai.request.failed` (capture).
- `JidoGralkor.ReAct` — `maybe_force_memory_search/2` helper. Folds `tool_choice: %{type: "function", function: %{name: "memory_search"}}` into ReAct overrides on iteration 1; passes through unchanged on iterations 2+.
- `JidoGralkor.Canonical` — normalises a Jido/ReAct turn into the canonical `[%Gralkor.Message{role, content}]` shape.
- `JidoGralkor.Lifecycle` — `Jido.AgentServer.Lifecycle` impl whose sole job is the death-triggered flush.
- `JidoGralkor.ContextRotator` — synchronous `rotate_now/2` for in-life context consolidation.
- `JidoGralkor.Actions.MemorySearch` — the ReAct tool that always calls `Gralkor.Client.search/1` for the current operator, using optional Destination and Lens selectors from that invocation. It works before a thread is committed and short-circuits only a blank query.
- `JidoGralkor.Actions.MemoryAdd` — fire-and-forget ReAct tool.
- `JidoGralkor.Actions.MemoryBuildIndices` — admin tool. Description tells the LLM `DO NOT CALL` unless the user asked. Whole-graph index rebuild.
- `JidoGralkor.Actions.MemoryBuildCommunities` — admin tool. Same `DO NOT CALL` guard. Runs Graphiti community detection on this agent's `operator/<operator id>` graph.

The embedded Gralkor adapter (under `lib/gralkor/`):

- `Gralkor.Client` — adapter behaviour plus the public `ingest/1`, `replace/1`, and Destination-based `search/1` boundary.
- `Gralkor.Client.Native` — production adapter; wires `Recall`, `CaptureBuffer`, and `GraphitiPool`.
- `Gralkor.Client.InMemory` — test twin.
- `Gralkor.Destination` and `Gralkor.Destination.Registry` — first-class named graphs shared by Lenses and Reflections. The full agreed model is in [DESTINATIONS.md](DESTINATIONS.md).
- `Gralkor.Lens`, `Gralkor.Lens.Replaceable`, `Gralkor.Ingest`, `Gralkor.IngestedRepresentation`, `Gralkor.Replace`, `Gralkor.Graph`, `Gralkor.Search` — resolved ingestion models, completed-ingestion representation, and consumer request values.
- `Gralkor.Lens.Store` / `Gralkor.Lens.Storage.Graphiti` — append, replacement, and search capabilities for exact Destination graph identities.
- `Gralkor.Lens.Ingestion.Store` — the built-in straight-through ingestion process.
- `Gralkor.Reflection`, `Gralkor.Reflection.Registry`, `Gralkor.Reflection.ChainOfThought`, and `Gralkor.Reflection.Runner` — validated YAML declarations and synchronous, consumer-invoked synthesis.
- `Gralkor.Artefact`, `Gralkor.Artefact.ReturnHandler`, and `Gralkor.Destination.Storage` — producer-independent artefacts plus primitives the consumer uses to deliver return and Destination outputs.
- `Gralkor.Ontology` — compile-time DSL for declaring graphiti custom-entity ontologies (`entity`/`field`/`from`/verb macros).
- `Gralkor.Application`, `Gralkor.Python`, `Gralkor.GraphitiPool`, `Gralkor.CaptureBuffer`, `Gralkor.Recall`, `Gralkor.Distill`, `Gralkor.Format`, `Gralkor.Config`, and `Gralkor.Message` — the embedded capture, recall, and Graphiti pipelines.

The behavioural contract lives in [`test-trees/`](https://github.com/elimydlarz/jido_gralkor/tree/main/test-trees). Functional trees describe each application-visible feature, and the Journey tree describes the broad whole-application workflow. [`CLAUDE.md`](https://github.com/elimydlarz/jido_gralkor/blob/main/CLAUDE.md) carries the maintainer-facing mental model and project guidance.

## Publishing (maintainers)

`:jido_gralkor` is published to the public Hex registry as a package owned by the `elimydlarz` Hex user. Releases use that user's API key (`HEX_TOKEN`) loaded from the workspace `.env`; see the workspace `publish` skill for the full release flow.

```bash
$publish patch   # or minor | major | current
```

The skill runs the full suite before changing release state, verifies or transfers the package to personal ownership, lets trunk-sync synchronize the version commit and default branch, publishes through the personal Hex token, creates the lightweight `jido-gralkor-v<version>` tag through GitHub's API, and verifies both remote refs. Copy `.env.example` to `.env` and provide `HEX_TOKEN` plus a repository-scoped `GH_TOKEN` with Contents write permission.

## License

MIT.
