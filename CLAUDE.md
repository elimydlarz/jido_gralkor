# jido_gralkor

Jido-side adapter for the Gralkor memory server. Ships three modules that let any Jido agent use Gralkor without reimplementing the plumbing.

## Mental Model

- **`JidoGralkor.Plugin`** — `use Jido.Plugin, name: "gralkor", state_key: :__memory__, singleton: true, actions: []`. Claims the `:__memory__` slot. Does recall on `ai.react.query` (prepends any returned memory block to the query; plants `session_id` on `tool_context`) and capture on `ai.request.completed` / `ai.request.failed`. For capture, the plugin hands the user query, the full ReAct event trace, and a turn outcome — `{:completed, answer}` or `{:failed, error}` — to `JidoGralkor.Canonical.to_messages/3`, which normalises the turn into Gralkor's canonical `[%Gralkor.Message{role, content}]` shape (roles: `"user" | "assistant" | "behaviour"`). That list is what gets sent to Gralkor — the server has no opinion about Jido-shaped events. The two signal types are handled by separate `handle_signal` clauses that pattern-match their payload shape (`:result` vs `:error`); malformed signals fall through to the catchall. `session_id` is the current Jido thread id (read from `agent.state[:__thread__].id`, populated by `Jido.Thread.Plugin`) — the plugin does not mint its own identifier. `group_id` is `Gralkor.Client.sanitize_group_id(agent.id)` (per-principal memory partition). No plugin state — `mount/2` returns `{:ok, nil}`. Gralkor errors raise so callers see them per fail-fast. Consumers must mount `Jido.Thread.Plugin` on their `use Jido` supervisor; otherwise there's no thread id to read.
- **`JidoGralkor.Canonical`** — the adapter-only module that translates a Jido/ReAct turn into Gralkor's canonical message shape. Strips the `<gralkor-memory>…</gralkor-memory>` envelope the plugin itself prepended during recall (so recalled facts don't leak into episodes), filters events that aren't memory-worthy, and renders surviving `:llm_completed` / `:tool_completed` events as `behaviour` messages with content the distillation LLM can read (`"thought: …"`, `"tool NAME → RESULT"`). The turn outcome terminates the message list: `{:completed, answer}` becomes the trailing `"assistant"` message; `{:failed, error}` becomes a terminal `"behaviour"` message `"request failed: …"` so the failure is visible to downstream distillation rather than silently swallowed. Returns `[]` when nothing is worth persisting; the plugin uses that to skip the capture call entirely.
- **`JidoGralkor.Actions.MemorySearch`** — `use Jido.Action, name: "memory_search"`. The ReAct tool. Reads `session_id` from `context[:session_id]` (planted by the plugin on `ai.react.query` — the Jido thread id) and derives `group_id` from `context[:agent_id]`. If `session_id` is absent or blank (LLM called the tool on the very first query of a fresh agent, before the strategy committed a thread), short-circuits with an explicit "did not run" non-result message without calling the client. Otherwise calls `Gralkor.Client.impl().memory_search/3`; propagates `{:error, reason}` on client failure.
- **`JidoGralkor.Actions.MemoryAdd`** — `use Jido.Action, name: "memory_add"`. Fire-and-forget ReAct tool: spawns a `Task` that calls `Gralkor.Client.impl().memory_add/3` and logs on failure; returns `{:ok, %{result: "Queued for storage."}}` immediately. The server-side write invokes Graphiti entity/edge extraction (LLM + graph update, tens of seconds) — far longer than the agent should wait before replying, and Jido has no native async tool calls.

## Dependencies

Two direct Hex deps (three with `:ex_doc` for dev docs):

- `{:jido, "~> 2.2"}` — `Jido.Plugin`, `Jido.Action`, `Jido.Signal` (struct + pattern match).
- `{:jido_ai, "~> 2.1"}` — `Jido.AI.Request.get_request/2` (used once in the plugin to look up the user query for a completed `request_id`).
- `{:gralkor_ex, "~> 1.3"}` — `Gralkor.Client` (behaviour + `sanitize_group_id/1` + `impl/0` resolver). The plugin calls `recall/3` + `capture/3`; actions call `memory_search/3` + `memory_add/3` + `build_indices/0` + `build_communities/1`. `end_session/1` and `health_check/0` are not used here — consumers call those directly from their own agent lifecycle / supervision tree.

## Testing

Test trees use `Gralkor.Client.InMemory` (shipped in `lib/` of `:gralkor_ex`) as the client. `config/test.exs` sets `config :gralkor_ex, client: Gralkor.Client.InMemory`; `test_helper.exs` starts the GenServer once globally. Tests call `InMemory.reset/0` in `setup` and configure canned responses per scenario.

```bash
mix test          # all tests (excludes :integration and :functional by default)
mix test.unit
mix test.integration
mix test.functional
```

## Test Trees

### Plugin

```
JidoGralkor.Plugin
  then the session_id is the Jido thread id read from agent.state[:__thread__].id — the plugin does not mint its own id (no ULID at mount, no agent-lifecycle token); Jido's thread lifecycle is the single source of truth
  then mount/2 returns {:ok, nil} — the plugin holds no state of its own
  when an agent turn begins
    then Gralkor is asked to recall memory for the agent's group_id and the thread's session_id with the query
    then the thread's session_id is planted on the signal's tool_context for downstream tool calls
    when recall returns a memory block
      then the turn's query is enriched by prepending the memory block
    when recall returns nothing
      then the turn's query passes through unchanged aside from the injected session_id
    if recall fails
      then the callback raises so the caller sees the real error
    when the agent has no committed thread yet (first query on a fresh agent — ReAct strategy's ThreadAgent.append runs inside @start, after plugin hooks)
      then recall is skipped and the signal passes through unchanged (no session_id is fabricated)
      and a Logger.warning is emitted naming the agent id and pointing at the upstream
        jido_ai fix (susu-2 JIDO_CHANGE_SUGGESTIONS.md §2) — once that lands, this skip
        path and its warning both go away
  when an agent turn completes
    then the user query, event trace, and `{:completed, answer}` outcome are normalised via
      `JidoGralkor.Canonical.to_messages/3` and the resulting canonical message list is sent to
      Gralkor for capture with the thread's session_id and the principal's group_id
    when the turn's query was enriched with a recalled memory block earlier in the turn (so
      `Request.query` starts with `<gralkor-memory>…</gralkor-memory>\n\n…`)
      then the captured user content strips that prefix so the episode body records the user's
        original request rather than Gralkor's recall output round-tripping back through Graphiti
        extraction
  when an agent turn fails
    then the user query, event trace, and `{:failed, error}` outcome are normalised via
      `JidoGralkor.Canonical.to_messages/3` and the resulting canonical message list — ending in
      a `"request failed: …"` behaviour message instead of an assistant message — is sent to
      Gralkor for capture, so the failure is visible to downstream distillation rather than
      silently dropped
    when the agent has no committed thread yet (first-turn failure)
      then capture is skipped
      and a Logger.warning is emitted naming the agent id and pointing at the upstream
        jido_ai fix (susu-2 JIDO_CHANGE_SUGGESTIONS.md §2)
  when the completed turn has no events in its request trace
    then no capture is sent (simple chit-chat turns with no tool usage don't populate memory)
  if capture fails
    then the callback raises
```

### Canonical

```
JidoGralkor.Canonical.to_messages/3
  when both the user query and the assistant answer are empty and there are no events
    then returns []
  when the user query wraps a <gralkor-memory>…</gralkor-memory> envelope
    then the envelope is stripped before the user message is emitted
  when the events contain a :llm_completed event
    then a behaviour message with "thought: <text>" is emitted, preserving order
  when the events contain a :tool_completed event
    then a behaviour message with "tool <name> → <result>" is emitted, preserving order
  when the events contain an unknown :kind
    then that event is ignored (telemetry-only signals don't become memory)
  when the assistant answer is empty
    then no trailing assistant message is emitted
  when the assistant answer is present
    then the final message is an assistant-role message with the trimmed answer
  then messages are ordered user → behaviour(s) → assistant
  when an LLM event carries Anthropic-style list-shaped content blocks
    then the text blocks are concatenated with spaces into the rendered "thought: …" message
```

### Actions.MemorySearch

```
JidoGralkor.Actions.MemorySearch
  when invoked with session_id in context
    then group_id is derived from context.agent_id via Gralkor.Client.sanitize_group_id/1 and session_id is passed straight through to the client
  when invoked without a session_id (or with a blank one) in context
    then the client is not called and the action returns {:ok, %{result: <non-result message>}} where the message explicitly tells the LLM the search did not run (vs. ran-and-found-nothing), so the LLM can't read an empty payload as "no memory exists" and confidently lie
    and a Logger.warning is emitted naming the agent id and pointing at the upstream
      jido_ai fix (susu-2 JIDO_CHANGE_SUGGESTIONS.md §2)
  when the client returns {:ok, text}
    then the action result is %{result: text}
  when the client returns {:error, reason}
    then the action returns {:error, reason} (propagated)
```

### Actions.MemoryAdd

```
JidoGralkor.Actions.MemoryAdd
  when invoked
    then the action returns {:ok, %{result: "Queued for storage."}} without waiting on the client
    then the client's memory_add is called in a background Task with the sanitized group_id, content, and source_description
  if the background Task's client call fails
    then the failure is logged (best-effort storage)
```

### Actions.MemoryBuildIndices

```
JidoGralkor.Actions.MemoryBuildIndices
  then the action's description tells the LLM DO NOT CALL unless the user has explicitly asked to rebuild Gralkor's graph indices (operator-maintenance action)
  when invoked
    then Gralkor.Client.impl().build_indices/0 is called (whole-graph, no arguments)
    when the client returns {:ok, %{status: status}}
      then the action result reports success with the status string
    when the client returns {:error, reason}
      then the action returns {:error, reason} (propagated)
```

### Actions.MemoryBuildCommunities

```
JidoGralkor.Actions.MemoryBuildCommunities
  then the action's description tells the LLM DO NOT CALL unless the user has explicitly asked to build Gralkor communities (expensive operator-maintenance action)
  when invoked
    then group_id is derived from context.agent_id via Gralkor.Client.sanitize_group_id/1
    then Gralkor.Client.impl().build_communities/1 is called with that group_id
    when the client returns {:ok, %{communities: c, edges: e}}
      then the action result reports the community and edge counts
    when the client returns {:error, reason}
      then the action returns {:error, reason} (propagated)
```
