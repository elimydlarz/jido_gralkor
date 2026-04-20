# jido_gralkor

Jido-side adapter for the Gralkor memory server. Ships three modules that let any Jido agent use Gralkor without reimplementing the plumbing.

## Mental Model

- **`JidoGralkor.Plugin`** — `use Jido.Plugin, name: "gralkor", state_key: :__memory__, singleton: true, actions: []`. Claims the `:__memory__` slot. Does recall on `ai.react.query` (prepends any returned memory block to the query; plants `session_id` on `tool_context`) and capture on `ai.request.completed` / `ai.request.failed` (bundles the full ReAct event trace + user query + assistant answer into a turn and ships it to Gralkor). `session_id` is the current Jido thread id (read from `agent.state[:__thread__].id`, populated by `Jido.Thread.Plugin`) — the plugin does not mint its own identifier. `group_id` is `Gralkor.Client.sanitize_group_id(agent.id)` (per-principal memory partition). No plugin state — `mount/2` returns `{:ok, nil}`. Gralkor errors raise so callers see them per fail-fast. Consumers must mount `Jido.Thread.Plugin` on their `use Jido` supervisor; otherwise there's no thread id to read.
- **`JidoGralkor.Actions.MemorySearch`** — `use Jido.Action, name: "memory_search"`. The ReAct tool. Reads `session_id` from `context[:session_id]` (planted by the plugin on `ai.react.query` — the Jido thread id) and derives `group_id` from `context[:agent_id]`. If `session_id` is absent or blank (LLM called the tool on the very first query of a fresh agent, before the strategy committed a thread), short-circuits with an explicit "did not run" non-result message without calling the client. Otherwise calls `Gralkor.Client.impl().memory_search/3`; propagates `{:error, reason}` on client failure.
- **`JidoGralkor.Actions.MemoryAdd`** — `use Jido.Action, name: "memory_add"`. Fire-and-forget ReAct tool: spawns a `Task` that calls `Gralkor.Client.impl().memory_add/3` and logs on failure; returns `{:ok, %{result: "Queued for storage."}}` immediately. The server-side write invokes Graphiti entity/edge extraction (LLM + graph update, tens of seconds) — far longer than the agent should wait before replying, and Jido has no native async tool calls.

## Dependencies

Two direct Hex deps (three with `:ex_doc` for dev docs):

- `{:jido, "~> 2.2"}` — `Jido.Plugin`, `Jido.Action`, `Jido.Signal` (struct + pattern match).
- `{:jido_ai, "~> 2.1"}` — `Jido.AI.Request.get_request/2` (used once in the plugin to look up the user query for a completed `request_id`).
- `{:gralkor, "~> 1.1"}` — `Gralkor.Client` (behaviour + `sanitize_group_id/1` + `impl/0` resolver). The plugin calls `recall/3` + `capture/3`; actions call `memory_search/3` + `memory_add/3`. `end_session/1` and `health_check/0` are not used here — consumers call those directly from their own agent lifecycle / supervision tree.

## Testing

Test trees use `Gralkor.Client.InMemory` (shipped in `lib/` of `:gralkor`) as the client. `config/test.exs` sets `config :gralkor, client: Gralkor.Client.InMemory`; `test_helper.exs` starts the GenServer once globally. Tests call `InMemory.reset/0` in `setup` and configure canned responses per scenario.

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
  when an agent turn completes
    then the turn — user query, event trace, assistant answer — is sent to Gralkor for capture with the thread's session_id and the principal's group_id
  when an agent turn fails
    then the turn is still sent to Gralkor for capture
    when the agent has no committed thread yet (first-turn failure)
      then capture is skipped
  when the completed turn has no events in its request trace
    then no capture is sent
  if capture fails
    then the callback raises
```

### Actions.MemorySearch

```
JidoGralkor.Actions.MemorySearch
  when invoked with session_id in context
    then group_id is derived from context.agent_id via Gralkor.Client.sanitize_group_id/1 and session_id is passed straight through to the client
  when invoked without a session_id (or with a blank one) in context
    then the client is not called and the action returns {:ok, %{result: <non-result message>}} where the message explicitly tells the LLM the search did not run (vs. ran-and-found-nothing), so the LLM can't read an empty payload as "no memory exists" and confidently lie
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
