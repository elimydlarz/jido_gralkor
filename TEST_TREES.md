# Test Trees — jido_gralkor

These trees are the contract between intent and implementation. Each top-level name is a behaviour; nested `when`/`then` clauses are the spec. Tests in `test/` mirror these one-to-one.

Never modify silently. If implementation has drifted, decide explicitly: update the trees (and tests) to match, or pare the implementation back.

## Canonical turn shape

```
canonical-message
  a captured turn is a list of messages with:
    role ∈ {"user", "assistant", "behaviour"}
    content: str (opaque — adapters render harness-internal events however they like)
  the pipeline never branches on content interior structure — only on
    role (for distillation labels and interpretation context). Anything to strip or rewrite
    (gralkor-memory envelopes, system-line artefacts, etc.) is an adapter concern and lives
    in the harness's adapter, not here.
```

## Recall (embedded Gralkor adapter)

```
ex-recall (src: lib/gralkor/recall.ex; unit: test/gralkor/recall_test.exs)
  when relevant facts are found
    then memory_block lists them, one per line
    and each entry is the original fact verbatim (preserving every timestamp
      parenthetical) followed by ' — ' and a one-sentence relevance reason
  when no relevant facts are found
    then memory_block body is "No relevant memories found."
  request shape (Gralkor.Recall.recall/1 args)
    when called with a non-blank session_id
      then conversation context is sourced from Gralkor.CaptureBuffer.turns_for(session_id), flat-walked in order with role labels rendered using agent_name
    when called with a nil session_id
      then conversation context is empty
      and Gralkor.CaptureBuffer is not consulted
    when called with max_results
      then at most that many facts are searched
    when called without max_results
      then the default (10) is applied
    when called with an output_token_budget option
      then it is forwarded to Gralkor.Interpret.interpret_facts as its output_token_budget
    when called without an output_token_budget option
      then Gralkor.Interpret.interpret_facts applies its default (2000)
    then group_id is sanitized (hyphens → underscores) before use
    if agent_name is missing or blank
      then raises ArgumentError
  orchestration
    when called
      then Gralkor.GraphitiPool runs search against the sanitized group_id
        when search returns no facts
          then memory_block body is "No relevant memories found."
        when search returns facts
          then Gralkor.Interpret.interpret_facts is called with the conversation, the formatted facts, and the agent_name
            when interpret_facts returns relevant facts
              then memory_block body is the list of relevant facts
            when interpret_facts returns []
              then memory_block body is "No relevant memories found."
      and memory_block wraps body in <gralkor-memory trust="untrusted">...</gralkor-memory>
      and memory_block includes the further-querying instruction
  recall deadline
    then recall completes within 12_000ms (matches the consumer's worst-case tolerance — see Susu2.ChatAgent)
    if the budget is exhausted before the call returns
      then in-flight upstream work is cancelled
      and {:error, :recall_deadline_expired} is returned
  observability
    then logs the session
    and the group
    and the query length
    and the search result limit
    when the call completes
      then logs how many facts were found
      and the resulting block size
      and how long the search took
      and how long interpretation took
    when test mode is enabled
      then also logs the raw query
      when facts are returned
        then also logs the resulting memory block
  (rate-limit / transient upstream errors: req_llm owns the retry. ex layer adds nothing.)

ex-interpret (src: lib/gralkor/interpret.ex; unit: test/gralkor/interpret_test.exs)
  interpret_facts/5 takes conversation messages, formatted facts, an LLM client (interpret_fn), an agent_name, and an opts keyword list
    if agent_name is missing or blank
      then raises ArgumentError
    when opts[:output_token_budget] is omitted
      then a default of 2000 is applied
    if opts[:output_token_budget] is non-positive or non-integer
      then raises ArgumentError
    calls interpret_fn with the prompt (built via build_interpretation_context/3 with the agent_name) AND the output_token_budget — interpret_fn has arity 2 so the LLM-side wiring (e.g. req_llm) can pass max_tokens through to the provider
    and the interpretation prompt carries a "respond within {output_token_budget} tokens" instruction so the model self-limits the breadth of its answer
    and the structured-output schema instructs the LLM to copy each fact line verbatim
      (preserving every timestamp parenthetical, dropping the leading '- ')
      then ' — ' then a one-sentence relevance reason
    when the LLM returns relevant facts
      then returns the list unchanged
    when the LLM returns an empty list
      then returns []
    if the LLM response cannot be parsed against the structured-output schema (truncation, schema mismatch)
      then raises Gralkor.InterpretParseFailed (a distinct exception; no partial list is returned)

ex-format-fact (src: lib/gralkor/format.ex; unit: test/gralkor/format_test.exs)
  Gralkor.Format.format_fact/1 takes a map with :fact (required) and optional :created_at, :valid_at, :invalid_at, :expired_at timestamp strings
    then returns "- {fact}" with each present timestamp appended in parentheses in this order: "(created …)", "(valid from …)", "(invalid since …)", "(expired …)"
  Gralkor.Format.format_timestamp/1 takes an ISO-8601 timestamp string
    then strips fractional seconds
    then converts a trailing "Z" to "+0"
    then compacts a "+HH:00" / "-HH:00" zone offset to "+H" / "-H" (single-digit hour, no minutes when 00); a non-zero minute offset is preserved as "+H:MM" / "-H:MM"
  Gralkor.Format.format_facts/1 takes a list of fact maps
    when the list is empty
      then returns ""
    when the list has facts
      then joins format_fact/1 results with newlines (no leading "Facts:" header — Recall composes the surrounding context)

ex-interpret-context (src: lib/gralkor/interpret.ex; unit: test/gralkor/interpret_test.exs)
  build_interpretation_context/3 takes messages, facts_text, and an agent_name
    if agent_name is missing or blank
      then raises ArgumentError
    then renders user messages as "User: {content}"
    then renders assistant messages as "{agent_name}: {content}"
    then renders behaviour messages as "{agent_name}: (behaviour: {content})"
    then drops messages with empty cleaned content
    then assembles context as "Conversation context:\n{messages}\n\nMemory facts to interpret:\n{facts}"
    when total char length exceeds budget
      then oldest messages are dropped until context fits
    then does NOT inspect or mutate content beyond whitespace trimming
```

## Capture (embedded Gralkor adapter)

```
ex-capture-buffer (src: lib/gralkor/capture_buffer.ex; unit: test/gralkor/capture_buffer_test.exs)
  the buffer holds turns until an explicit flush — session lifetime is owned by the consumer;
  there is no idle-flush policy
  append/6 (session_id, group_id, agent_name, user_name, ontology, messages)
    when called for a new session_id
      then an entry is created bound to the sanitized group_id, the agent_name, the user_name, the ontology (a module or nil), and the turn (list of Messages)
    when called again for the same session_id
      then the new turn is appended to the existing entry and prior turns remain buffered
    when called for multiple session_ids
      then each session_id has an independent entry
    when called for an existing session_id with a different group_id
      then raises (sessions are not re-bindable across groups)
    when called for an existing session_id with a different agent_name
      then raises ArgumentError (same invariant as group_id)
    when called for an existing session_id with a different user_name
      then raises ArgumentError (same invariant as agent_name — the user identity for a session is fixed at first append; a session that started as Eli cannot mid-stream become Alice without a graph-quality contradiction)
    when called for an existing session_id with a different ontology module (or non-nil vs nil)
      then raises ArgumentError (the ontology is part of the session contract — switching mid-stream would mix entity/edge schemas in one episode, destroying interpretability)
    if agent_name is missing or blank
      then raises ArgumentError
    if user_name is missing or blank
      then raises ArgumentError
  turns_for/1
    when the session has buffered turns
      then returns [[Gralkor.Message.t()]] in append order
    when the session has never been appended to (or was just flushed)
      then returns []
  flush/1 (session_id)
    when called for a session_id with buffered turns
      then the flush callback is scheduled with (group_id, agent_name, user_name, [[Message]]) derived from the entry
      and the call returns without awaiting the scheduled flush
      and the entry is removed from the buffer
      and subsequent turns_for/1 calls return []
      and a "[gralkor] flush scheduled — session:<id> turns:<n>" line is emitted at :info
        (visible in production, not gated on test mode — successful flushes must be observable
         from logs alone, otherwise idle-driven session-end regressions go undetected)
    when called for a session_id with no entry
      then returns without scheduling any flush
      and a "[gralkor] flush — session:<id> empty" line is emitted at :info
        (an empty flush is a real outcome — distinguishable in logs from "no flush attempted")
  retry schedule (owns the server-internal failure class — see Retry ownership)
    when the flush callback succeeds (first attempt or after retries)
      then logs "[gralkor] capture flushed — turns:<n> elapsed:<ms>" at :info
    when the flush callback returns {:error, :capture_client_4xx}
      then does not retry and logs "capture dropped (4xx)" at :warning
    when the flush callback returns {:error, {:upstream_llm, _}}
      then does not retry and logs "capture dropped (upstream error)" at :warning
    when the flush callback raises or returns {:error, _} for any other reason (graph write failure, GraphitiPool error, internal distill crash)
      then retries at 1s, 2s, 4s (exponential)
    when the flush callback fails after 3 retries
      then logs "capture exhausted" at :error and drops
  flush_and_await/2 (session_id, timeout_ms)
    when called for a session_id with buffered turns
      then the entry is consumed (a subsequent turns_for/1 returns [], and a subsequent append starts a fresh entry)
      when the flush callback returns :ok within timeout_ms
        then :ok is returned
        and a flush-completed event is logged at :info naming the turn count and elapsed time
      when the flush callback does not return within timeout_ms
        then {:error, :timeout} is returned
        and a timeout event is logged at :warning naming the session id
      when the flush callback returns {:error, :capture_client_4xx}
        then {:error, :capture_client_4xx} is returned without retry
      when the flush callback returns {:error, {:upstream_llm, _}}
        then {:error, {:upstream_llm, _}} is returned without retry
      when the flush callback returns {:error, _} for any other reason
        then the same 1s/2s/4s retry schedule applies, governed by the caller's timeout_ms — if the retries together exceed the timeout, {:error, :timeout} is returned
    when called for a session_id with no entry
      then :ok is returned without scheduling a flush
      and an empty-flush event is logged at :info naming the session id
  flush_all/0
    when called with pending entries
      then every entry is flushed via the same callback and retry machinery and awaited
    when called with no entries
      then returns immediately
    when one flush fails and another succeeds
      then the successful flush still completes
  application shutdown
    when the supervision tree is stopping
      then Gralkor.CaptureBuffer.terminate/2 drains every pending entry via the flush callback before returning

ex-format-transcript (src: lib/gralkor/distill.ex; unit: test/gralkor/distill_test.exs)
  format_transcript/4 takes [[Gralkor.Message.t()]], a distill_fn, an agent_name, and a user_name
  if agent_name is missing or blank
    then raises ArgumentError
  if user_name is missing or blank
    then raises ArgumentError (the rendered transcript is fed to graphiti's entity extraction; a generic "User:" label collapses every user across the deployment into one node, destroying graph quality — every consumer must name the human)
  per turn
    when a turn contains a message with role="behaviour"
      then all messages in the turn are rendered with role labels ("{user_name}: {content}",
        "{agent_name}: (behaviour: {content})", "{agent_name}: {content}") and passed to
        the configured LLM (via req_llm) as the "thinking" prompt
    when a turn has no behaviour messages
      then distillation is skipped for that turn (no LLM call)
  transcript rendering
    when a turn has behaviour and the LLM call succeeds
      then it is distilled into a first-person past-tense summary
      and rendered as "{agent_name}: (behaviour: {summary})" before the assistant text for that turn
    when distillation fails for a turn (safe_distill)
      then the behaviour line is silently dropped, user/assistant text preserved
    when no LLM is configured
      then behaviour lines are silently omitted, user/assistant text preserved
    when a turn has no behaviour
      then rendered as "{user_name}: {content}\n{agent_name}: {content}" with no behaviour line, no LLM call
  then the LLM call uses a structured-output schema with a single "behaviour" field
  then turns with behaviour are distilled in parallel via Task.async_stream

ex-capture (src: lib/gralkor/client/native.ex#capture/5; unit: test/gralkor/client/native_test.exs)
  request shape
    when called with session_id, group_id, agent_name, user_name, messages (a list of Gralkor.Message structs)
      then group_id is sanitized
      and Gralkor.CaptureBuffer.append/5 is invoked with the sanitized group_id, the agent_name, the user_name, and the messages
  if session_id is missing or blank
    then raises ArgumentError
  if agent_name is missing or blank
    then raises ArgumentError
  if user_name is missing or blank
    then raises ArgumentError
  then returns :ok immediately (does not call distill synchronously)
  observability
    when test mode is enabled
      then logs the captured messages
  flush (fires from flush/1, flush_and_await/2, and shutdown only)
    when the distilled episode body is empty
      then no episode is added
      and nothing is logged
    when the episode is added
      then logs the group
      and the body size
      and how long the add took
    when test mode is enabled
      then also logs the distilled episode body

ex-flush (src: lib/gralkor/client/native.ex#flush/1; unit: test/gralkor/client/native_test.exs)
  when called with a session_id with buffered turns
    then the buffered turns are scheduled for flush and :ok is returned before the flush completes
  when called with a session_id with no buffered turns
    then :ok is returned and no work is scheduled
  if session_id is missing or blank
    then raises ArgumentError
  observability
    then a flush-scheduled event is logged at :info naming the session id and turn count

ex-flush-and-await (src: lib/gralkor/client/native.ex#flush_and_await/2; unit: test/gralkor/client/native_test.exs)
  when called with a session_id with buffered turns and a positive timeout_ms
    when the flush completes within the timeout
      then :ok is returned
      and an immediate recall/4 for the bound group surfaces the just-flushed turns
    when the flush does not complete within the timeout
      then {:error, :timeout} is returned
      and the buffered turns are still available to flush on a later call
    if the backend fails before the timeout
      then {:error, reason} is returned
  when called with a session_id with no buffered turns
    then :ok is returned
  if session_id is missing or blank
    then raises ArgumentError
  if timeout_ms is missing or non-positive
    then raises ArgumentError
  observability
    then a flush-and-await event is logged at :info naming the session id, turn count, and timeout
    then the outcome (ok / timeout / error) is logged at :info on return
```

## Tools (embedded Gralkor adapter)

```
ex-memory-add (src: lib/gralkor/client/native.ex#memory_add/4; unit: test/gralkor/client/native_test.exs)
  request shape
    when called with group_id, content, source_description, ontology
      then group_id is sanitized before ingestion
  then auto-generates name ("manual-add-" + timestamp_ms)
  then auto-generates idempotency_key from `System.unique_integer([:positive, :monotonic])` rendered as a string
  then calls Gralkor.GraphitiPool.add_episode with source=:text scoped to the sanitized group_id, forwarding the ontology as the final arg
  then returns :ok on success
  when source_description is nil
    then defaults to "manual"
  when ontology is nil
    then GraphitiPool.add_episode is invoked with ontology=nil — graphiti receives no entity_types/edge_types/edge_type_map/excluded_entity_types (behaviour identical to pre-ontology slice)
  when ontology is a module declared with `use Gralkor.Ontology`
    then the module's `__ontology__/0` payload is forwarded; GraphitiPool builds (and caches) the Pydantic dicts and passes them to graphiti — see ex-graphiti-pool > ontology materialisation

ex-build-indices (src: lib/gralkor/client/native.ex#build_indices/0; unit: test/gralkor/client/native_test.exs)
  then calls Gralkor.GraphitiPool.build_indices_and_constraints (operates on the whole graph)
  then returns {:ok, %{status: String.t()}}
  (admin-only — DO-NOT-CALL-UNLESS-ASKED semantics)

ex-build-communities (src: lib/gralkor/client/native.ex#build_communities/1; unit: test/gralkor/client/native_test.exs)
  request shape
    when called with group_id
      then group_id is sanitized before use
  then calls Gralkor.GraphitiPool.build_communities scoped to the sanitized group_id
  then returns {:ok, %{communities: non_neg_integer(), edges: non_neg_integer()}}
  (admin-only)
```

## Ontology DSL (embedded Gralkor adapter)

```
ex-ontology (src: lib/gralkor/ontology.ex; unit: test/gralkor/ontology_test.exs)
  the DSL — a consumer declares an ontology by `use Gralkor.Ontology, entities: …, relationships: …`
  and naming entities and outgoing relationship blocks. The macro produces a compile-time
  artefact (see ex-ontology-payload) that the Pythonx layer translates into graphiti's
  entity_types/edge_types/edge_type_map/excluded_entity_types at first use.

  `use Gralkor.Ontology, entities:, relationships:`
    if :entities is not provided
      then CompileError is raised naming :entities and the allowed values (:strict, :open)
    if :entities is provided as any value other than :strict or :open
      then CompileError is raised naming the bad value
    if :relationships is not provided
      then CompileError is raised naming :relationships and the allowed values (:scoped, :open)
    if :relationships is provided as any value other than :scoped or :open
      then CompileError is raised naming the bad value
    (no defaults — declaring an ontology is a deliberate act, and the open/closed semantics
     for entities vs relationships are independent enough that picking one default invariably
     surprises the consumer who needed the other)

  `entity Foo do … end`
    when Foo is an alias
      then the entity is named with the alias' last segment as a string ("Foo"); no real module Foo is defined
    inside the block
      when `field :name, :type` is called
        then a field with that name and type is added to the entity
        when called with `required: true`
          then the field is required (Pythonx side: a Pydantic field with no default)
        when called without :required or with `required: false`
          then the field is optional (Pythonx side: defaults to None)
        when called with `doc: "…"`
          then the doc string is recorded as the field's description
        if :type is not in the supported set (:string, :integer, :float, :boolean)
          then CompileError is raised naming the bad type
      if a field name collides with another field in the same entity
        then CompileError is raised naming the duplicate
      if a non-field expression (e.g. `prefers Foo`) appears inside the `entity` block
        then CompileError is raised — relationships do not live inside `entity` blocks (they go in `from` blocks)
    if `entity Foo` is declared more than once in the same ontology
      then CompileError is raised naming the duplicate entity

  `from Source do … end`
    when Source is an alias
      then the block declares outgoing relationships from the entity named with the alias' last segment
    inside the block
      when `verb Target` is called with no do-block
        then a relationship is added with name = uppercase snake of the verb ("prefers" → "PREFERS"), endpoint (Source → Target), and no edge properties
      when `verb Target do … end` is called
        then a relationship is added with the same name/endpoint, and the do-block's `field` calls become edge properties (same `field` semantics as inside `entity`)
      if Target is not an alias
        then CompileError is raised
      if the verb's uppercase-snake name collides with a previously declared verb whose edge-property schema (field names, types, required flags) differs
        then CompileError is raised naming the conflict
      when the same verb appears in multiple `from` blocks with matching property schemas
        then one edge type is declared and `:edge_type_map` gains one entry per (Source, Target) pair where the verb appeared
    if `from Source` references an alias that does not match any declared entity
      then CompileError is raised at end-of-module naming the unknown source
    if a relationship target alias does not match any declared entity
      then CompileError is raised at end-of-module naming the unknown target

  verb-to-name casing
    when the verb is a single lowercase word ("prefers")
      then the edge name is uppercase ("PREFERS")
    when the verb has underscores ("relates_to")
      then the edge name preserves underscores and uppercases each segment ("RELATES_TO")

  `__ontology__/0`
    then returns the materialised payload (see ex-ontology-payload)
    then the payload is computed at compile time — calling `__ontology__/0` is a constant lookup

ex-ontology-payload (src: lib/gralkor/ontology.ex; unit: test/gralkor/ontology_test.exs)
  the value an ontology module's `__ontology__/0` returns — the Elixir-side spec the Pythonx
  layer translates into graphiti's dicts. The Elixir side never builds Pydantic classes.

  shape
    then a map with keys :entity_types, :edge_types, :edge_type_map, :excluded_entity_types
    then :entity_types is a list of %{name: String.t(), fields: [field()]} entries, one per declared entity, in declaration order
    then :edge_types is a list of %{name: String.t(), fields: [field()]} entries, one per declared verb (deduplicated across `from` blocks), in first-declaration order
    then :edge_type_map is a list of {{source_name, target_name}, [edge_name]} pairs preserving declaration order across `from` blocks
    then :excluded_entity_types is ["Entity"] when `entities: :strict`, else nil
    then a field() entry is %{name: atom(), type: atom(), required: boolean(), doc: String.t() | nil}

  `relationships: :open`
    then :edge_type_map is []
      (the Pythonx side translates an empty list to "omit edge_type_map", which lets graphiti's
       default — every named edge allowed everywhere — apply)

  `relationships: :scoped`
    then :edge_type_map carries exactly the declared (source, target) → [edge_name] entries

  `entities: :open`
    then :excluded_entity_types is nil (graphiti also extracts generic Entity)

  `entities: :strict`
    then :excluded_entity_types is ["Entity"] (only declared types are extracted)

  empty ontology
    when no entities and no relationships are declared
      then :entity_types is []
      and :edge_types is []
      and :edge_type_map is []
      and :excluded_entity_types follows the entities: opt (nil for :open, ["Entity"] for :strict)
```

## Startup (embedded Gralkor adapter)

```
ex-application (src: lib/gralkor/application.ex; unit: test/gralkor/application_test.exs)
  start/2 child specs
    consumers opt in by setting either `:gralkor_ex, :falkordb` (remote FalkorDB) or `GRALKOR_DATA_DIR` (embedded falkordblite)
    when `:gralkor_ex, :falkordb` is set as a keyword list with `:host` and `:port`
      then the supervisor includes (in order):
        Gralkor.Python (synchronous boot — see ex-python-runtime; smoke-imports graphiti_core; does NOT import or reap redislite in remote mode)
        Gralkor.GraphitiPool (constructed with the remote spec — connects via host/port/credentials, no embedded redis-server is spawned)
        Gralkor.CaptureBuffer
      then `GRALKOR_DATA_DIR` is ignored even if also set (remote wins)
    when `:gralkor_ex, :falkordb` is unset and GRALKOR_DATA_DIR is set, with `:gralkor_ex, :client` unset or `Gralkor.Client.Native`
      then the supervisor includes (in order):
        Gralkor.Python (synchronous boot — see ex-python-runtime; reaps redislite orphans, smoke-imports graphiti_core)
        Gralkor.GraphitiPool (constructed with the embedded spec — falkordblite spawns redis-server child)
        Gralkor.CaptureBuffer
      then Application.start/2 returns only after all three have initialised
        (consumers do not need a separate readiness gate — there is no Gralkor.Connection)
    when neither `:gralkor_ex, :falkordb` nor GRALKOR_DATA_DIR is set
      then the supervisor includes no children
        (consumer / library has not opted in; tests start specific children via start_supervised; production sets one of the two)
    when `:gralkor_ex, :client` is configured to `Gralkor.Client.InMemory`
      then the supervisor includes no children regardless of GRALKOR_DATA_DIR or `:falkordb`
        (consumer has explicitly opted out of the native runtime; this matters because dotenv-loaders shipped by sibling deps — e.g. `:req_llm` — populate GRALKOR_DATA_DIR from `.env` before `:gralkor_ex` boots, so test configs that pin the InMemory client must not also be forced into the native boot path)
    when `:gralkor_ex, :falkordb` is set to a value that is not a keyword list, or is missing `:host` or `:port`
      then Application.start/2 raises ArgumentError before any child starts (fail-fast on operator misconfig)

ex-python-runtime (src: lib/gralkor/python.ex; unit: test/gralkor/python_test.exs)
  Gralkor.Python's init/1 runs the boot sequence synchronously and returns only when ready
    when running in embedded mode (GRALKOR_DATA_DIR is set, no `:falkordb` config)
      then any process whose argv contains "redislite/bin/redis-server" is SIGKILLed
        (boot-time backstop: falkordblite — loaded into PythonX in this BEAM — spawns a redis-server grandchild that a hard BEAM SIGKILL leaves orphaned. Safe to nuke unconditionally because this runs before our own PythonX init, so anything matching is by definition not ours-yet, and `redislite/bin/redis-server` is unique-to-falkordblite with no other plausible owner.)
    when running in remote mode (`:falkordb` is set)
      then no redislite reaping runs and `redislite` is not imported (remote FalkorDB owns its own storage; spawning local redis-servers would be wasted work and a confusing footgun if remote and embedded both ran concurrently in the same BEAM)
    then the priv/python/ uv-managed venv is materialised if absent
      (graphiti-core + falkordblite + provider deps installed; idempotent — subsequent boots noop)
    then PythonX is initialised pointing at that venv
    then a smoke import of graphiti_core succeeds
    then a shared asyncio event loop is installed on a daemon thread, exposed as `asyncio._gralkor_loop` plus a helper `asyncio._gralkor_run(coro)` that submits onto it via `run_coroutine_threadsafe(...).result()`
      (every Pythonx.eval block that drives graphiti uses `asyncio._gralkor_run(...)` instead of `asyncio.run(...)`. Without this, each Pythonx.eval would create a fresh event loop, and `AsyncFalkorDB` connections — which bind to the loop they're created on — would surface "Future attached to a different loop" on the second call.)
      (idempotent — `Gralkor.Python.install_async_runtime/0` checks `hasattr(asyncio, '_gralkor_loop')` before installing, so callers downstream can re-invoke it as a defence-in-depth measure.)
    if any step fails
      then init/1 returns {:stop, {:boot_failed, reason}} so the supervisor restarts (and the BEAM eventually exits if the failure is permanent)
  liveness
    then once booted, no health probes run — runtime failures surface from the next call into PythonX (which crashes the GenServer and triggers a supervisor restart)

ex-graphiti-pool (src: lib/gralkor/graphiti_pool.ex; unit: test/gralkor/graphiti_pool_test.exs; integration: test/gralkor/graphiti_pool_test.exs)
  LLM call ownership
    Distill and Interpret (Elixir-side pre/post-processing) call the LLM via req_llm — see ex-format-transcript and ex-interpret
    Graphiti-internal LLM and embedding (entity/edge extraction during add_episode; embedder during search; reranker) go through graphiti-core's bundled Python clients — never req_llm — because graphiti owns those call sites
  Gralkor.GraphitiPool's init/1 runs synchronously
    then `Gralkor.Python.install_async_runtime/0` is invoked (idempotent) so the pool can be booted standalone
    then the graphiti-core LLM client, embedder, and cross-encoder are constructed once via Pythonx and shared across every Graphiti instance for the lifetime of the GenServer
      where the embedder is constructed with `batch_size=1` regardless of provider
    when started with an embedded spec (`{:embedded, data_dir: dir}`)
      then `<data_dir>/gralkor.db.settings` is removed if present, immediately before constructing AsyncFalkorDB
        (redislite writes this resume-cache file alongside the db on every successful boot, pinning the unix-socket and pidfile of the redis-server it spawned. On the next boot it reads the file and decides "is the previous server still running?" by checking `kill -0 <pidfile_PID>` — a check that returns true for zombies. When that check returns true, redislite skips spawning fresh and blindly reconnects to the cached socket; the connection raises `ConnectionError` and the call fails with no fallback.)
      then a single AsyncFalkorDB is constructed via `redislite.async_falkordb_client.AsyncFalkorDB(<data_dir>/gralkor.db)` (falkordblite spawns the redis-server child) and held for the lifetime of the GenServer
    then warmup runs: search is invoked once with a throwaway query and group_id, then Gralkor.Interpret.interpret_facts is invoked once with an empty conversation and a throwaway facts_text, paying graphiti-core's cold-start cost before consumers can call recall
    then logs "[gralkor] warmup — search:… interpret:… <total>ms" at :info
    if any warmup call raises or returns {:error, _}
      then it is caught and logged at :warning as "[gralkor] warmup failed (non-fatal): <reason>"
      and boot proceeds (best-effort)
  for/1 (group_id) — also driven by search/4, add_episode/4, build_indices/1, build_communities/2, which all delegate to it
    when called against an embedded spec
      then the Graphiti instance for the sanitized group_id is looked up from a shared ETS cache; on first use it is constructed and inserted, then lives for the lifetime of the GenServer
      then concurrent callers proceed in parallel
    when called against a remote spec
      then a fresh AsyncFalkorDB and Graphiti instance scoped to the sanitized group_id are constructed and returned, then discarded by the caller after the operation that needed it returns
```

## Configuration (embedded Gralkor adapter)

```
ex-config-defaults (src: lib/gralkor/config.ex; unit: test/gralkor/config_test.exs)
  when the consumer supplies an LLM provider/model
    then that provider/model is used for all LLM calls (Distill, Interpret, graphiti-core inside PythonX)
  when the consumer omits LLM provider/model
    then defaults are applied (single source of truth in Gralkor.Config) — req_llm picks the provider; the embedder and cross-encoder defaults are stable so consumers can rely on them
  model-spec shape (the value Config.llm_model/0 and Config.embedder_model/0 return)
    then the shape is %{provider: atom(), id: String.t()} — the inline-map shape ReqLLM.model/1 accepts without a catalog lookup (and therefore without an "unverified model" IO.warn when the model id is newer than the LLMDB catalog snapshot)
    when GRALKOR_LLM_MODEL / GRALKOR_EMBEDDER_MODEL is unset or blank
      then the default map is returned
    when GRALKOR_LLM_MODEL / GRALKOR_EMBEDDER_MODEL is set to "provider:model"
      then it parses to %{provider: :provider, id: "model"}
    if the env var is set to a value missing the ":" separator or with a blank half
      then llm_model/0 / embedder_model/0 raises ArgumentError naming the env var and the bad value
```

## Timeouts (embedded Gralkor adapter)

```
ex-timeouts (integration: test/gralkor/client/native_test.exs)
  in-process via PythonX — no transport class, no receive windows. Only two operations carry a
    deadline; everything else runs to completion or crashes the GenServer.
  per-operation deadline
    Gralkor.Client.recall/3       12_000ms   (see ex-recall > recall deadline)
    Gralkor.Client.memory_add/3   60_000ms   (graphiti entity/edge extraction)
  if either deadline is exceeded
    then in-flight PythonX work is cancelled (via the GraphitiPool worker)
    and the call returns {:error, :deadline_expired}
```

## Gralkor Client Port

```
ex-client (src: lib/gralkor/client.ex; unit: test/support/gralkor_client_contract.ex; integration: test/gralkor/client/native_test.exs and test/gralkor/client/in_memory_test.exs)
  when recall/4 is called with a non-blank string session_id and an agent_name
    when the backend returns a memory block
      then {:ok, block} is returned
    if the backend fails
      then {:error, reason} is returned
  when recall/4 is called with a nil session_id and an agent_name
    when the backend returns a memory block
      then {:ok, block} is returned
    if the backend fails
      then {:error, reason} is returned
  when capture/5 is called with session_id, group_id, agent_name, user_name, and messages
    messages is a list of canonical Gralkor.Message structs (role ∈ {"user", "assistant", "behaviour"}, content: String.t())
    when the backend acknowledges the capture
      then :ok is returned
    if the backend fails
      then {:error, reason} is returned
    if agent_name is missing or blank
      then raises ArgumentError
    if user_name is missing or blank
      then raises ArgumentError
  when flush/1 is called with a session_id
    then :ok is returned before the flush completes
    if the backend later fails
      then the failure is not observable through the return value
  when flush_and_await/2 is called with a session_id and a timeout_ms
    when the flush completes within the timeout
      then :ok is returned
      and a subsequent recall/4 for the same group surfaces the just-flushed turns
    when the flush does not complete within the timeout
      then {:error, :timeout} is returned
      and the buffered turns are still available to flush on a later call
    if the backend fails before the timeout
      then {:error, reason} is returned
  when memory_add/3 is called with group_id, content, and source_description
    when the backend acknowledges the add
      then :ok is returned
    if the backend fails
      then {:error, reason} is returned
  when build_indices/0 is called
    when the backend acknowledges the rebuild
      then {:ok, %{status: String.t()}} is returned
    if the backend fails
      then {:error, reason} is returned
  when build_communities/1 is called with a group_id
    when the backend returns counts
      then {:ok, %{communities: non_neg_integer(), edges: non_neg_integer()}} is returned
    if the backend fails
      then {:error, reason} is returned
  agent_name validation
    if recall/4 or capture/5 is called with a missing or blank agent_name
      then ArgumentError is raised at the port boundary (no backend call is made)
  user_name validation
    if capture/5 is called with a missing or blank user_name
      then ArgumentError is raised at the port boundary (no backend call is made)

ex-sanitize-group-id (src: lib/gralkor/client.ex; unit: test/gralkor/client/native_test.exs and test/gralkor/client/in_memory_test.exs)
  when the id contains hyphens
    then hyphens are replaced with underscores
  when the id has consecutive hyphens
    then each hyphen is replaced independently
  when the id has no hyphens
    then it is returned unchanged

ex-impl-resolver (src: lib/gralkor/client.ex; unit: test/gralkor/client/native_test.exs and test/gralkor/client/in_memory_test.exs)
  when :gralkor_ex/:client is unset in app env
    then Gralkor.Client.Native is returned
  when :gralkor_ex/:client is configured to a module
    then that module is returned

ex-client-native (src: lib/gralkor/client/native.ex; integration: test/gralkor/client/native_test.exs)
  then no HTTP is involved — calls dispatch directly to Gralkor.Recall, Gralkor.CaptureBuffer, Gralkor.Tools, and Gralkor.GraphitiPool in-process
  when recall is called with a non-blank string session_id
    then the session_id is forwarded to Gralkor.Recall.recall/1 and used to fetch buffered conversation
  when recall is called with a nil session_id
    then Gralkor.Recall is invoked with no session_id and the conversation context is empty
  interpret output budget
    then :gralkor_ex, :interpret_max_output_tokens is read each call from app env (not at boot, so operators can change it without restarting) and, when set, forwarded to Gralkor.Recall as the output_token_budget option
    if :gralkor_ex, :interpret_max_output_tokens is set to a non-positive integer or a non-integer value
      then the call raises ArgumentError at the port boundary (configuration error surfaces immediately, not as a downstream LLM failure)
  if capture is called with a blank string session_id
    then the call raises with ArgumentError
  if capture is called with a nil session_id
    then the call raises with ArgumentError
  if capture is called with a missing or blank user_name
    then the call raises with ArgumentError
  if flush is called with a blank string session_id
    then the call raises with ArgumentError
  if flush is called with a nil session_id
    then the call raises with ArgumentError
  if flush_and_await is called with a blank string session_id
    then the call raises with ArgumentError
  if flush_and_await is called with a nil session_id
    then the call raises with ArgumentError
  if flush_and_await is called with a non-positive timeout_ms
    then the call raises with ArgumentError
  (per-operation deadline behaviour is described in ex-timeouts; flush_and_await is governed by the caller-supplied timeout, not the global deadline)
  runs the shared ex-client port contract (via test/support/gralkor_client_contract.ex)

ex-client-in-memory (src: lib/gralkor/client/in_memory.ex; unit: test/gralkor/client/in_memory_test.exs)
  when an operation is called
    then the call is recorded with its arguments for later inspection
  if no response is configured for an operation
    then {:error, :not_configured} is returned
  when reset/0 is called
    then configured responses and recorded calls are cleared
  runs the shared ex-client port contract (via test/support/gralkor_client_contract.ex)

(no ex-connection — the readiness gate is the synchronous boot of Gralkor.Python + Gralkor.GraphitiPool + Gralkor.CaptureBuffer. Application.start/2 doesn't return until they're all up.)
(no ex-orphan-reaper module — the redislite-orphan SIGKILL is the first step of ex-python-runtime's boot sequence, not a separate module.)
```

## JidoGralkor Plugin

```
JidoGralkor.Plugin (src: lib/jido_gralkor/plugin.ex; unit: test/jido_gralkor/plugin_test.exs)
  then registers MemorySearch, MemoryAdd, MemoryBuildIndices, and MemoryBuildCommunities as plugin actions, exposed via the autogenerated `JidoGralkor.Plugin.actions/0` for consumers to pass to `tools:`
  then a consumer agent that mounts the plugin compiles (no Jido route conflicts)
  then the session_id is the Jido thread id read from agent.state[:__thread__].id — the plugin does not mint its own id (no ULID at mount, no agent-lifecycle token); Jido's thread lifecycle is the single source of truth
  if mount/2 is called without an :agent_name opt or with a blank :agent_name
    then it raises ArgumentError (every consumer must supply the agent's name; there is no fallback)
  then mount/2 returns {:ok, %{agent_name: opts[:agent_name]}}
  user_name is read per-turn from `agent.state[:user_name]` — the consumer's responsibility to populate (e.g. via on_before_cmd from the signal's tool_context). Convention key, not a mount opt, because the user behind an agent can change between turns (multi-user deployments), and graph-quality depends on naming the right human in each captured episode.
  when an agent turn begins
    when a thread has committed to agent state
      then the thread's session_id and the configured agent_name are planted on the signal's tool_context so the `MemorySearch` ReAct tool can find them; the plugin does not call `Gralkor.Client.recall/3` on its own (recall is the LLM's job — see `JidoGralkor.ReAct` and the consumer's `RequestTransformer` for how `memory_search` is forced on iteration 1)
    when no thread has committed yet (first query on a fresh agent — ReAct strategy's ThreadAgent.append runs inside @start, after plugin hooks)
      then only the configured agent_name is planted on tool_context; no session_id is planted, and `MemorySearch` short-circuits with a non-result message on this turn
  when an agent turn completes
    then the user query, event trace, and `{:completed, answer}` outcome are normalised via
      `JidoGralkor.Canonical.to_messages/3` and the resulting canonical message list is sent to
      Gralkor for capture with the thread's session_id, the principal's group_id, the configured agent_name, and the user_name read from `agent.state[:user_name]`
    if `agent.state[:user_name]` is missing or blank
      then capture raises ArgumentError (the consumer's contract violation surfaces immediately rather than persisting an episode under a generic "User" label that would corrupt the graph)
  when an agent turn fails
    then the user query, event trace, and `{:failed, error}` outcome are normalised via
      `JidoGralkor.Canonical.to_messages/3` and the resulting canonical message list — ending in
      a `"request failed: …"` behaviour message instead of an assistant message — is sent to
      Gralkor for capture with the thread's session_id, the principal's group_id, the configured agent_name, and the user_name read from `agent.state[:user_name]`, so the failure is visible to downstream distillation rather than
      silently dropped
    when the agent has no committed thread yet (first-turn failure)
      then capture is skipped
      and a Logger.warning is emitted naming the agent id and pointing at the upstream
        jido_ai fix (susu-2 JIDO_CHANGE_SUGGESTIONS.md §2)
  when the completed turn has no events in its request trace
    then no capture is sent (simple chit-chat turns with no tool usage don't populate memory)
  when a signal of any other type arrives
    then handle_signal/2 returns {:ok, :continue} with no captures and no recalls
  if capture fails
    then the callback raises
```

## JidoGralkor ReAct helper

```
JidoGralkor.ReAct.maybe_force_memory_search/2 (src: lib/jido_gralkor/re_act.ex; unit: test/jido_gralkor/re_act_test.exs)
  when state.iteration == 1 (first ReAct turn)
    then the returned overrides carry llm_opts: [tool_choice: %{type: "function", function: %{name: "memory_search"}}], folded into any existing :llm_opts the consumer was already returning (other entries preserved)
  when state.iteration > 1
    then the overrides are returned unchanged (no tool_choice override — the model is free to answer or call further tools)
  when overrides has no :llm_opts key on iteration 1
    then :llm_opts is added with [tool_choice: %{type: "function", function: %{name: "memory_search"}}]
```

## JidoGralkor Lifecycle

```
JidoGralkor.Lifecycle (src: lib/jido_gralkor/lifecycle.ex; unit: test/jido_gralkor/lifecycle_test.exs)
  then implements `Jido.AgentServer.Lifecycle` so the AgentServer calls `terminate/2` on graceful stop
  when the AgentServer terminates with a committed thread
    then `Gralkor.Client.flush(thread_id)` is invoked without blocking termination
    and the flush is logged at :info naming the session id and the terminate reason
    if the background flush call fails
      then the failure is logged and termination is unaffected
  when the AgentServer terminates without a committed thread
    then Gralkor is not called
```

```
JidoGralkor.Lifecycle (integration) (integration: test/integration/lifecycle_integration_test.exs)
  while the AgentServer is wired with JidoGralkor.Lifecycle
    while a thread is committed
      when the AgentServer is stopped gracefully
        then `Gralkor.Client.flush` is invoked once with the thread id
    while no thread is committed
      when the AgentServer is stopped gracefully
        then `Gralkor.Client.flush` is not invoked
```

## JidoGralkor ContextRotator

```
JidoGralkor.ContextRotator.compute_seed/3 (src: lib/jido_gralkor/context_rotator.ex; unit: test/jido_gralkor/context_rotator_test.exs)

  when called with pre-flush entries, the same entries as current, and a positive keep_last_n smaller than the entry count
    then returns the last keep_last_n pre-flush entries
  when called with keep_last_n: 0 and no in-flight entries
    then returns []
  when current contains entries with seq beyond the max pre-flush seq (in-flight turns)
    then those entries are preserved in the seed regardless of keep_last_n
  when both keep_last_n entries and in-flight entries are present
    then keep_last_n entries come before in-flight entries in the seed
  when pre-flush entries is empty and current has entries (any in-flight)
    then the seed is just the in-flight entries
  when keep_last_n exceeds the pre-flush length
    then returns all pre-flush entries (plus any in-flight)
```

```
JidoGralkor.ContextRotator (src: lib/jido_gralkor/context_rotator.ex; integration: test/integration/context_rotator_integration_test.exs)

The test runs the AgentServer against `Gralkor.Client.InMemory`.

  while a thread is committed
    when rotate_now/2 is called and the flush returns :ok
      then the agent's active session id changes
      and the agent process is still running
      and InMemory records one flush_and_await for the pre-rotation session id and the configured flush timeout
    when rotate_now/2 is called with keep_last_n > 0 and the pre-rotation thread has more entries than keep_last_n
      then the rotated thread is seeded with the most recent keep_last_n entries
      and everything before them is dropped from the in-memory context
    when rotate_now/2 is called with keep_last_n: 0 and every pre-rotation entry was in the flushed set (no in-flight)
      then the rotated thread starts empty
    when rotate_now/2 is called and the flush fails
      then the error is propagated as {:error, reason}
      and the active session id is unchanged
      and the agent process is still running
  while no thread is committed
    when rotate_now/2 is called
      then it returns :ok without invoking the flush
      and the agent process is still running
```

## JidoGralkor Canonical

```
JidoGralkor.Canonical.to_messages/3 (src: lib/jido_gralkor/canonical.ex; unit: test/jido_gralkor/canonical_test.exs)
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

## JidoGralkor ReAct Actions

```
JidoGralkor.Actions.MemorySearch (src: lib/jido_gralkor/actions/memory_search.ex; unit: test/jido_gralkor/actions/memory_search_test.exs)
  when invoked with a non-blank query and session_id in context
    then group_id is derived from context.agent_id via Gralkor.Client.sanitize_group_id/1 and Gralkor.Client.impl().recall/3 is called with that group_id, session_id, and query
  when invoked with a blank or missing query
    then the client is not called and the action returns {:ok, %{result: <no-query non-result message>}}
    and a Logger.warning is emitted (defensive against forced-tool-call paths where the LLM had nothing meaningful to search for)
  when invoked without a session_id (or with a blank one) in context
    then the client is not called and the action returns {:ok, %{result: <no-session non-result message>}}
    and a Logger.warning is emitted naming the agent id and pointing at the upstream
      jido_ai fix (susu-2 JIDO_CHANGE_SUGGESTIONS.md §2)
  when the client returns {:ok, memory_block}
    then the action returns {:ok, %{result: memory_block}}
  when the client returns {:error, reason}
    then the action returns {:error, reason} (propagated). Our actual error reasons
      (atoms, `{atom, binary}` tuples) flow through jido_ai's
      `Jido.AI.Signal.Helpers.normalize_error` + `Jason.encode!` cleanly. The shape
      invariant is pinned by `test/jido_gralkor/actions/error_encoder_compat_test.exs`.
```

```
JidoGralkor.Actions.MemoryAdd (src: lib/jido_gralkor/actions/memory_add.ex; unit: test/jido_gralkor/actions/memory_add_test.exs)
  then source_description is a required tool parameter (alongside content) — the LLM must say where each stored insight came from, so no context-less memories land in the graph
  when invoked
    then the action returns {:ok, %{result: "Ingesting."}} without waiting on the client
    then the client's memory_add is called in a background Task with the sanitized group_id, content, and source_description
  if the background Task's client call fails
    then the failure is logged (best-effort storage)
```

```
JidoGralkor.Actions.MemoryBuildIndices (src: lib/jido_gralkor/actions/memory_build_indices.ex; unit: test/jido_gralkor/actions/memory_build_indices_test.exs)
  then the action's description tells the LLM DO NOT CALL unless the user has explicitly asked to rebuild Gralkor's graph indices (operator-maintenance action)
  when invoked
    then Gralkor.Client.impl().build_indices/0 is called (whole-graph, no arguments)
    when the client returns {:ok, %{status: status}}
      then the action result reports success with the status string
    when the client returns {:error, reason}
      then the action returns {:error, reason} (propagated; same encoder-safe
        shape invariant as MemorySearch — see
        `test/jido_gralkor/actions/error_encoder_compat_test.exs`)
```

```
JidoGralkor.Actions.MemoryBuildCommunities (src: lib/jido_gralkor/actions/memory_build_communities.ex; unit: test/jido_gralkor/actions/memory_build_communities_test.exs)
  then the action's description tells the LLM DO NOT CALL unless the user has explicitly asked to build Gralkor communities (expensive operator-maintenance action)
  when invoked
    then group_id is derived from context.agent_id via Gralkor.Client.sanitize_group_id/1
    then Gralkor.Client.impl().build_communities/1 is called with that group_id
    when the client returns {:ok, %{communities: c, edges: e}}
      then the action result reports the community and edge counts
    when the client returns {:error, reason}
      then the action returns {:error, reason} (propagated; same encoder-safe
        shape invariant as MemorySearch — see
        `test/jido_gralkor/actions/error_encoder_compat_test.exs`)
```

```
JidoGralkor.Actions error-encoder compat (unit: test/jido_gralkor/actions/error_encoder_compat_test.exs)
  for every error reason any JidoGralkor.Actions.* module is allowed to produce today
    (atoms, `{atom, binary}` tuples, bare binaries — never an exception struct)
    then `Jido.AI.Signal.Helpers.normalize_error/4` returns a plain map (not a struct)
    and `Jason.encode!/1` succeeds on that envelope (no `Protocol.UndefinedError`)
  rationale: pins a latent jido_ai 2.1.0 encoder bug where `normalize_error`'s
    `%{message: …}` clause did `Map.drop` on the struct, leaving `__struct__` in
    `:details` so `Jason.encode!` crashed. Fixed upstream on `main` in commit
    `d60699c0` (refactor of `Jido.AI.Error.normalize/4`); the test stays valuable
    as a regression guard on our own error shapes until that fix is published and
    pinned, after which it can be simplified or removed (see jido_gralkor CLAUDE.md).
```

## Functional Journey

```
jido-memory-journey (functional: test/functional/jido_memory_journey_test.exs)
  prerequisites
    given the application has booted Gralkor.Python with a real PythonX runtime, real graphiti-core, real falkordblite, and the configured LLM (req_llm)
    when no LLM API key is configured for the chosen provider
      then the suite is skipped
  round-trip
    given Gralkor.Client.memory_add/3 stores "Eli prefers concise explanations" under group "jido-test"
      when Gralkor.Client.recall/3 is called with a fresh session_id and a related query
        then {:ok, block} is returned
        and block is a non-empty <gralkor-memory> block
        and the block references the stored content semantically (contains "concise" or similar)
  flush
    given a pending turn in Gralkor.CaptureBuffer
      when Gralkor.Client.flush/1 is called with the session_id
        then :ok is returned before the episode is ingested
        and the episode eventually lands in the bound group_id
        and a follow-up Gralkor.Client.recall/3 surfaces the turn content
  flush_and_await
    given a pending turn in Gralkor.CaptureBuffer
      when Gralkor.Client.flush_and_await/2 is called with the session_id and a generous timeout
        then :ok is returned only after the episode is queryable
        and an immediate follow-up Gralkor.Client.recall/3 surfaces the turn content
  graceful-shutdown flush
    given a pending turn in Gralkor.CaptureBuffer (no idle elapsed)
      when the supervision tree stops (Application.stop or supervisor shutdown)
        then Gralkor.CaptureBuffer.terminate/2 awaits flush_all/0
        and the episode lands before the BEAM exits
      when the application is started again
        then a follow-up Gralkor.Client.recall/3 surfaces the previously-flushed episode
  runtime crash recovery
    when Gralkor.Python (the PythonX runtime owner) crashes
      then the supervisor restarts it
      and the next Gralkor.Client.recall/3 call returns {:ok, _} within the boot window
```

```
ex-remote-falkordb-journey (functional: test/functional/remote_falkordb_journey_test.exs)
  same consumer-visible round-trip as jido-memory-journey, but against a real network FalkorDB instead of the embedded falkordblite — proves the {:remote, kw} branch of Gralkor.GraphitiPool.default_construct_falkor_db actually drives graphiti against a remote graph
  prerequisites
    given a real FalkorDB is reachable at FALKORDB_TEST_HOST:FALKORDB_TEST_PORT (e.g. `docker run -p 6379:6379 falkordb/falkordb`)
      and `:gralkor_ex, :falkordb` is set to that host/port (with optional :username/:password)
      and GRALKOR_DATA_DIR is unset so the embedded path is not also armed
      and a real LLM API key is configured for the chosen provider
    when FALKORDB_TEST_HOST is unset
      then the suite is skipped (the unit tests in falkordb-connection cover the spec-loading shape)
  boot
    when the application boots
      then Gralkor.Python initialises with reap_orphans: false (no redislite reaping runs)
      and Gralkor.GraphitiPool constructs falkordb.asyncio.FalkorDB(host:, port:, username:, password:, ssl:) — no `redislite/bin/redis-server` grandchild appears in the BEAM's process tree at any point
  round-trip
    given Gralkor.Client.memory_add/3 stores a fact under a fresh group_id
      when Gralkor.Client.recall/3 is called with a fresh session_id and a related query
        then {:ok, block} is returned
        and the block references the stored content semantically
  flush_and_await (remote)
    given a pending turn in Gralkor.CaptureBuffer
      when Gralkor.Client.flush_and_await/2 is called with the session_id
        then :ok is returned only after the episode is queryable in the remote FalkorDB
        and an immediate follow-up Gralkor.Client.recall/3 surfaces the turn content
  shutdown
    when the application stops
      then Gralkor.CaptureBuffer.terminate/2 awaits flush_all/0 and the AsyncFalkorDB driver closes cleanly
      and no orphan processes are left on the BEAM host (the redis-server in this test is owned by the FalkorDB container, not us)
```

## Retry ownership

```
retry-ownership (stack-wide invariant; unit: none — other tree nodes in this file cite this section)
  then exactly one layer retries any given failure class
  then layers above the owner derive their timeout from that layer's worst case
  then no two layers retry the same class
  failure class: upstream LLM rate-limit (HTTP 429 from the configured provider)
    owner: req_llm
      then req_llm's built-in 429 handling absorbs the first hit; the ex layer adds nothing
    then no other endpoint or call site retries this class — 429 surfaces immediately
  failure class: upstream LLM other (HTTP 408, 500, 502, 503, 504)
    no owner — surfaces through req_llm's error tuple straight to the consumer
  failure class: LLM malformed output (structured-output parse failures, refusal)
    owner: graphiti-core (graphiti-core itself runs the structured-output retry loop, invoked via PythonX)
      then 2 attempts; the error text is appended to the next prompt
    then no layer above retries this class
  failure class: server-internal / runtime-internal (graph write failure, FalkorDB driver error, internal distill crash)
    owner for the capture chain: ex-capture-buffer (1s / 2s / 4s exponential)
    for all other chains: no owner — the failure surfaces immediately
  failure class: consumer-budget expired (the outermost timeout at the consumer)
    owner: the consumer (Susu2.ChatAgent 30 s ask_sync)
      then returns to the user; logs at :warn; does not retry
```

## Distribution

```
publish-jido-gralkor (src: scripts/publish.sh; unit: none)
  when publish succeeds
    then @version is bumped in mix.exs
    and a git tag jido-gralkor-v${version} is created for the new version (push manually)
  when HEX_API_KEY is missing (no fallback to user OAuth)
    then exits before version bump with a clear error
    and no rollback is needed
  when publish fails (mix hex.publish reject)
    then @version in mix.exs is rolled back to its pre-publish value
    and no git tag is created
  when level is current
    then @version is not incremented
    and publish still runs
    and a git tag jido-gralkor-v${version} is created for the current version
  when level is current and publish fails
    then no rollback runs
    and mix.exs remains unchanged
```
