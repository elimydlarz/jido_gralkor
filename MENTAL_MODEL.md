## Core Domain Identity

This repository is the canonical development and distribution home for Jido-first Gralkor. The `JidoGralkor.*` layer owns Jido↔Gralkor wiring; the embedded `Gralkor.*` layer owns memory-domain behavior. Applications extend ingestion with independent Lens definitions and post-ingestion synthesis with repository YAML Reflection definitions.

## World-to-Code Mapping

- **`JidoGralkor.Plugin`** — the Jido hook that watches `ai.react.query` / `ai.request.completed` / `ai.request.failed` signals and plants context / fires captures.
- **`JidoGralkor.Actions.MemorySearch` / `MemoryAdd` / `MemoryBuildIndices` / `MemoryBuildCommunities`** — the plugin's four ReAct tools; `MemorySearch` is the only recall path (no auto-recall in the plugin), and the two build actions are description-gated operator maintenance.
- **`JidoGralkor.ReAct.maybe_force_memory_search/2`** — folds `tool_choice` into the consumer's transformer overrides on iter-1, making recall agentic.
- **`JidoGralkor.Canonical.to_messages/3`** — normalises a Jido/ReAct turn into Gralkor's `[%Message{role, content}]` shape.
- **`JidoGralkor.Lifecycle`** — graceful-shutdown flush via the configured Gralkor client adapter's `flush/1`.
- **`JidoGralkor.ContextRotator`** — synchronous rotate-on-demand: flush, retain recent and in-flight entries, then install a fresh thread.
- **`Gralkor.Client` / `Gralkor.Ingest` / `Gralkor.Replace` / `Gralkor.Search`** — the callable memory boundary and request values. `Gralkor.Lens`, `Gralkor.Lens.Replaceable`, and `Gralkor.Lens.Store` own independent ingestion views, placement, provenance, and graph ownership. `Gralkor.Reflection.Registry`, `ChainOfThought`, `Runner`, `Scheduler`, and `Store` load YAML processes, run them after completed Lens ingestion, and persist/search their artefacts in a separate namespace.

## Ubiquitous Language

- *plugin* — `Jido.Plugin` mounted on a `use Jido` supervisor.
- *thread* — a Jido conversation segment; its `id` is the Gralkor `session_id`.
- *agent_name* — the assistant's display name; required at mount; renders all assistant turns in graphiti.
- *user_name* — the human's name per turn; stashed on `agent.state[:user_name]` by the consumer.
- *forced recall* — the iter-1 `tool_choice` override that pins `memory_search` on the first ReAct iteration.
- *operator* — the application identity whose local memory is isolated; it is not a Lens and does not determine global visibility.
- *Lens* — a named, scoped memory channel. An appending Lens has an ontology and ingestion process; a replaceable Lens has a complete graph format. Reserved `operator` is the requesting operator's baseline Lens and reserved `global` names the shared group.
- *Reflection* — an asynchronous post-ingestion process with its own name and operator-or-global destination. Its repository YAML Chain of Thought runs ordered inference turns over the completed operation's lensed representations, interpolates prior structured outputs, may direct any host tool through natural-language steps, and stores exactly one evidence-linked artefact. Reflection names form their own search namespace rather than naming Lenses.
- *group* — where episodes are stored; graphiti's `group_id`, and its own FalkorDB database, so isolation between groups is physical rather than a filter applied at search time. Every Lens resolves to one: an operator Lens to a group derived from the operator id and Lens name, every global Lens to the one shared `global` group, which is searched unfiltered by originating Lens.
- *episode* — the unit written to graphiti; an episode search reads back the body that was written, while node and edge search return what the extractor derived from it.
- *fact* — the text of one edge an edge search returned; recall interprets facts, it does not adjudicate them.
- *node* — one entity graphiti extracted; node search returns entities directly, while edge search matches relationships by their endpoints.
- *entity description* — the sentence an ontology entity carries; graphiti's extractor reads it to decide when to mint that entity.
- *role* — one of the two inference slots, `llm` or `embedder`, each selecting its provider from its own model spec. The cross-encoder has no spec and follows the llm role; a credential is required only for a provider some role selects.

## Bounded Contexts

Two cooperating contexts live in this package: `Gralkor.*` owns the memory domain, while `JidoGralkor.*` adapts Jido signals, threads, actions, lifecycle, host tools, and tool context into that domain. Within Gralkor, Lenses ingest information without referring to one another; Reflections operate asynchronously over completed lensed representations and own separate destinations. Graphiti, Pythonx, and FalkorDB remain infrastructure inside the Gralkor context.

## Invariants

- Recall is LLM-driven via `MemorySearch`; the plugin never calls `Gralkor.Client.recall/4` directly.
- `session_id` is the Jido thread id from `agent.state[:__thread__].id` — never minted by the plugin.
- `agent_name` is required at mount; missing/blank raises `ArgumentError`.
- When a committed turn produces a non-empty capture, `user_name` is read from `agent.state[:user_name]`; missing/blank raises `ArgumentError`.
- First-turn-on-fresh-agent: no thread at query time → `MemorySearch` short-circuits, and Lens mounts still plant `agent_name`, `lens`, and `search_lenses` without a session id; capture is skipped only if no thread is committed when completion or failure is handled.
- A local Lens store resolves its group from the operator id and Lens name; every store write through a global Lens uses the shared global group.
- Public search validates every selected Lens and its positive result limit before any query begins, always includes the reserved `"operator"` destination for the requesting operator, collapses every selected global Lens name to one shared `"global"` destination, and searches all distinct destinations concurrently. Results retain configured Lens order and identify the searched Lens for every fact; repeated facts from distinct local groups remain distinct.
- Lens definitions are application-owned and selected by name. An appending Lens's callback controls zero, one, or many bound-store writes; a replaceable Lens validates one complete graph before deleting and recreating the graph content tagged with that Lens at its resolved destination. `Client.ingest/1` and `Client.replace/1` return storage results without crossing write modes; replacement import failures do not roll back completed storage mutations.
- Reflections are scheduled once only after all intended Lens ingestions succeed; each receives every completed lensed representation, and one Reflection's failure does not prevent another from running or storing its result.
- Every valid Reflection has a unique name, an operator-or-global destination scope, and a repository YAML CoT with ordered exact-output steps; a successful run stores exactly one artefact. Reflection search names Reflections separately from Lenses and may narrow to an exact `artefact_id`.
- Every recall carries its query through to interpretation as a required argument, whatever the buffered conversation holds.

## Decision Rationale

- The iter-1 `tool_choice` forcing is a workaround: `Jido.AI.Reasoning.ReAct.Config` lacks a `:preamble_tool` knob, and `tool_choice` is applied uniformly across the ReAct loop today. The helper exists to pin it for one iteration without forking the strategy.
- Capture is not gated on calling a memory tool: completed or failed turns with a committed thread and non-empty canonical event trace are captured. Canonical filters empty turns, and the selected Lens ingestion process decides downstream retention.
- Recalled graph content is memory context, not adjudicated truth. Gralkor preserves and retrieves understandings extracted from source material without imposing confidence or verification semantics on the ontology; truth-sensitive verification belongs to the consuming application. That policy is carried by the interpretation prompt rather than by code, so a capable model's compliance with it is the only evidence it holds.
- The recall query travels to interpretation separately from the conversation because a recall may come from a session that never carried it — a fresh session, or a `memory_search` whose query is not the last thing the user said — so the buffered conversation alone cannot say what was asked.
- What graphiti derives from an episode is not knowable in advance: a statement naming one subject yields a node and no edge, and on another run may yield neither. Retrieval therefore matches the primitive to what was stored — episode search returns the body Gralkor wrote and must read back verbatim, node and edge search return what the extractor derived — and a custom entity type carries a description, because that is what the extractor reads to decide when to mint it.
- Consumer configuration is read from the `:jido_gralkor` app env and documented system environment variables. Request-time settings resolve per call; startup backend selection through `:falkordb` or `GRALKOR_DATA_DIR` requires restarting the application.
- Ontology selection belongs to the selected Lens. The implicit `"operator"` Lens retains deployment-wide `:ontology` as the compatibility path for calls or mounts that do not select a registered Lens.
- Generalisation and experiential learning are packaged Reflection declarations rather than Lens types: both operate over whatever lensed information completed ingestion produced, while their YAML CoTs own their distinct synthesis behaviour. Reflection destinations and search attribution preserve the producing Reflection's identity without coupling Lens definitions.
- The embedded Python stack is a consumer-invisible internal concern: `Gralkor.Python.init/1` reads jido_gralkor's packaged `priv/python/pyproject.toml` and supplies it directly to `Pythonx.uv_init/1`. Dependency application config does not propagate into a consumer, so owning the manifest prevents consumers from restating and drifting the Python dependency set.
- Ontology-kwarg selection and inference-provider selection are made first in pure Elixir — `graphiti_boundary_spec/1` decides which `add_episode` kwargs an ontology populates, and `shared_client_spec/2` decides which provider builds each role's client and which OpenAI reasoning tier reaches Graphiti (`none` for GPT-5.5 and GPT-5.6, `auto` otherwise). Those decisions are pinned deterministically without Python, a real LLM, or credentials. Boundary data crosses as explicit arguments: the embedded interpreter shares the OS process but not Erlang's environment table, so `os:putenv` never reaches `os.environ` and `api_key!/1` hands each provider client its credential rather than letting Python read the variable.
- `Gralkor.Ontology` declares each relationship once (`from Source do verb Target end`) and derives graphiti's `edge_types` + `edge_type_map` automatically. Graphiti's split between those two dicts is the modelled-once-mentioned-twice trap the DSL exists to remove. `relationships: :scoped` does not forbid generic edges — graphiti always extracts edge candidates and only constrains *which named class* they conform to between declared `(src, dst)` pairs; closing the world on edges would require post-filtering not yet implemented.

## Temporal View

`ai.react.query` → plant `:session_id` when committed plus `:agent_name`, selected `:lens`, and additional `:search_lenses`, retaining the selected Lens and host Reflection context on the request-correlated Jido thread entry → ReAct tools ingest through the configured or per-turn Lens and concurrently search distinct Lens destinations → a completed or failed request with a committed thread and non-empty canonical trace is buffered for its intended Lenses → flush completes every Lens batch and collects evidence-linked representations → schedule each declared Reflection independently → its ordered YAML steps may call host tools, interpolate validated structured outputs, and store one artefact in the Reflection's named destination. With a committed thread, AgentServer termination starts a fire-and-forget flush. Manual rotation without a thread is a no-op; otherwise `ContextRotator.rotate_now/2` installs a fresh thread seeded with retained and in-flight entries only after a successful synchronous flush, and preserves the current thread when flushing fails.
