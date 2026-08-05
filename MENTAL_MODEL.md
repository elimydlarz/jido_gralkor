## Core Domain Identity

This repository is the canonical development and distribution home for Jido-first Gralkor. The `JidoGralkor.*` layer owns Jido↔Gralkor wiring; the embedded `Gralkor.*` layer owns memory-domain behavior, and applications extend it with Lens ingestion modules.

## World-to-Code Mapping

- **`JidoGralkor.Plugin`** — the Jido hook that watches `ai.react.query` / `ai.request.completed` / `ai.request.failed` signals and plants context / fires captures.
- **`JidoGralkor.Actions.MemorySearch` / `MemoryAdd`** — ReAct tools the LLM calls; `MemorySearch` is the only recall path (no auto-recall in the plugin).
- **`JidoGralkor.ReAct.maybe_force_memory_search/2`** — folds `tool_choice` into the consumer's transformer overrides on iter-1, making recall agentic.
- **`JidoGralkor.Canonical.to_messages/3`** — normalises a Jido/ReAct turn into Gralkor's `[%Message{role, content}]` shape.
- **`JidoGralkor.Lifecycle`** — graceful-shutdown flush via `Gralkor.Client.flush/1`.
- **`JidoGralkor.ContextRotator`** — synchronous rotate-on-demand: flush, retain recent and in-flight entries, then install a fresh thread.
- **`Gralkor.Client` / `Gralkor.Ingest` / `Gralkor.Search`** — the callable Lens boundary and its request values. A registered `Gralkor.Lens` owns its name, ontology, operator-or-global scope, and ingestion module; `Gralkor.Lens.Store` owns physical partitioning and provenance.

## Ubiquitous Language

- *plugin* — `Jido.Plugin` mounted on a `use Jido` supervisor.
- *thread* — a Jido conversation segment; its `id` is the Gralkor `session_id`.
- *agent_name* — the assistant's display name; required at mount; renders all assistant turns in graphiti.
- *user_name* — the human's name per turn; stashed on `agent.state[:user_name]` by the consumer.
- *forced recall* — the iter-1 `tool_choice` override that pins `memory_search` on the first ReAct iteration.
- *operator* — the application identity whose local memory is isolated; it is not a Lens and does not determine global visibility.
- *Lens* — a named ingestion channel with an ontology, an ingestion process, and `:operator` or `:global` scope; reserved `default` is the operator's baseline memory destination.
- *global pool* — the one shared destination used by every global Lens. Global episodes retain their originating Lens, while global search is deliberately unfiltered.
- *role* — one of the two inference slots, `llm` or `embedder`, each selecting its provider from its own model spec. The cross-encoder has no spec and follows the llm role; a credential is required only for a provider some role selects.

## Bounded Contexts

Two cooperating contexts live in this package: `Gralkor.*` owns the memory domain, while `JidoGralkor.*` adapts Jido signals, threads, actions, and lifecycle into that domain; Graphiti, Pythonx, and FalkorDB remain infrastructure inside the Gralkor context.

## Invariants

- Recall is LLM-driven via `MemorySearch`; the plugin never calls `Gralkor.Client.recall/4` directly.
- `session_id` is the Jido thread id from `agent.state[:__thread__].id` — never minted by the plugin.
- `agent_name` is required at mount; missing/blank raises `ArgumentError`.
- When a committed turn produces a non-empty capture, `user_name` is read from `agent.state[:user_name]`; missing/blank raises `ArgumentError`.
- First-turn-on-fresh-agent: no thread yet → `MemorySearch` short-circuits, capture is skipped, and Lens mounts still plant `agent_name`, `lens`, and `search_targets` without a session id.
- A local Lens store partitions by operator and Lens name; every store write through a global Lens uses the shared global partition.
- Public search always includes the requesting operator's reserved `"default"` destination first; a fully valid explicit selection adds local Lens destinations or reserved `"global"` before any query begins. Only `"global"` selects the global pool; a global Lens name is provenance.
- Lens definitions are application-owned and selected by name. The selected callback controls zero, one, or many bound-store writes; `Client.ingest/1` returns its result without an implicit fallback write.

## Decision Rationale

- The iter-1 `tool_choice` forcing is a workaround: `Jido.AI.Reasoning.ReAct.Config` lacks a `:preamble_tool` knob, and `tool_choice` is applied uniformly across the ReAct loop today. The helper exists to pin it for one iteration without forking the strategy.
- Capture is not gated on calling a memory tool: completed or failed turns with a committed thread and non-empty canonical event trace are captured. Canonical filters empty turns, and the selected Lens ingestion process decides downstream retention.
- Recalled graph content is memory context, not adjudicated truth. Gralkor preserves and retrieves understandings extracted from source material without imposing confidence or verification semantics on the ontology; truth-sensitive verification belongs to the consuming application.
- Consumer configuration is read from the `:jido_gralkor` app env and documented system environment variables. Request-time settings resolve per call; startup backend selection through `:falkordb` or `GRALKOR_DATA_DIR` requires restarting the application.
- Ontology selection belongs to the selected Lens. The implicit `"default"` Lens retains deployment-wide `:ontology` as the compatibility path for calls or mounts that do not select a registered Lens.
- Generalisation is an ingestion process, not a partition type. `Gralkor.Lens.Ingestion.Generalise` distils durable episodes and adds them through its bound store; Graphiti's normal episode ingestion owns fact reconciliation, while the selected Lens determines ontology and local/global placement.
- The embedded Python stack is a consumer-invisible internal concern: `Gralkor.Python.init/1` reads jido_gralkor's packaged `priv/python/pyproject.toml` and supplies it directly to `Pythonx.uv_init/2`. Dependency application config does not propagate into a consumer, so owning the manifest prevents consumers from restating and drifting the Python dependency set.
- Every decision the Pythonx boundary acts on is made first in a pure Elixir function that takes and returns plain data — `graphiti_boundary_spec/1` for which `add_episode` kwargs an ontology populates, `shared_client_spec/2` for which provider builds each role's client. The `Pythonx.eval` block is then left with nothing to decide, so the decision is pinned deterministically without Python, a real LLM, or credentials.
- `Gralkor.Ontology` declares each relationship once (`from Source do verb Target end`) and derives graphiti's `edge_types` + `edge_type_map` automatically. Graphiti's split between those two dicts is the modelled-once-mentioned-twice trap the DSL exists to remove. `relationships: :scoped` does not forbid generic edges — graphiti always extracts edge candidates and only constrains *which named class* they conform to between declared `(src, dst)` pairs; closing the world on edges would require post-filtering not yet implemented.

## Temporal View

`ai.react.query` → plant `:session_id` when committed plus `:agent_name`, selected `:lens`, and additional `:search_targets`, retaining the selected Lens on the request-correlated Jido thread entry → ReAct tools ingest through the default or per-turn Lens and search the operator's reserved `default` memory followed by selected local Lenses and optional global pool → a completed or failed request with a committed thread and non-empty canonical trace is buffered under the retained and optional generalising Lenses → flush submits each Lens batch independently. With a committed thread, AgentServer termination starts a fire-and-forget flush. Manual rotation without a thread is a no-op; otherwise `ContextRotator.rotate_now/2` installs a fresh thread seeded with retained and in-flight entries only after a successful synchronous flush, and preserves the current thread when flushing fails.
