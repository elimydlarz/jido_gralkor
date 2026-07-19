## Core Domain Identity

The `JidoGralkor.*` layer owns Jido↔Gralkor wiring; the embedded `Gralkor.*` layer owns memory-domain behavior, and applications extend it with Lens ingestion modules.

## World-to-Code Mapping

- **`JidoGralkor.Plugin`** — the Jido hook that watches `ai.react.query` / `ai.request.completed` / `ai.request.failed` signals and plants context / fires captures.
- **`JidoGralkor.Actions.MemorySearch` / `MemoryAdd`** — ReAct tools the LLM calls; `MemorySearch` is the only recall path (no auto-recall in the plugin).
- **`JidoGralkor.ReAct.maybe_force_memory_search/2`** — folds `tool_choice` into the consumer's transformer overrides on iter-1, making recall agentic.
- **`JidoGralkor.Canonical.to_messages/3`** — normalises a Jido/ReAct turn into Gralkor's `[%Message{role, content}]` shape.
- **`JidoGralkor.Lifecycle`** — graceful-shutdown flush via `Gralkor.Client.flush/1`.
- **`JidoGralkor.ContextRotator`** — synchronous rotate-on-demand (flush + fresh thread + compaction signal).
- **`Gralkor.Lens` / `Gralkor.Ingest` / `Gralkor.Search`** — the consumer-facing memory boundary. A registered Lens owns its name, ontology, operator-or-global scope, and ingestion module; the Lens-bound store owns physical partitioning and provenance.

## Ubiquitous Language

- *plugin* — `Jido.Plugin` mounted on a `use Jido` supervisor.
- *thread* — a Jido conversation segment; its `id` is the Gralkor `session_id`.
- *agent_name* — the assistant's display name; required at mount; renders all assistant turns in graphiti.
- *user_name* — the human's name per turn; stashed on `agent.state[:user_name]` by the consumer.
- *forced recall* — the iter-1 `tool_choice` override that pins `memory_search` on the first ReAct iteration.
- *operator* — the application identity whose local memory is isolated; it is not a Lens and does not determine global visibility.
- *Lens* — a named ingestion channel with an ontology, an ingestion process, and `:operator` or `:global` scope.
- *global pool* — the one shared destination used by every global Lens. Global episodes retain their originating Lens, while global search is deliberately unfiltered.

## Bounded Contexts

Two cooperating contexts live in this package: `Gralkor.*` owns the memory domain, while `JidoGralkor.*` adapts Jido signals, threads, actions, and lifecycle into that domain; Graphiti, Pythonx, and FalkorDB remain infrastructure inside the Gralkor context.

## Invariants

- Recall is LLM-driven via `MemorySearch`; the plugin never calls `Gralkor.Client.recall/4` directly.
- `session_id` is the Jido thread id from `agent.state[:__thread__].id` — never minted by the plugin.
- `agent_name` is required at mount; missing/blank raises `ArgumentError`.
- `user_name` is read per-turn from `agent.state[:user_name]`; capture raises on missing/blank.
- First-turn-on-fresh-agent: no thread yet → `MemorySearch` short-circuits, capture is skipped, and Lens mounts still plant `agent_name`, `lens`, and `search_targets` without a session id.
- A local Lens partitions by operator and Lens name; every global Lens writes to the shared global partition.
- Only the reserved `"global"` target searches the global pool. A global Lens name records ingestion provenance and is not a sound search filter.
- A Lens ingestion callback controls whether one request causes zero, one, or many store writes; storage failures are returned without falling back to another path.

## Decision Rationale

- The iter-1 `tool_choice` forcing is a workaround: `Jido.AI.Reasoning.ReAct.Config` lacks a `:preamble_tool` knob, and `tool_choice` is applied uniformly across the ReAct loop today. The helper exists to pin it for one iteration without forking the strategy.
- The plugin captures on every turn, regardless of whether tools were called, because the embedded `Gralkor.Distill` decides what's memory-worthy — we don't gate at this layer.
- Recalled graph content is memory context, not adjudicated truth. Gralkor preserves and retrieves understandings extracted from source material without imposing confidence or verification semantics on the ontology; truth-sensitive verification belongs to the consuming application.
- Consumer-facing configuration lives under the `:jido_gralkor` app env. Request settings are resolved per call; startup backend settings such as `:falkordb` require an application restart.
- Ontology selection belongs to the Lens. The implicit `"default"` Lens retains the deployment-wide `:ontology` only as the compatibility path for consumers that have not adopted a Lens registry.
- Generalisation is an ingestion process, not a partition type. `Gralkor.Lens.Ingestion.Generalise` reads, updates, and removes through its bound store, so the selected Lens determines ontology and local/global placement.
- The embedded Python stack is a consumer-invisible internal concern: `Gralkor.Python.init/1` materialises the venv via `Pythonx.uv_init/2` from jido_gralkor's own `priv/python/pyproject.toml`, so consumers configure *nothing* about Python. The Python deps must live in jido_gralkor's packaged manifest rather than `config/config.exs` because a dep's config does not propagate to a consumer's runtime app env and Pythonx reads its pin via `Application.compile_env` — leaving it in config forced every consumer to restate (and silently drift on) the graphiti-core version.
- `Gralkor.Ontology` declares each relationship once (`from Source do verb Target end`) and derives graphiti's `edge_types` + `edge_type_map` automatically. Graphiti's split between those two dicts is the modelled-once-mentioned-twice trap the DSL exists to remove. `relationships: :scoped` does not forbid generic edges — graphiti always extracts edge candidates and only constrains *which named class* they conform to between declared `(src, dst)` pairs; closing the world on edges would require post-filtering not yet implemented.

## Temporal View

`ai.react.query` → plant `:session_id` (if committed), `:agent_name`, selected `:lens`, and `:search_targets` → ReAct tools ingest through the default/per-turn Lens and search the selected local Lenses plus optional global pool → `ai.request.completed`/`failed` → `Canonical.to_messages/3` normalises one turn → capture buffers the turn under the selected and optional generalising Lenses → flush submits each Lens batch independently. On AgentServer termination, `Lifecycle.terminate/2` fires a fire-and-forget flush. On manual rotate (`/new`), `ContextRotator.rotate_now/2` flushes synchronously, installs a fresh thread, and emits a compaction signal.
