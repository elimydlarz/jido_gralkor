# Test Strategy

The test kind identifies the consumer seam. Hook timing does not change a test's kind.

## Unit

- Consumer seam: one module's public functions or callbacks.
- Controllable conditions: direct arguments, application configuration restored by the test, process messages, and test-owned dependency callbacks.
- Observable outcomes: return values, raised errors, process state exposed through the subject's public API, emitted messages, logs, and requests made to mocked dependencies.
- Real boundaries: the subject under test only.
- Substituted boundaries: every dependency outside the subject is replaced by a deterministic test-owned callback, module, process, or configured client; assertions may cover only the subject's request to that substitute.
- Focused invocation: `mix test.unit path/to/unit_test.exs`.
- Complete lifecycle command: `mix test` together with Integration tests.

## Integration

- Consumer seam: one parent module observed through its public interface with its real child modules.
- Controllable conditions: public inputs, application configuration restored by the test, in-memory state, supervised processes, and deterministic substitutes beyond the parent subject.
- Observable outcomes: public returns and errors, process lifecycle and state exposed at the parent seam, emitted messages and logs, and requests crossing a substituted external boundary.
- Real boundaries: the parent subject and its child modules.
- Substituted boundaries: services outside the parent and its children are deterministic test-owned clients or callbacks; assertions may cover only requests made to those boundaries.
- Focused invocation: `mix test.integration path/to/integration_test.exs`.
- Complete lifecycle command: `mix test` together with Unit tests.

## Functional

- Consumer seam: the exported Gralkor and JidoGralkor memory capabilities used by an application or agent.
- Controllable conditions: public function inputs, agent and application lifecycle, declared destinations, lenses and reflections, test-owned in-memory clients, isolated embedded Graphiti state, and focused real-provider fixtures where the capability itself crosses that boundary.
- Observable outcomes: public returns and errors, memory content and provenance, agent-visible instructions, persisted graph effects observed through public search, process lifecycle, logs, and requests made to deterministic external-boundary substitutes.
- Real boundaries: all internal production modules; focused provider and embedded Graphiti boundaries remain real when the Functional subject requires their behavior.
- Substituted boundaries: external systems may be replaced only by deterministic test-owned clients at the system boundary; assertions may cover the system's request to a substitute but not completion by a real external system.
- Focused invocation: `mix test.functional path/to/functional_test.exs`.
- Complete lifecycle command: `mix test.functional`.

## Journey

- Consumer seam: one curated operator lifecycle through the exported Gralkor memory API.
- Controllable conditions: public memory requests, isolated destination and lens configuration, a test-owned data directory, embedded FalkorDB, Graphiti, PythonX, and configured model-provider credentials.
- Observable outcomes: public memory results with source provenance, graph replacement and recall across operators and destinations, reflection effects, and cleanup of the production-like runtime.
- Real boundaries: production Gralkor modules, PythonX, Graphiti, embedded FalkorDB, and configured model providers.
- Substituted boundaries: none in the current Journey.
- Focused invocation: `mix test.journey path/to/journey_test.exs`.
- Complete lifecycle command: `mix test.journey`.

## Commands and lifecycle

- `mix test` runs every Unit and Integration test and excludes Functional and Journey.
- `mix test.functional` runs every Functional test.
- `mix test.journey` owns the complete production-like Journey lifecycle.
- `mix test.changed` uses ExUnit's stale dependency tracking to select changed or related Unit, Integration, and Functional tests and excludes Journey.
- `mix test.fast` uses ExUnit's stale dependency tracking to select changed or related Unit and Integration tests and excludes Functional and Journey.
- `mix test.all` runs Unit, Integration, Functional, Journey, and Node tests and fails when either runner fails.
- `PostToolUse` after `Edit` or `Write` starts `mix test.fast` optimistically and returns without waiting.
- `Stop` first delivers saved optimistic failures, waits for active optimistic work, and then runs `mix test` synchronously.
- During Functional RED and GREEN, the coding agent runs only the current focused Functional test.
- When implementation appears finished, the coding agent runs `mix test.functional`.
- After a Journey tree or test change, the coding agent runs `mix test.journey`.
- After a substantive production change affecting operator-visible behavior, a public interface, persistence, an external-system boundary, architecture boundaries, or orchestration spanning components, the coding agent runs `mix test.journey`.
- Documentation, formatting, and behavior-preserving local refactors do not trigger Journey.
- Setup and CI own `mix test.all`; ordinary coding-agent work does not duplicate it.
