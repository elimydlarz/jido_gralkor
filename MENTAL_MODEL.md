## Core Domain Identity

`:jido_gralkor` is the adapter library between a Jido agent loop and Gralkor's memory port. It owns the wiring (plugin + lifecycle + ReAct tools + canonical message translation); it owns no memory behaviour of its own.

## World-to-Code Mapping

- **`JidoGralkor.Plugin`** — the Jido hook that watches `ai.react.query` / `ai.request.completed` / `ai.request.failed` signals and plants context / fires captures.
- **`JidoGralkor.Actions.MemorySearch` / `MemoryAdd`** — ReAct tools the LLM calls; `MemorySearch` is the only recall path (no auto-recall in the plugin).
- **`JidoGralkor.ReAct.maybe_force_memory_search/2`** — folds `tool_choice` into the consumer's transformer overrides on iter-1, making recall agentic.
- **`JidoGralkor.Canonical.to_messages/3`** — normalises a Jido/ReAct turn into Gralkor's `[%Message{role, content}]` shape.
- **`JidoGralkor.Lifecycle`** — graceful-shutdown flush via `Gralkor.Client.flush/1`.
- **`JidoGralkor.ContextRotator`** — synchronous rotate-on-demand (flush + fresh thread + compaction signal).

## Ubiquitous Language

- *plugin* — `Jido.Plugin` mounted on a `use Jido` supervisor.
- *thread* — a Jido conversation segment; its `id` is the Gralkor `session_id`.
- *agent_name* — the assistant's display name; required at mount; renders all assistant turns in graphiti.
- *user_name* — the human's name per turn; stashed on `agent.state[:user_name]` by the consumer.
- *forced recall* — the iter-1 `tool_choice` override that pins `memory_search` on the first ReAct iteration.

## Bounded Contexts

One context only — the Jido↔Gralkor adaptation. No domain logic, no memory pipelines (those live in `:gralkor_ex`).

## Invariants

- Recall is LLM-driven via `MemorySearch`; the plugin never calls `Gralkor.Client.recall/4` directly.
- `session_id` is the Jido thread id from `agent.state[:__thread__].id` — never minted by the plugin.
- `agent_name` is required at mount; missing/blank raises `ArgumentError`.
- `user_name` is read per-turn from `agent.state[:user_name]`; capture raises on missing/blank.
- First-turn-on-fresh-agent: no thread yet → `MemorySearch` short-circuits, capture is skipped, only `agent_name` is planted.

## Decision Rationale

- The iter-1 `tool_choice` forcing is a workaround: `Jido.AI.Reasoning.ReAct.Config` lacks a `:preamble_tool` knob, and `tool_choice` is applied uniformly across the ReAct loop today. The helper exists to pin it for one iteration without forking the strategy.
- The plugin captures on every turn, regardless of whether tools were called, because distillation (in `:gralkor_ex`) decides what's memory-worthy — we don't gate at this layer.
- Interpret output budget knobs live under `:gralkor_ex` app env (read each recall by `Gralkor.Client.Native`), not under `:jido_gralkor` config. The plugin is documentation-only for that knob; the adapter holds the actual config surface.

## Temporal View

`ai.react.query` → plant `:session_id` (if thread committed) + `:agent_name` on signal `tool_context` → ReAct strategy invokes the LLM with the forced `tool_choice` on iter-1 → `MemorySearch` runs against `Gralkor.Client.recall/4` → ReAct loops → `ai.request.completed`/`failed` → `Canonical.to_messages/3` normalises the turn → `Gralkor.Client.capture/5` ingests. On AgentServer termination, `Lifecycle.terminate/2` fires a fire-and-forget `Gralkor.Client.flush/1`. On manual rotate (`/new`), `ContextRotator.rotate_now/2` flushes synchronously, installs a fresh thread, emits a compaction signal.
