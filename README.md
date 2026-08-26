# jido_gralkor

Drop-in long-term memory for a [Jido](https://hex.pm/packages/jido) agent. One Hex package: the Jido plugin and ReAct tools on top of an embedded Gralkor memory adapter — Graphiti driven directly from the BEAM via [Pythonx](https://github.com/livebook-dev/pythonx), with no separate Gralkor service to deploy. Storage uses either an embedded FalkorDB child or a remote FalkorDB deployment.

You write your agent's prompt, model, and business tools. `jido_gralkor` covers session identity, recall, capture, the `memory_search` / `memory_add` ReAct tools, a small helper that pins `tool_choice` to `memory_search` on the first ReAct iteration so the agent itself authors its memory queries, a graceful-shutdown flush, a context-rotation primitive for long-running agents, **Destinations** for named memory placement and extraction, **Lenses** for ingestion, and **Reflections** for asynchronous post-ingestion synthesis.

This is the canonical home for new Gralkor development: Gralkor is Jido-first. As of `3.0.0` the former `:gralkor_ex` Hex package is folded into this one, and the legacy `:gralkor` and `:gralkor_ex` packages direct consumers here. Consumers need only `{:jido_gralkor, "~> 7.0"}` for the whole memory stack.

## Install

```elixir
def deps do
  [
    {:jido_gralkor, "~> 7.0"}
  ]
end
```

Then fetch:

```bash
mix deps.get
```

The package requires Elixir `~> 1.18` and has runtime dependencies on `:jido`, `:jido_ai`, `:pythonx`, `:req_llm`, `:jason`, and `:yaml_elixir`. On the first native-runtime boot, Pythonx materialises a managed Python 3.12 environment with `graphiti-core` and `falkordblite`; consumers do not install Python themselves, but the boot needs package-download access and a writable cache.

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

**2. In-memory client in tests.** Swap the adapter for the in-memory twin:

```elixir
# config/test.exs
config :jido_gralkor,
  client: Gralkor.Client.InMemory,
  destination_storage: Gralkor.Destination.Storage.InMemory,
  lens_storage: Gralkor.Lens.Storage.InMemory,
  reflection_storage: Gralkor.Reflection.Storage.InMemory
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
  start_supervised!(Gralkor.Reflection.Storage.InMemory)
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

`:jido_gralkor` auto-supervises its native runtime (Python → GraphitiPool → CaptureBuffer) when a FalkorDB backend is configured — no separate `Gralkor.Server` to wire into your supervision tree, and no readiness gate to add. By the time `Application.start/2` returns, `Gralkor.Client` is ready.

## Configuration reference

Everything `:jido_gralkor` reads, in one place. Nothing else is configurable — Python, the venv, and the Graphiti client are internal concerns with no consumer-facing knobs.

### Application environment (`config :jido_gralkor, …`)

| Key | Type | Default | What it does |
| --- | --- | --- | --- |
| `:falkordb` | keyword: `:host`, `:port`, optional `:username`, `:password`, `:ssl` | unset | Remote FalkorDB connection. Wins over the embedded backend when both are set. `:ssl` defaults to `false`. Invalid shape raises `ArgumentError` at app start. See [Required configuration](#required-configuration). |
| `:destinations` | list of keyword definitions | packaged `operator`, `experiential-learning`, and `generalisations` Destinations | The Destination registry. Each application definition has `:name`, an `operator/path` or `global/path` `:address`, and optional `:ontology` (default `Gralkor.DefaultOntology`). See [Destinations](DESTINATIONS.md). |
| `:lenses` | list of keyword definitions | `[]` | The Lens registry. Appending Lenses use `:name`, `:destination`, and `:ingestion`, with optional `write: :append`; replaceable Lenses use `:name`, `:destination`, `write: :replace_graph`, and `:graph_format`. Blank, duplicate, reserved (`"operator"`, `"global"`), retired (`"default"`), or malformed definitions raise. See [Configure Lenses](#configure-lenses). |
| `:client` | module implementing `Gralkor.Client` | `Gralkor.Client.Native` | The adapter. Set to `Gralkor.Client.InMemory` in tests; that value also suppresses the native supervision tree (Pythonx → GraphitiPool → CaptureBuffer). |
| `:lens_storage` | module | `Gralkor.Lens.Storage.Graphiti` | Physical storage behind `Gralkor.Lens.Store`. Set to `Gralkor.Lens.Storage.InMemory` in tests — pinning `:client` alone does **not** intercept `Client.ingest/1`, `replace/1`, or `search/1`. |
| `:destination_storage` | module | `Gralkor.Destination.Storage.Graphiti` | Search storage behind `Client.search/1`. Set to `Gralkor.Destination.Storage.InMemory` in tests. |
| `:reflections` | list of keyword definitions | built-in `generalisations` and `erl` declarations | The Reflection registry. Each definition has a unique non-blank `:name`, a registered `:destination`, and a repository-relative YAML `:chain_of_thought` path. Supplying the key replaces the built-in declarations. See [Configure Reflections](#configure-reflections). |
| `:reflection_root` | path | application package root | Root used to resolve Reflection YAML paths. The default makes the packaged `priv/reflections/*.yaml` files work after installation; set it when an application keeps custom CoTs under another repository directory. |
| `:reflection_storage` | module | `Gralkor.Reflection.Storage.Graphiti` | Physical storage behind `Gralkor.Reflection.Store`. Tests can use `Gralkor.Reflection.Storage.InMemory`; Destination search should then use its in-memory adapter too. |
| `:recall_deadline_ms` | positive integer | `12_000` | Wall-clock budget for a whole recall search and presentation. On expiry the recall task is killed and `recall/4` returns `{:error, :recall_deadline_expired}`. |
| `:test` | boolean | `false` | Verbose diagnostic logging: recall queries, returned facts, and flushed capture bodies are written to the log. Debugging aid — leave it off in production, where it would log memory contents. |

```elixir
# config/runtime.exs — everything optional, shown with its default
config :jido_gralkor,
  recall_deadline_ms: 12_000
```

The implicit `"operator"` Lens and legacy `capture/5`, `memory_add/3`, and `recall/4` need no ontology configuration. They use the packaged operator Destination and its library-owned `Gralkor.DefaultOntology`. Application-specific extraction schemas belong on registered Destinations referenced by named Lenses or Reflections.

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
| `:ingestion_lens` | no | unset (implicit-operator mode) | Registered Lens name receiving `memory_add` and automatic capture. Required as soon as any other Lens option is given. The removed `:default_lens` option raises and identifies this replacement. |
| `:search_destinations` | no | `[]` | Registered Destination names searched by `memory_search`. An empty list selects the packaged operator-memory and global-generalisations Destinations. |

Per-turn, `tool_context[:lens]` overrides `:ingestion_lens` for that query; the plugin retains the selection on the request's thread entry so later capture stays bound to it.

### `JidoGralkor.ContextRotator.rotate_now/2`

| Option | Default | What it does |
| --- | --- | --- |
| `:flush_timeout_ms` | `30_000` | How long the synchronous pre-rotation flush may take. |
| `:keep_last_n` | `4` | Most-recent pre-flush thread entries seeded into the rotated thread. `0` drops everything that existed before the flush; turns that land during the flush are always carried over. |

## A complete configuration

Everything above, in one deployment. Three files.

**Ontologies are modules referenced by Destinations.** Define an ontology as ordinary compiled Elixir in your own `lib/`, then reference its module from each Destination that should extract with it. Lenses and Reflections reference those Destinations by name; neither repeats the ontology or address.

```elixir
# lib/my_app/ontologies.ex — compiled code. Named by Destination definitions below.
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

  destinations: [
    [name: "observations", address: "operator/observations", ontology: MyApp.Ontology],
    [name: "decisions", address: "operator/decisions", ontology: MyApp.Ontology],
    [name: "release-knowledge", address: "global/release-knowledge"]
  ],

  # The Lens registry selects ingestion behavior and a Destination.
  lenses: [
    [
      name: "observations",
      destination: "observations",
      ingestion: Gralkor.Lens.Ingestion.Store
    ],
    [
      name: "decisions",
      destination: "decisions",
      ingestion: MyApp.DecisionIngestion
    ]
  ],

  # Optional custom Reflection declarations. Omit this key to use the two
  # packaged declarations shown here.
  reflections: [
    [
      name: "generalisations",
      destination: "generalisations",
      chain_of_thought: "priv/reflections/generalisations.yaml"
    ],
    [
      name: "erl",
      destination: "experiential-learning",
      chain_of_thought: "priv/reflections/erl.yaml"
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
     ingestion_lens: "observations",
     search_destinations: ["decisions", "generalisations"]
   }}
]
```

That mount writes captured turns and `memory_add` calls through the `"observations"` Lens to its Destination, and concurrently searches the selected `"decisions"` and `"generalisations"` Destinations. After a flushed ingestion has completed across its intended Lenses, each declared Reflection is scheduled independently over the completed lensed representations.

**Ontology placement.** The packaged operator Destination uses Jido Gralkor's open `Gralkor.DefaultOntology`; packaged experiential learning uses `Gralkor.Reflection.ERLOntology`. Applications attach custom ontology modules to explicitly registered Destinations. If an older deployment set `config :jido_gralkor, :ontology`, remove it and create a named Destination referenced by a Lens or Reflection instead.

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
         ingestion_lens: "observations",
         search_destinations: ["observations", "generalisations"]
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

The plugin claims Jido's `:__memory__` slot. On `ai.react.query`, it plants `:session_id` (when a thread is committed), `:agent_name`, the selected `:lens`, and `:search_destinations` on the signal's `tool_context`. Recall itself is the LLM's job — `JidoGralkor.ReAct.maybe_force_memory_search/2` is the cheapest way to force it on iteration 1. Capture runs automatically on completion and failure: the ReAct event trace is normalised into Gralkor's canonical `[%Gralkor.Message{role, content}]` shape via `JidoGralkor.Canonical` — `user` for the user query, `behaviour` for intermediate thinking / tool calls / tool results, `assistant` for the final answer on completed turns, or a terminal `"request failed: …"` `behaviour` on failed turns so the failure stays visible to downstream distillation.

Set `tool_context[:lens]` on an individual query to override `ingestion_lens` for that turn. The plugin retains the selection on the request's Jido thread entry, making it authoritative for both `memory_add` and later completion or failure capture after ReAct has released its transient tool context. The host strategy's configured tools and complete tool context are carried into post-ingestion Reflection execution.

The plugin reads `user_name` per-turn from `agent.state[:user_name]`. Populate it before each request (for example, via `on_before_cmd/2` from the signal's `tool_context`) so distill renders user lines under the correct human identity. Missing and blank names raise; there is no generic fallback.

## What happens at runtime

**Session identity.** `session_id` is the current Jido thread id (read from `agent.state[:__thread__].id`, populated by `Jido.Thread.Plugin`). The plugin does not mint its own identifier — Jido's thread lifecycle is the single source of truth.

**Destinations.** Every Lens and Reflection references a registered Destination. Its `operator/path` or `global/path` address resolves the Graphiti graph ID, and its ontology governs extraction. Multiple Lenses and Reflections may save to the same Destination. Replacement writes inject `_gralkor_lens` into supplied nodes and relationships so a replaceable Lens changes only its own content at that Destination.

**Post-ingestion Reflections.** A successful flush first completes every intended Lens ingestion and retains the actual zero, one, or many outputs each Lens stored, with a shared evidence identifier linking representations of the same submitted information. When at least one representation was stored, the declared Reflections are then scheduled asynchronously. Each Reflection runs independently, so one failure does not prevent another from completing or storing its artefact.

**First-turn bootstrap.** On the very first query of a fresh agent, the thread isn't yet committed (the ReAct strategy's `ThreadAgent.append` runs after the plugin hook). The plugin plants `:agent_name` plus configured `:lens` and `:search_destinations`, but no `:session_id`; completed and failed turn capture are both skipped with a warning until a committed thread supplies that identity. `memory_search` called in that same first turn short-circuits with an explicit "did not run" non-result so the LLM cannot read an empty payload as "no memory exists" and confidently lie.

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

A Lens is an application-owned memory ingestion channel that targets a Destination. The Destination owns the `operator/path` or `global/path` address and ontology. A Lens's write mode is either append, which sends content through an ingestion process, or whole-graph replacement, which replaces the graph content for its Destination.

Appending is the default write mode. An appending Lens names its Destination and the ingestion process Gralkor invokes when content is sent through it; `write: :append` may be stated explicitly or omitted.

The ontology is a module you compile into your own application — declared once in `lib/`, then named by each Destination that should extract with it:

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

Register Destinations first, then point as many Lenses as your application needs at them. Several Lenses may use the same Destination:

```elixir
# config/runtime.exs
config :jido_gralkor,
  destinations: [
    [name: "observations", address: "operator/observations", ontology: MyApp.Ontology],
    [name: "decisions", address: "operator/decisions", ontology: MyApp.Ontology],
    [name: "systems", address: "operator/systems", ontology: MyApp.Ontology]
  ],
  lenses: [
    [
      name: "observations",
      destination: "observations",
      ingestion: Gralkor.Lens.Ingestion.Store
    ],
    [
      name: "decisions",
      destination: "decisions",
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
      destination: "systems",
      write: :replace_graph,
      graph_format: :property_graph
    ]
  ]
```

Destination addresses control visibility: `operator/path` resolves a separate graph for each operator, while `global/path` resolves the same graph for every operator.

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

The callback receives the original `%Gralkor.Ingest{}` request and a Lens-bound `%Gralkor.Lens.Store{}`. It decides whether to make zero, one, or many writes and can use `Gralkor.Lens.Store.add/3` and `search/3`. The selected Destination supplies the graph address and ontology. `Client.ingest/1` accepts appending Lenses and raises for replaceable Lenses; `Client.replace/1` accepts replaceable Lenses and raises for appending Lenses.

The plugin mount chooses how an agent uses the registered Lenses:

```elixir
{JidoGralkor.Plugin,
 %{
   agent_name: "Susu",
   ingestion_lens: "observations",
   search_destinations: ["observations", "generalisations"]
 }}
```

- `ingestion_lens` receives `memory_add` calls and automatic capture unless a turn supplies `tool_context[:lens]`.
- `search_destinations` is an optional list of registered Destination names. An empty list searches the packaged `"operator"` and `"generalisations"` Destinations.

Consumers that ingest, replace, or search outside an agent call the same public boundary directly:

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
    destinations: ["decisions", "generalisations"],
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

Search names Destinations directly. Searches run concurrently while results retain configured Destination order. `max_results` defaults to `20`, must be a positive integer, and applies independently to every Destination. Result types are `:facts`, `:nodes`, `:episodes`, and `:artefacts`; each returned item identifies its Destination. Node searches accept `entity_types`, fact searches accept `edge_types`, and artefact searches may narrow by `artefact_id`. The `memory_search` action returns the attributed list as JSON.

`:property_graph` is the supported replacement format. Every node requires a unique, non-blank string `:id`, a list of non-blank string `:labels`, and a `:properties` map. Every relationship requires `:from` and `:to` identifiers naming supplied nodes, a non-blank string `:type`, and a `:properties` map. This payload is the whole current graph for the Lens; partial node and relationship operations are not supported.

Replacement changes only content owned by that Lens at its Destination. Gralkor overwrites any supplied `_gralkor_lens` property with the selected Lens name on every inserted node and relationship. Content saved through another Lens or Reflection, or carrying no Lens ownership, remains unchanged. An empty graph removes all graph content owned by the selected Lens. The supplied graph format must match the Lens's configured `:graph_format`.

Invalid Lens names, write modes, formats, and graph data raise `ArgumentError`; graph data is fully validated before storage mutation begins. Once a valid replacement starts, deletion and insertion are not transactional: an import error is returned, and content already removed or inserted is not rolled back.

Registry and plugin configuration fail fast for blank, duplicate, reserved, retired, or malformed Lens definitions and for unknown Lens names. The retired `"default"` Lens name raises with guidance to use `"operator"`; it is not an alias. If no Lens configuration is used, the implicit `"operator"` Lens preserves the existing operator group and uses Jido Gralkor's built-in generic extraction contract.

### Ontology DSL

Each Destination ontology is a module declared with `Gralkor.Ontology`:

- `entity Foo do field … end` declares an entity. `field :name, :type, opts` supports `:string | :integer | :float | :boolean`, plus `required: true` and `doc:` (rendered as the Pydantic field description).
- `entity Foo, "when to extract one" do … end` adds a description, rendered as the extracted type's own description. Graphiti's extractor reads it to decide when to mint the entity, so a type whose name alone is ambiguous — `Preference`, `Pattern`, `Learning` — is extracted far more reliably with one. The description must be a literal string.
- `from Source do verb Target [do field … end] end` declares outgoing relationships from `Source`. The verb's name becomes the edge type in graphiti (`prefers` → `"PREFERS"`, `relates_to` → `"RELATES_TO"`). The optional `do` block carries edge properties.
- Same verb in multiple `from` blocks becomes one edge type with multiple endpoint pairs.
- `entities: :strict` excludes graphiti's generic `Entity` extraction — only your declared types survive. `entities: :open` lets graphiti extract generic Entity nodes alongside yours.
- `relationships: :scoped` populates graphiti's `edge_type_map` from your declared `(src, dst)` pairs, so named edges only fire between declared endpoints. `relationships: :open` drops the map; graphiti's default applies. Either way, graphiti always extracts edge candidates — generic fall-through edges between unconstrained pairs are not closed off.
- Both opts are required at `use` — no defaults; pick deliberately.

**Protected field names.** Entity and edge *type* names are unrestricted — pick whatever suits your domain. Field names are not: graphiti rejects any custom entity attribute whose name collides with a field on its own `EntityNode`, namely `uuid`, `name`, `group_id`, `labels`, `created_at`, `summary`, `attributes`, and `name_embedding`. The DSL does not currently catch this at compile time, so `field :name, :string` compiles and then raises `EntityTypeValidationError` from Python on the first write through the Lens that selected the ontology. Name fields for what they hold — `handle`, `title`, `statement` — rather than reaching for `name` or `summary`.

On each store write, graphiti receives the selected Destination ontology's `entity_types`, `edge_types`, `edge_type_map`, and `excluded_entity_types`, translated from the module's compile-time payload.

## Configure Reflections

A Reflection is an asynchronous post-ingestion process over completed lensed representations. It is declared by name, registered Destination, and a repository YAML Chain of Thought. Reflections are not Lenses: Lens definitions remain independent views for absorbing information, while Reflections operate over the successful results after every intended Lens has finished.

The package supplies two declarations by default:

- `generalisations` uses `priv/reflections/generalisations.yaml` and the packaged `generalisations` Destination at `global/generalisations`.
- `erl` uses `priv/reflections/erl.yaml` and the packaged `experiential-learning` Destination at `operator/experiential-learning`. That Destination carries `Gralkor.Reflection.ERLOntology`, whose `Learning` entity declares optional `problem_kind`, `approach`, `success`, and `lesson` fields.

Set `:reflections` to replace those defaults with application declarations, and set `:reflection_root` when their YAML paths resolve from somewhere other than the installed application root. A Reflection's Destination ontology governs extraction, whether it is the generic default or an application schema.

```elixir
config :jido_gralkor,
  reflection_root: File.cwd!(),
  reflections: [
    [
      name: "release-review",
      destination: "release-knowledge",
      chain_of_thought: "priv/reflections/release-review.yaml"
    ]
  ]
```

Each YAML file contains an ordered, non-empty `steps` list. A step declares a `label`, natural-language `directions`, and an exact structured `output` schema. Later directions may interpolate prior outputs with `{{output_name}}`. At runtime each step receives the completed ingestion's lensed representations, the host agent's tools, and its full tool context. The model may direct tool calls described by the custom directions; tool results return to the same step before it produces its structured output. That output is validated exactly, made available to later interpolation, and the final step becomes one stored `%Gralkor.Reflection.Artefact{}` with its supporting evidence identifiers.

Multiple Reflections and Lenses may save to the same Destination. Search selects Destinations directly:

```elixir
{:ok, artefacts} =
  Gralkor.Client.search(%Gralkor.Search{
    operator_id: "operator-42",
    query: "What release approaches have worked?",
    destinations: ["experiential-learning"],
    result_type: :artefacts,
    max_results: 20
  })

{:ok, [artefact]} =
  Gralkor.Client.search(%Gralkor.Search{
    operator_id: "operator-42",
    query: "",
    destinations: ["experiential-learning"],
    result_type: :artefacts,
    artefact_id: "reflection-123"
  })
```

`result_type: :artefacts` returns final Reflection artefacts from the selected Destinations, and `artefact_id` optionally narrows the lookup to one exact artefact. Each artefact carries its declaring Reflection.

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

- `JidoGralkor.Plugin` — `use Jido.Plugin, state_key: :__memory__, singleton: true`. Handles `ai.react.query` (planting session, agent, selected Lens, and Destinations to search) and `ai.request.completed` / `ai.request.failed` (capture).
- `JidoGralkor.ReAct` — `maybe_force_memory_search/2` helper. Folds `tool_choice: %{type: "function", function: %{name: "memory_search"}}` into ReAct overrides on iteration 1; passes through unchanged on iterations 2+.
- `JidoGralkor.Canonical` — normalises a Jido/ReAct turn into the canonical `[%Gralkor.Message{role, content}]` shape.
- `JidoGralkor.Lifecycle` — `Jido.AgentServer.Lifecycle` impl whose sole job is the death-triggered flush.
- `JidoGralkor.ContextRotator` — synchronous `rotate_now/2` for in-life context consolidation.
- `JidoGralkor.Actions.MemorySearch` — the ReAct tool that calls `Gralkor.Client.search/1` for configured Destinations and falls back to legacy `recall/4` in implicit-operator plugin mode. It short-circuits when no thread is committed or the query is blank.
- `JidoGralkor.Actions.MemoryAdd` — fire-and-forget ReAct tool.
- `JidoGralkor.Actions.MemoryBuildIndices` — admin tool. Description tells the LLM `DO NOT CALL` unless the user asked. Whole-graph index rebuild.
- `JidoGralkor.Actions.MemoryBuildCommunities` — admin tool. Same `DO NOT CALL` guard. Runs Graphiti community detection on this agent's group.

The embedded Gralkor adapter (under `lib/gralkor/`):

- `Gralkor.Client` — adapter behaviour plus the public `ingest/1`, `replace/1`, and Destination-based `search/1` boundary.
- `Gralkor.Client.Native` — production adapter; wires `Recall`, `CaptureBuffer`, and `GraphitiPool`.
- `Gralkor.Client.InMemory` — test twin.
- `Gralkor.Destination` and `Gralkor.Destination.Registry` — first-class named addresses and extraction ontologies shared by Lenses and Reflections. The full agreed model is in [DESTINATIONS.md](DESTINATIONS.md).
- `Gralkor.Lens`, `Gralkor.Lens.Replaceable`, `Gralkor.Ingest`, `Gralkor.IngestedRepresentation`, `Gralkor.Replace`, `Gralkor.Graph`, `Gralkor.Search` — resolved ingestion models, completed-ingestion representation, and consumer request values.
- `Gralkor.Lens.Store` / `Gralkor.Lens.Storage.Graphiti` — append, replacement, and search capabilities with collision-safe local/shared-global Graphiti placement.
- `Gralkor.Lens.Ingestion.Store` — the built-in straight-through ingestion process.
- `Gralkor.Reflection`, `Gralkor.Reflection.Registry`, `Gralkor.Reflection.ChainOfThought`, `Gralkor.Reflection.Runner`, and `Gralkor.Reflection.Scheduler` — validated YAML declarations and asynchronous ordered execution after completed Lens ingestion.
- `Gralkor.Reflection.Artefact`, `Gralkor.Reflection.Store`, and the Graphiti/InMemory Reflection storage modules — exactly-one-artefact persistence at referenced Destinations.
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
