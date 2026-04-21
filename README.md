# jido_gralkor

Connect a [Jido](https://hex.pm/packages/jido) agent to [Gralkor](https://hex.pm/packages/gralkor) — a temporally-aware, knowledge-graph memory server (Graphiti + FalkorDB) — with three drop-in modules. This is the entry point for Jido devs who want long-term memory: the library handles session identity, recall-on-query, capture-on-completion, and the two ReAct tools the LLM calls for explicit lookup and recording. You write your agent's prompt, model, and business tools; `jido_gralkor` covers the memory wiring.

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

This transitively pulls `:jido`, `:jido_ai`, and `:gralkor_ex`.

## Required configuration

Four things the consumer must set up.

**1. Environment variables for `:gralkor_ex`.** The Gralkor server reads these when it boots (under its own supervisor inside the `:gralkor_ex` application):

```bash
export GRALKOR_DATA_DIR=/var/lib/<your-app>/gralkor   # required, writable
export GOOGLE_API_KEY=...                              # or ANTHROPIC / OPENAI / GROQ
# optional: GRALKOR_URL (default http://127.0.0.1:4000)
```

**2. App env for the `Gralkor.Client` HTTP adapter.** `jido_gralkor` calls `Gralkor.Client.impl/0` which resolves from `Application.get_env(:gralkor_ex, :client)` (defaults to `Gralkor.Client.HTTP`). The HTTP adapter reads its URL from `:gralkor_ex, :client_http`. Wire it in your `Application.start/2`:

```elixir
def start(_type, _args) do
  url = System.get_env("GRALKOR_URL", "http://127.0.0.1:4000")
  Application.put_env(:gralkor_ex, :client_http, url: url)
  # ...
end
```

In tests, swap the adapter for the in-memory twin:

```elixir
# config/test.exs
config :gralkor_ex,
  client: Gralkor.Client.InMemory,
  client_http: [url: "http://gralkor.test"]
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

**4. `Gralkor.Connection` in your supervision tree.** Blocks startup until the Python server responds healthy; sits idle afterwards.

```elixir
children = [
  Gralkor.Connection,   # before anything that will talk to Gralkor
  MyApp.Jido,
  # ...
]
```

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

That's it. The plugin's `:__memory__` slot replaces Jido's built-in memory plugin. Your agent now auto-recalls relevant facts before every LLM call, auto-captures every turn after completion (the ReAct event trace is normalised into Gralkor's canonical `{role, content}` message shape via `JidoGralkor.Canonical` — `user`, `behaviour` for thinking / tool calls / tool results, `assistant` for the final answer), and exposes `memory_search` / `memory_add` as callable tools.

## What happens at runtime

**Session identity.** `session_id` is the current Jido thread id (read from `agent.state[:__thread__].id`, populated by `Jido.Thread.Plugin`). The plugin does not mint its own identifier — Jido's thread lifecycle is the single source of truth. One Jido conversation thread per Gralkor session, so concurrent agents for the same principal never share a capture buffer, and the session rotates naturally when the thread rotates.

**Group partitioning.** `group_id` is `Gralkor.Client.sanitize_group_id(agent.id)` (hyphens replaced with underscores — a RediSearch constraint). Per-agent graph partition; agents never see each other's memory.

**First-turn bootstrap.** On the very first query of a fresh agent, `Jido.Thread.Plugin` hasn't yet committed a thread (the ReAct strategy's `ThreadAgent.append` runs inside `@start`, after the plugin hook). The plugin passes the signal through unchanged and lets capture establish the session when the turn completes. `memory_search` called in that same first turn short-circuits with an explicit "did not run" non-result — the LLM is told the search did not run, so it can't read an empty payload as "no memory exists" and confidently lie.

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
- `JidoGralkor.Canonical` — translates a Jido/ReAct turn (user query + event trace + assistant answer) into Gralkor's canonical `[%Gralkor.Message{role, content}]` shape. Strips the `<gralkor-memory>…</gralkor-memory>` envelope the plugin prepended during recall, filters telemetry-only events, and renders surviving `:llm_completed` / `:tool_completed` events as `behaviour` messages. The server never sees Jido-shaped events; shape concerns live here.
- `JidoGralkor.Actions.MemorySearch` — `use Jido.Action, name: "memory_search"`. The ReAct tool. Short-circuits when no thread is committed yet.
- `JidoGralkor.Actions.MemoryAdd` — `use Jido.Action, name: "memory_add"`. Fire-and-forget.
- `JidoGralkor.Actions.MemoryBuildIndices` — admin tool. Description explicitly tells the LLM `DO NOT CALL` unless the user asked. Whole-graph index rebuild.
- `JidoGralkor.Actions.MemoryBuildCommunities` — admin tool. Same `DO NOT CALL` guard. Runs Graphiti community detection on this agent's partition.

Detailed behaviour lives in [`CLAUDE.md`](https://github.com/elimydlarz/jido_gralkor/blob/main/CLAUDE.md) under `## Test Trees`.

## License

MIT.
