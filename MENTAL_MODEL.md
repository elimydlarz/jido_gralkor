## Core Domain Identity

`:jido_gralkor` is the adapter library between a Jido agent loop and Gralkor's memory port. It owns the wiring (plugin + lifecycle + ReAct tools + canonical message translation); it owns no memory behaviour of its own.

## World-to-Code Mapping

- **`JidoGralkor.Plugin`** — the Jido hook that watches `ai.react.query` / `ai.request.completed` / `ai.request.failed` signals and plants context / fires captures.
- **`JidoGralkor.Actions.MemorySearch` / `MemoryAdd`** — ReAct tools the LLM calls; `MemorySearch` is the only recall path (no auto-recall in the plugin).
- **`JidoGralkor.ReAct.maybe_force_memory_search/2`** — folds `tool_choice` into the consumer's transformer overrides on iter-1, making recall agentic.
- **`JidoGralkor.Canonical.to_messages/3`** — normalises a Jido/ReAct turn into Gralkor's `[%Message{role, content}]` shape.
- **`JidoGralkor.Lifecycle`** — graceful-shutdown flush via `Gralkor.Client.flush/1`.
- **`JidoGralkor.ContextRotator`** — synchronous rotate-on-demand (flush + fresh thread + compaction signal).
- **`Gralkor.Ontology`** — compile-time DSL for declaring graphiti custom-entity ontologies (`entity Foo do … end`, `from Source do verb Target end`). The consumer's ontology module is a deployment-wide config value (`config :jido_gralkor, ontology:`) that `Gralkor.Client` resolves via `Gralkor.Config.ontology/0` on every write (capture flush + `memory_add`) — never threaded through agent state.

## Ubiquitous Language

- *plugin* — `Jido.Plugin` mounted on a `use Jido` supervisor.
- *thread* — a Jido conversation segment; its `id` is the Gralkor `session_id`.
- *agent_name* — the assistant's display name; required at mount; renders all assistant turns in graphiti.
- *user_name* — the human's name per turn; stashed on `agent.state[:user_name]` by the consumer.
- *forced recall* — the iter-1 `tool_choice` override that pins `memory_search` on the first ReAct iteration.
- *ontology* — a module declared with `use Gralkor.Ontology, entities: …, relationships: …` that names the entity types and outgoing relationships graphiti should extract from captured episodes. Configured once deployment-wide (`config :jido_gralkor, ontology:`); applied automatically to every `add_episode` call. A programmatic `Gralkor.Client.memory_add/4` override can substitute a different ontology for a single add.

## Bounded Contexts

One context only — the Jido↔Gralkor adaptation. The memory pipelines (`Gralkor.*` under `lib/gralkor/`) are embedded but logically separate: they hold the domain logic; the `JidoGralkor.*` modules are pure framework glue.

## Invariants

- Recall is LLM-driven via `MemorySearch`; the plugin never calls `Gralkor.Client.recall/4` directly.
- `session_id` is the Jido thread id from `agent.state[:__thread__].id` — never minted by the plugin.
- `agent_name` is required at mount; missing/blank raises `ArgumentError`.
- `user_name` is read per-turn from `agent.state[:user_name]`; capture raises on missing/blank.
- First-turn-on-fresh-agent: no thread yet → `MemorySearch` short-circuits, capture is skipped, only `agent_name` is planted.

## Decision Rationale

- The iter-1 `tool_choice` forcing is a workaround: `Jido.AI.Reasoning.ReAct.Config` lacks a `:preamble_tool` knob, and `tool_choice` is applied uniformly across the ReAct loop today. The helper exists to pin it for one iteration without forking the strategy.
- The plugin captures on every turn, regardless of whether tools were called, because the embedded `Gralkor.Distill` decides what's memory-worthy — we don't gate at this layer.
- Recalled graph content is memory context, not adjudicated truth. Gralkor preserves and retrieves understandings extracted from source material without imposing confidence or verification semantics on the ontology; truth-sensitive verification belongs to the consuming application.
- All operator-facing knobs (`:falkordb`, `:client`, `:ontology`, `:interpret_max_output_tokens`, `:recall_deadline_ms`, `:test`) live under the `:jido_gralkor` app env — single namespace matching the OTP application. `Gralkor.Client.Native` reads them per call so operators can change them without restarting.
- Ontology is config, not state. It applies uniformly to every write (capture + `memory_add`) so one graph never mixes entity/edge schemas, and there is exactly one deployment-wide source of truth. Wiring it through the plugin mount + agent state (the prior design) was a coupling that forced a per-agent value onto a graph-wide concern and left the low-level `Gralkor.Client` unable to default it; the only legitimate per-call variation is the programmatic `memory_add/4` override.
- The embedded Python stack is a consumer-invisible internal concern: `Gralkor.Python.init/1` materialises the venv via `Pythonx.uv_init/2` from jido_gralkor's own `priv/python/pyproject.toml`, so consumers configure *nothing* about Python. The Python deps must live in jido_gralkor's packaged manifest rather than `config/config.exs` because a dep's config does not propagate to a consumer's runtime app env and Pythonx reads its pin via `Application.compile_env` — leaving it in config forced every consumer to restate (and silently drift on) the graphiti-core version.
- `Gralkor.Ontology` declares each relationship once (`from Source do verb Target end`) and derives graphiti's `edge_types` + `edge_type_map` automatically. Graphiti's split between those two dicts is the modelled-once-mentioned-twice trap the DSL exists to remove. `relationships: :scoped` does not forbid generic edges — graphiti always extracts edge candidates and only constrains *which named class* they conform to between declared `(src, dst)` pairs; closing the world on edges would require post-filtering not yet implemented.

## Temporal View

`ai.react.query` → plant `:session_id` (if thread committed) + `:agent_name` on signal `tool_context` → ReAct strategy invokes the LLM with the forced `tool_choice` on iter-1 → `MemorySearch` runs against `Gralkor.Client.recall/4` → ReAct loops → `ai.request.completed`/`failed` → `Canonical.to_messages/3` normalises the turn → `Gralkor.Client.capture/5` ingests (the configured ontology is resolved by the client, not threaded through the signal). On AgentServer termination, `Lifecycle.terminate/2` fires a fire-and-forget `Gralkor.Client.flush/1`. On manual rotate (`/new`), `ContextRotator.rotate_now/2` flushes synchronously, installs a fresh thread, emits a compaction signal.
