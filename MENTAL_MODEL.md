## Core Domain Identity

This repository is the canonical development and distribution home for Jido-first Gralkor. The `JidoGralkor.*` layer owns Jido↔Gralkor wiring; the embedded `Gralkor.*` layer owns memory-domain behavior, and applications extend it with Lens ingestion modules.

## World-to-Code Mapping

- **`JidoGralkor.Plugin`** — the Jido hook that watches `ai.react.query` / `ai.request.completed` / `ai.request.failed` signals and plants context / fires captures.
- **`JidoGralkor.Actions.MemorySearch` / `MemoryAdd` / `MemoryBuildIndices` / `MemoryBuildCommunities`** — the plugin's four ReAct tools; `MemorySearch` is the only recall path (no auto-recall in the plugin), and the two build actions are description-gated operator maintenance.
- **`JidoGralkor.ReAct.maybe_force_memory_search/2`** — folds `tool_choice` into the consumer's transformer overrides on iter-1, making recall agentic.
- **`JidoGralkor.Canonical.to_messages/3`** — normalises a Jido/ReAct turn into Gralkor's `[%Message{role, content}]` shape.
- **`JidoGralkor.Lifecycle`** — graceful-shutdown flush via the configured Gralkor client adapter's `flush/1`.
- **`JidoGralkor.ContextRotator`** — synchronous rotate-on-demand: flush, retain recent and in-flight entries, then install a fresh thread.
- **`Gralkor.Client` / `Gralkor.Ingest` / `Gralkor.Replace` / `Gralkor.Search`** — the callable Lens boundary and its request values. An appending `Gralkor.Lens` owns its ontology and ingestion module; a `Gralkor.Lens.Replaceable` owns its complete graph format; both own a name and operator-or-global scope. `Gralkor.Lens.Store` owns group resolution, provenance, and graph ownership; `Gralkor.Lens.Ingestion.ingest/2` is the callback an application implements, and `Gralkor.Lens.Ingestion.Generalise` is the built-in generalising one.

## Ubiquitous Language

- *plugin* — `Jido.Plugin` mounted on a `use Jido` supervisor.
- *thread* — a Jido conversation segment; its `id` is the Gralkor `session_id`.
- *agent_name* — the assistant's display name; required at mount; renders all assistant turns in graphiti.
- *user_name* — the human's name per turn; stashed on `agent.state[:user_name]` by the consumer.
- *forced recall* — the iter-1 `tool_choice` override that pins `memory_search` on the first ReAct iteration.
- *operator* — the application identity whose local memory is isolated; it is not a Lens and does not determine global visibility.
- *Lens* — a named, scoped memory channel. An appending Lens has an ontology and ingestion process; a replaceable Lens has a complete graph format. Reserved `default` is the operator's baseline Lens and reserved `global` names the shared group.
- *group* — where episodes are stored; graphiti's `group_id`, and its own FalkorDB database, so isolation between groups is physical rather than a filter applied at search time. Every Lens resolves to one: an operator Lens to a group derived from the operator id and Lens name, every global Lens to the one shared `global` group, which is searched unfiltered by originating Lens.
- *episode* — the unit written to graphiti; an episode search reads back the body that was written, while node and edge search return what the extractor derived from it.
- *fact* — the text of one edge an edge search returned; recall interprets facts, it does not adjudicate them.
- *node* — one entity graphiti extracted; a custom entity type (`Learning`) is reachable by node search alone, edge search matching edges by their endpoints.
- *entity description* — the sentence an ontology entity carries; graphiti's extractor reads it to decide when to mint that entity.
- *role* — one of the two inference slots, `llm` or `embedder`, each selecting its provider from its own model spec. The cross-encoder has no spec and follows the llm role; a credential is required only for a provider some role selects.

## Bounded Contexts

Two cooperating contexts live in this package: `Gralkor.*` owns the memory domain, while `JidoGralkor.*` adapts Jido signals, threads, actions, and lifecycle into that domain; Graphiti, Pythonx, and FalkorDB remain infrastructure inside the Gralkor context.

## Invariants

- Recall is LLM-driven via `MemorySearch`; the plugin never calls `Gralkor.Client.recall/4` directly.
- `session_id` is the Jido thread id from `agent.state[:__thread__].id` — never minted by the plugin.
- `agent_name` is required at mount; missing/blank raises `ArgumentError`.
- When a committed turn produces a non-empty capture, `user_name` is read from `agent.state[:user_name]`; missing/blank raises `ArgumentError`.
- First-turn-on-fresh-agent: no thread at query time → `MemorySearch` short-circuits, and Lens mounts still plant `agent_name`, `lens`, and `search_lenses` without a session id; capture is skipped only if no thread is committed when completion or failure is handled.
- A local Lens store resolves its group from the operator id and Lens name; every store write through a global Lens uses the shared global group.
- Public search always includes the requesting operator's reserved `"default"` Lens first and validates every selected Lens before any query begins. Naming a global Lens searches the whole shared global group, because that is the group its episodes live in; originating Lens is attribution, not a filter.
- Lens definitions are application-owned and selected by name. An appending Lens's callback controls zero, one, or many bound-store writes; a replaceable Lens atomically selects all graph content that Lens owns at its resolved destination. `Client.ingest/1` and `Client.replace/1` return their results without crossing write modes.
- Every recall carries its query through to interpretation as a required argument, whatever the buffered conversation holds.

## Decision Rationale

- The iter-1 `tool_choice` forcing is a workaround: `Jido.AI.Reasoning.ReAct.Config` lacks a `:preamble_tool` knob, and `tool_choice` is applied uniformly across the ReAct loop today. The helper exists to pin it for one iteration without forking the strategy.
- Capture is not gated on calling a memory tool: completed or failed turns with a committed thread and non-empty canonical event trace are captured. Canonical filters empty turns, and the selected Lens ingestion process decides downstream retention.
- Recalled graph content is memory context, not adjudicated truth. Gralkor preserves and retrieves understandings extracted from source material without imposing confidence or verification semantics on the ontology; truth-sensitive verification belongs to the consuming application. That policy is carried by the interpretation prompt rather than by code, so a capable model's compliance with it is the only evidence it holds.
- The recall query travels to interpretation separately from the conversation because a recall may come from a session that never carried it — a fresh session, or a `memory_search` whose query is not the last thing the user said — so the buffered conversation alone cannot say what was asked.
- What graphiti derives from an episode is not knowable in advance: a statement naming one subject yields a node and no edge, and on another run may yield neither. Retrieval therefore matches the primitive to what was stored — episode search returns the body Gralkor wrote and must read back verbatim, node and edge search return what the extractor derived — and a custom entity type carries a description, because that is what the extractor reads to decide when to mint it.
- Consumer configuration is read from the `:jido_gralkor` app env and documented system environment variables. Request-time settings resolve per call; startup backend selection through `:falkordb` or `GRALKOR_DATA_DIR` requires restarting the application.
- Ontology selection belongs to the selected Lens. The implicit `"default"` Lens retains deployment-wide `:ontology` as the compatibility path for calls or mounts that do not select a registered Lens.
- Generalisation is an ingestion process, not a kind of group. `Gralkor.Lens.Ingestion.Generalise` distils durable episodes and adds them through its bound store; Graphiti's normal episode ingestion owns fact reconciliation, while the selected Lens determines ontology and local/global placement.
- The embedded Python stack is a consumer-invisible internal concern: `Gralkor.Python.init/1` reads jido_gralkor's packaged `priv/python/pyproject.toml` and supplies it directly to `Pythonx.uv_init/1`. Dependency application config does not propagate into a consumer, so owning the manifest prevents consumers from restating and drifting the Python dependency set.
- Ontology-kwarg selection and inference-provider selection are made first in pure Elixir — `graphiti_boundary_spec/1` decides which `add_episode` kwargs an ontology populates, and `shared_client_spec/2` decides which provider builds each role's client and which OpenAI reasoning tier reaches Graphiti (`none` for GPT-5.5 and GPT-5.6, `auto` otherwise). Those decisions are pinned deterministically without Python, a real LLM, or credentials. Boundary data crosses as explicit arguments: the embedded interpreter shares the OS process but not Erlang's environment table, so `os:putenv` never reaches `os.environ` and `api_key!/1` hands each provider client its credential rather than letting Python read the variable.
- `Gralkor.Ontology` declares each relationship once (`from Source do verb Target end`) and derives graphiti's `edge_types` + `edge_type_map` automatically. Graphiti's split between those two dicts is the modelled-once-mentioned-twice trap the DSL exists to remove. `relationships: :scoped` does not forbid generic edges — graphiti always extracts edge candidates and only constrains *which named class* they conform to between declared `(src, dst)` pairs; closing the world on edges would require post-filtering not yet implemented.

## Temporal View

`ai.react.query` → plant `:session_id` when committed plus `:agent_name`, selected `:lens`, and additional `:search_lenses`, retaining the selected Lens on the request-correlated Jido thread entry → ReAct tools ingest through the default or per-turn Lens and search the operator's reserved `default` Lens followed by each additional selected Lens → a completed or failed request with a committed thread and non-empty canonical trace is buffered under the retained and optional generalising Lenses → flush submits each Lens batch independently. With a committed thread, AgentServer termination starts a fire-and-forget flush. Manual rotation without a thread is a no-op; otherwise `ContextRotator.rotate_now/2` installs a fresh thread seeded with retained and in-flight entries only after a successful synchronous flush, and preserves the current thread when flushing fails.
