# jido_gralkor

Connect a [Jido](https://hex.pm/packages/jido) agent to [Gralkor](https://hex.pm/packages/gralkor) — a temporally-aware, knowledge-graph memory server (Graphiti + FalkorDB) — with a small set of drop-in modules. This is the entry point for Jido devs who want long-term memory: the library handles session identity, capture-on-completion, the `memory_search` / `memory_add` ReAct tools, and a tiny `RequestTransformer` helper that pins `tool_choice` to `memory_search` on the first ReAct iteration so the agent itself authors its memory queries. You write your agent's prompt, model, and business tools; `jido_gralkor` covers the memory wiring.

Two sibling packages are involved and both are required:

- **[`gralkor_ex`](https://hex.pm/packages/gralkor_ex)** — the memory server itself. Auto-supervises its own Python/FastAPI child; exposes a loopback HTTP API, plus the `Gralkor.Client` Elixir port + `HTTP` adapter + `InMemory` test twin + a `Connection` boot-readiness GenServer + an `OrphanReaper` for `mix start` abort-recovery. You supervise Gralkor — don't list `Gralkor.Server` as a child yourself, the `:gralkor_ex` application does that. See [gralkor_ex's docs](https://hexdocs.pm/gralkor_ex) for what the memory system is and how it works.
- **`jido_gralkor`** — this package. The Jido-shaped glue: one plugin + two actions that turn `Gralkor.Client` into a transparent memory layer on your Jido agent.

## Install

```elixir
def deps do
  [
    {:jido_gralkor, "~> 0.1"}
  ]
end
```

Then fetch:

```bash
mix deps.get
```

This transitively pulls `:jido`, `:jido_ai`, and `:gralkor_ex`.

## Required configuration

Three things the consumer must set up.

**1. A FalkorDB backend for `:gralkor_ex`.** `:gralkor_ex` runs Graphiti in-process via Pythonx and connects to FalkorDB either as an embedded `falkordblite` child or over the network. Pick one:

```bash
# Embedded — falkordblite spawns a redis-server grandchild under this dir
export GRALKOR_DATA_DIR=/var/lib/<your-app>/gralkor   # writable
export GOOGLE_API_KEY=...                              # or ANTHROPIC / OPENAI / GROQ
```

```elixir
# Remote — point at a managed FalkorDB. config/runtime.exs
config :gralkor_ex,
  falkordb: [
    host: System.fetch_env!("FALKORDB_HOST"),
    port: String.to_integer(System.fetch_env!("FALKORDB_PORT")),
    username: System.get_env("FALKORDB_USERNAME"),
    password: System.get_env("FALKORDB_PASSWORD")
  ]
```

Remote wins when both are set. Misconfigured `:falkordb` (non-keyword, missing host/port) raises `ArgumentError` at app start.

**2. In-memory client in tests.** Swap the adapter for the in-memory twin:

```elixir
# config/test.exs
config :gralkor_ex, client: Gralkor.Client.InMemory
```

And start the twin once in `test/test_helper.exs`:

```elixir
{:ok, _} = Gralkor.Client.InMemory.start_link()
ExUnit.start()
```

**3. `Jido.Thread.Plugin` on your `use Jido` supervisor.** The plugin reads `session_id` from `agent.state[:__thread__].id`, so the thread plugin must be active:

```elixir
defmodule MyApp.Jido do
  use Jido, default_plugins: [Jido.Thread.Plugin, Jido.Identity.Plugin]
end
```

`:gralkor_ex` auto-supervises its native runtime (Python → GraphitiPool → CaptureBuffer) when a FalkorDB backend is configured — no `Gralkor.Connection` to wire and no readiness gate to add. By the time `Application.start/2` returns, `Gralkor.Client` is ready.

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

       Each user message may be preceded by a <gralkor-memory> block
       listing facts and interpretation from earlier turns. Use it to
       answer naturally — the user does not see it. Call memory_search
       for deeper lookups and memory_add when you want to record a new
       insight explicitly.
       """},
    default_plugins: %{__memory__: false},
    plugins: [{JidoGralkor.Plugin, %{}}]
end
```

That's it. The plugin's `:__memory__` slot replaces Jido's built-in memory plugin. The plugin plants `:session_id` and `:agent_name` on the per-turn `tool_context` so `memory_search` can find them; recall itself is the LLM's job — call `JidoGralkor.ReAct.maybe_force_memory_search/2` from your strategy's `request_transformer` to pin `tool_choice` to `memory_search` on iteration 1 so the agent authors a focused query in-thread instead of the harness embedding raw user text. Capture still runs automatically on completion and failure: the ReAct event trace is normalised into Gralkor's canonical `{role, content}` message shape via `JidoGralkor.Canonical` — `user`, `behaviour` for thinking / tool calls / tool results, `assistant` for the final answer on completed turns, or a terminal `"request failed: …"` `behaviour` message on failed turns so the failure stays visible to downstream distillation.

## What happens at runtime

**Session identity.** `session_id` is the current Jido thread id (read from `agent.state[:__thread__].id`, populated by `Jido.Thread.Plugin`). The plugin does not mint its own identifier — Jido's thread lifecycle is the single source of truth. One Jido conversation thread per Gralkor session, so concurrent agents for the same principal never share a capture buffer, and the session rotates naturally when the thread rotates.

**Group partitioning.** `group_id` is `Gralkor.Client.sanitize_group_id(agent.id)` (hyphens replaced with underscores — a RediSearch constraint). Per-agent graph partition; agents never see each other's memory.

**First-turn bootstrap.** On the very first query of a fresh agent, `Jido.Thread.Plugin` hasn't yet committed a thread (the ReAct strategy's `ThreadAgent.append` runs inside `@start`, after the plugin hook). The plugin plants only `:agent_name` (no `:session_id`) and lets capture establish the session when the turn completes. `memory_search` called in that same first turn short-circuits with an explicit "did not run" non-result — the LLM is told the search did not run, so it can't read an empty payload as "no memory exists" and confidently lie. `memory_search` likewise short-circuits when invoked with a blank `query`, which protects forced-tool-call paths from the LLM emitting empty arguments.

**Ending a session.** When your app decides a conversation is over (e.g. user issues `/reset`), call `Gralkor.Client.impl().end_session(session_id)` directly — this flushes the server-side capture buffer for that session now instead of waiting for the idle window. `jido_gralkor` doesn't own session lifecycle; your agent's chat facade does.

**Fail-fast.** Gralkor errors raise. If `/recall` or `/capture` returns an error, the plugin raises and the caller sees it. Your supervision tree decides how to react.

**`memory_add` is async.** The tool returns `"Queued for storage."` immediately and does the HTTP call in a background `Task`. Graphiti's entity/edge extraction can take tens of seconds; you don't want the agent waiting. Failures are logged; best-effort storage is the contract.

## Testing against the in-memory twin

`Gralkor.Client.InMemory` is a real implementation of `Gralkor.Client` (not a mock) that stores canned responses and records every call. Your agent's integration tests can hit it without any network:

```elixir
setup do
  Gralkor.Client.InMemory.reset()
  :ok
end

test "agent recalls stored context" do
  Gralkor.Client.InMemory.set_recall({:ok, "<gralkor-memory>known fact</gralkor-memory>"})
  Gralkor.Client.InMemory.set_capture(:ok)
  # ... exercise your agent, assert on responses, inspect InMemory.recalls() / captures()
end
```

## What's in the library

- `JidoGralkor.Plugin` — `use Jido.Plugin, state_key: :__memory__, singleton: true`. Handles `ai.react.query` (recall) and `ai.request.completed` / `ai.request.failed` (capture). Stateless — `mount/2` returns `{:ok, nil}`.
- `JidoGralkor.Canonical` — translates a Jido/ReAct turn (user query + event trace + turn outcome `{:completed, answer}` or `{:failed, error}`) into Gralkor's canonical `[%Gralkor.Message{role, content}]` shape. Strips the `<gralkor-memory>…</gralkor-memory>` envelope the plugin prepended during recall, filters telemetry-only events, renders surviving `:llm_completed` / `:tool_completed` events as `behaviour` messages, and terminates the list with either an `assistant` answer (completed) or a `"request failed: …"` `behaviour` (failed). The server never sees Jido-shaped events; shape concerns live here.
- `JidoGralkor.Actions.MemorySearch` — `use Jido.Action, name: "memory_search"`. The ReAct tool. Short-circuits when no thread is committed yet.
- `JidoGralkor.Actions.MemoryAdd` — `use Jido.Action, name: "memory_add"`. Fire-and-forget.
- `JidoGralkor.Actions.MemoryBuildIndices` — admin tool. Description explicitly tells the LLM `DO NOT CALL` unless the user asked. Whole-graph index rebuild.
- `JidoGralkor.Actions.MemoryBuildCommunities` — admin tool. Same `DO NOT CALL` guard. Runs Graphiti community detection on this agent's partition.

Detailed behaviour lives in [`CLAUDE.md`](https://github.com/elimydlarz/jido_gralkor/blob/main/CLAUDE.md) under `## Test Trees`.

## Publishing (maintainers)

Run the script directly — it needs a real TTY for Hex's OTP prompt:

```bash
./scripts/publish.sh patch   # or minor | major | current
```

Bumps `@version` in `mix.exs`, runs `mix hex.publish --yes`, commits the bump, and tags `jido-gralkor-v<version>` locally. Push with `git push --follow-tags`.

## License

MIT.
