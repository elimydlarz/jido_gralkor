# jido_gralkor

Jido-side adapter for the Gralkor memory server. Ships three modules that let any Jido agent use Gralkor without reimplementing the plumbing.

## Mental Model

- **`JidoGralkor.Plugin`** — `use Jido.Plugin, name: "gralkor", state_key: :__memory__, singleton: true, actions: []`. Claims the `:__memory__` slot. Does recall on `ai.react.query` (stashes the returned memory block on the signal's `tool_context` under `:__gralkor_memory__`, alongside the thread's `:session_id` when a thread is committed) and capture on `ai.request.completed` / `ai.request.failed`. The plugin never mutates `:query` — memory is delivered to the LLM by a `Jido.AI.Reasoning.ReAct.RequestTransformer` at prompt-build time (consumer-owned; see `Jido.AI.PromptBuilder`), so `:query` stays the user's actual words everywhere downstream (buffer, request store, capture). For capture, the plugin hands the user query, the full ReAct event trace, and a turn outcome — `{:completed, answer}` or `{:failed, error}` — to `JidoGralkor.Canonical.to_messages/3`, which normalises the turn into Gralkor's canonical `[%Gralkor.Message{role, content}]` shape (roles: `"user" | "assistant" | "behaviour"`). That list is what gets sent to Gralkor — the server has no opinion about Jido-shaped events. The two signal types are handled by separate `handle_signal` clauses that pattern-match their payload shape (`:result` vs `:error`); malformed signals fall through to the catchall. `session_id` is the current Jido thread id (read from `agent.state[:__thread__].id`, populated by `Jido.Thread.Plugin`) — the plugin does not mint its own identifier. On the very first query of a fresh agent, no thread is committed yet (ReAct strategy's `ThreadAgent.append` runs inside `@start`, after the plugin hook); recall is still called with `nil` session_id so the server can search by group_id alone with an empty conversation context. `group_id` is `Gralkor.Client.sanitize_group_id(agent.id)` (per-principal memory partition). No plugin state — `mount/2` returns `{:ok, nil}`. **Recall failures are best-effort** — the plugin logs a warning and continues the turn without memory context (the Vertex-upstream retries live at the google-genai SDK; see `gralkor/TEST_TREES.md › Retry ownership`). Capture failures still raise (server-unreachable is a distinct failure class). Consumers must mount `Jido.Thread.Plugin` on their `use Jido` supervisor; otherwise there's no thread id to read.
- **`JidoGralkor.Lifecycle`** — `Jido.AgentServer.Lifecycle` implementation that turns AgentServer termination into a Gralkor session-end. Owns an idle timer (armed from `state.lifecycle.idle_timeout` if positive; opted out otherwise), cancels and re-arms on each `:touch` event the consumer casts on user activity, and on idle expiry returns `{:stop, {:shutdown, :idle_timeout}, state}`. `terminate/2` reads the committed Jido thread id from `state.agent.state[:__thread__].id` and fire-and-forgets `Gralkor.Client.end_session(thread_id)` via `Task.start`; failures are logged but never block termination. First-turn agents (no thread committed yet) terminate without calling Gralkor. The mechanism is consumer-agnostic: callers decide *policy* (timeout duration, when to call `:touch`, when to issue `GenServer.stop`); the lib owns the *mechanism* (timer plumbing, thread-id read, `end_session` call). Note: `DynamicSupervisor.terminate_child` sends a raw `:shutdown` exit signal that the AgentServer (no `trap_exit`) dies on without invoking `terminate/2` — any consumer path that needs `end_session` to fire must go through `GenServer.stop(pid, reason, timeout)`.
- **`JidoGralkor.Canonical`** — the adapter-only module that translates a Jido/ReAct turn into Gralkor's canonical message shape. Takes `user_query` at face value — whatever string was registered with the request is what gets persisted — because the plugin and the rest of the pipeline keep `:query` the user's actual words (no envelope stripping is needed or performed here; harness-injected context is added at prompt-build time in the `RequestTransformer`, not in the query). Filters events that aren't memory-worthy, and renders surviving `:llm_completed` / `:tool_completed` events as `behaviour` messages with content the distillation LLM can read (`"thought: …"`, `"tool NAME → RESULT"`). The turn outcome terminates the message list: `{:completed, answer}` becomes the trailing `"assistant"` message; `{:failed, error}` becomes a terminal `"behaviour"` message `"request failed: …"` so the failure is visible to downstream distillation rather than silently swallowed. Returns `[]` when nothing is worth persisting; the plugin uses that to skip the capture call entirely.
- **`JidoGralkor.Actions.MemorySearch`** — `use Jido.Action, name: "memory_search"`. The ReAct tool. Reads `session_id` from `context[:session_id]` (planted by the plugin on `ai.react.query` — the Jido thread id) and derives `group_id` from `context[:agent_id]`. If `session_id` is absent or blank (LLM called the tool on the very first query of a fresh agent, before the strategy committed a thread), short-circuits with an explicit non-result message without calling the client. Otherwise calls `Gralkor.Client.impl().recall/3` — the same path the plugin uses for auto-recall (there is no separate manual-search endpoint). Returns `{:ok, %{result: memory_block}}` on `{:ok, block}`, `{:ok, %{result: <non-result message>}}` when no session is committed, and propagates `{:error, reason}` on client failure. The map-shaped return is required by `Jido.Action.Runtime.do_validate_output/2`, which calls `Map.split/2` on every action's output.
- **`JidoGralkor.Actions.MemoryAdd`** — `use Jido.Action, name: "memory_add"`. Fire-and-forget ReAct tool: spawns a `Task` that calls `Gralkor.Client.impl().memory_add/3` and logs on failure; returns `{:ok, %{result: "Ingesting."}}` immediately. The server-side write invokes Graphiti entity/edge extraction (LLM + graph update, tens of seconds) — far longer than the agent should wait before replying, and Jido has no native async tool calls.

## Dependencies

Two direct Hex deps (three with `:ex_doc` for dev docs):

- `{:jido, "~> 2.2"}` — `Jido.Plugin`, `Jido.Action`, `Jido.Signal` (struct + pattern match).
- `{:jido_ai, "~> 2.1"}` — `Jido.AI.Request.get_request/2` (used once in the plugin to look up the user query for a completed `request_id`).
- `{:gralkor_ex, "~> 2.0"}` — `Gralkor.Client` (behaviour + `sanitize_group_id/1` + `impl/0` resolver). The plugin and the `MemorySearch` action both call `recall/3`; the plugin also calls `capture/3`; other actions call `memory_add/3` + `build_indices/0` + `build_communities/1`; `JidoGralkor.Lifecycle` calls `end_session/1`. `health_check/0` is not used here — consumers call it directly from their own supervision tree.

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
    when a thread has committed to agent state
      then Gralkor is asked to recall memory for the agent's group_id and the thread's session_id with the query, which is passed through unchanged (no envelope stripping, no mutation — the plugin's contract is that `:query` is already the user's actual words)
      and the thread's session_id is planted on the signal's tool_context for downstream tool calls
    when no thread has committed yet (first query on a fresh agent — ReAct strategy's ThreadAgent.append runs inside @start, after plugin hooks)
      then Gralkor is asked to recall memory for the agent's group_id and a nil session_id with the query, which is passed through unchanged
      and no session_id is planted on the signal's tool_context
    when recall returns a memory block
      then the block is stashed on the signal's tool_context under `:__gralkor_memory__` for a downstream `RequestTransformer` to fold into the LLM prompt; `:query` itself is not mutated
    if recall fails
      then the turn continues without `:__gralkor_memory__` — the session_id (when a thread had committed) is still stashed on tool_context; `:query` is unchanged
      and a Logger.warning is emitted naming the reason, because memory is best-effort under the retry-ownership doctrine — the Vertex-upstream retries happen at the google-genai SDK, so if the failure reaches this point the SDK has already given up and retrying here would amplify load (see `gralkor/TEST_TREES.md › Retry ownership`)
  when an agent turn completes
    then the user query, event trace, and `{:completed, answer}` outcome are normalised via
      `JidoGralkor.Canonical.to_messages/3` and the resulting canonical message list is sent to
      Gralkor for capture with the thread's session_id and the principal's group_id
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

### Lifecycle

```
JidoGralkor.Lifecycle (src: lib/jido_gralkor/lifecycle.ex; unit: test/jido_gralkor/lifecycle_test.exs)
  then implements `Jido.AgentServer.Lifecycle` so the AgentServer's built-in idle-timer machinery owns the timer
  then `terminate/2` only runs on stop reasons that route through `GenServer`'s state machine — internal `{:stop, reason, state}` (e.g. `handle_event(:idle_timeout)`) or external `GenServer.stop(pid, reason, timeout)`. Raw `:shutdown` exit signals (e.g. `DynamicSupervisor.terminate_child`) bypass `terminate/2` because the AgentServer doesn't `trap_exit` — consumer paths that need `end_session` to fire must converge on `GenServer.stop`
  when the AgentServer initialises with a positive idle_timeout
    then an idle timer is armed for that window
  when the AgentServer initialises with a non-positive or absent idle_timeout
    then no idle timer is armed (consumer has opted out of idle-driven shutdown; only external GenServer.stop will trigger end_session)
  when a `:touch` event arrives
    then the idle timer is cancelled and re-armed for a fresh window
  when the idle timer elapses without a touch
    then the lifecycle returns `{:stop, {:shutdown, :idle_timeout}, state}` so the AgentServer terminates cleanly
  when the AgentServer terminates with a committed thread
    then `Gralkor.Client.end_session(thread_id)` is fire-and-forgotten via Task.start
    and a "[gralkor] end_session — session:<thread_id> reason:<terminate_reason>" line is
      emitted at :info before the Task is spawned (idle-timeout vs `/start` reset are both
      observable from this single line; the consumer-side trigger is logged independently of
      whether the buffer had anything to flush)
    if the background Gralkor.Client.end_session call fails
      then the failure is logged (best-effort flush; termination is unaffected)
  when the AgentServer terminates without a committed thread (first-turn agent that never appended)
    then Gralkor is not called
```

```
JidoGralkor.Lifecycle (integration) (integration: test/integration/lifecycle_integration_test.exs)
  while the AgentServer is wired with JidoGralkor.Lifecycle and a positive idle_timeout
    while a thread is committed
      when the idle window elapses without :touch
        then the AgentServer terminates and end_session fires once with the thread id
      when :touch arrives before each elapse
        then the AgentServer stays alive and end_session is not called
      when GenServer.stop(:shutdown) is invoked
        then end_session fires with the thread id
    while no thread is committed (first turn)
      when GenServer.stop is invoked
        then the AgentServer terminates and end_session is not called
  while the AgentServer is wired with a non-positive idle_timeout
    then no idle timer is armed (verified by elapsing well past any plausible window)
```

### Canonical

```
JidoGralkor.Canonical.to_messages/3
  when a :llm_completed event has a non-empty tool_calls list
    then a behaviour message "thought: <text>" is emitted for it, preserving order
  when a :llm_completed event has an empty tool_calls list
    then no "thought:" behaviour is emitted for it (the text is the turn's answer, and in
      a completed outcome will already be carried by the trailing assistant message)
  when the outcome is {:completed, answer}
    when user query, answer, and events are all empty
      then returns []
    then the user message content is the `user_query` as given (no envelope stripping — the
      plugin's contract is that `:query` is the user's actual words; harness context lives in
      the `RequestTransformer`, not the query)
    when the events contain a :tool_completed event
      then a behaviour message with "tool <name> → <result>" is emitted, preserving order
    when the events contain an unknown :kind
      then that event is ignored (telemetry-only signals don't become memory)
    when the answer is empty
      then no trailing assistant message is emitted
    when the answer is present
      then the final message is an assistant-role message with the trimmed answer
    then messages are ordered user → behaviour(s) → assistant
    when an LLM event carries Anthropic-style list-shaped content blocks
      then the text blocks are concatenated with spaces into the rendered "thought: …" message
  when the outcome is {:failed, error}
    then a terminal behaviour message "request failed: <error>" is emitted in place of the
      assistant message, so the failure is visible to downstream distillation rather than the
      turn ending in silence (error rendered via the same formatter used for tool results)
    then no assistant-role message is emitted
    then messages are ordered user → behaviour(s from events) → "request failed: …"
```

### Actions.MemorySearch

```
JidoGralkor.Actions.MemorySearch
  when invoked with session_id in context
    then group_id is derived from context.agent_id via Gralkor.Client.sanitize_group_id/1 and Gralkor.Client.impl().recall/3 is called with that group_id, session_id, and query
  when invoked without a session_id (or with a blank one) in context
    then the client is not called and the action returns {:ok, %{result: <non-result message string>}}
    and a Logger.warning is emitted naming the agent id and pointing at the upstream
      jido_ai fix (susu-2 JIDO_CHANGE_SUGGESTIONS.md §2)
  when the client returns {:ok, memory_block}
    then the action returns {:ok, %{result: memory_block}}
  when the client returns {:error, reason}
    then the action returns {:error, reason} (propagated)
```

### Actions.MemoryAdd

```
JidoGralkor.Actions.MemoryAdd
  then source_description is a required tool parameter (alongside content) — the LLM must say where each stored insight came from, so no context-less memories land in the graph
  when invoked
    then the action returns {:ok, %{result: "Ingesting."}} without waiting on the client
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
