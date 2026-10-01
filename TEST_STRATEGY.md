# Test Strategy

The test kind identifies the consumer seam. Hook timing does not change a test's kind.

## Unit

- Consumer seam: one module's public functions or callbacks.
- Controllable conditions: direct arguments, application configuration restored by the test, process messages, and test-owned dependency callbacks.
- Observable outcomes: return values, raised errors, process state exposed through the subject's public API, emitted messages, logs, and requests made to mocked dependencies.
- Real boundaries: the subject under test only.
- Substituted boundaries: every dependency outside the subject is replaced by a deterministic test-owned callback, module, process, or configured client; assertions may cover only the subject's request to that substitute.
- Focused invocation: `mix test.unit path/to/unit_test.exs` for ExUnit subjects; `node --test path/to/unit_test.mjs` for Node contract subjects.
- Complete lifecycle command: `mix test` together with Integration tests, followed by `node --test` for Node contract subjects through the Stop feedback check.

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
- `mix test.unit` runs Unit tests only by excluding the `integration`, `functional`, and `journey` tags.
- `mix test.integration` runs only tests tagged `integration`.
- `mix test.functional` runs every Functional test.
- `mix test.journey` owns the complete production-like Journey lifecycle.
- `mix test.changed` uses ExUnit's stale dependency tracking to select changed or related Unit, Integration, and Functional tests and excludes Journey.
- `mix test.fast` uses ExUnit's stale dependency tracking to select changed or related Unit and Integration tests and excludes Functional and Journey.
- `mix test.all` runs Unit, Integration, Functional, Journey, and Node tests and fails when either runner fails.
- `PostToolUse` after `Edit` or `Write` starts `mix test.fast` optimistically and returns without waiting. The check script uses `set -e`, so `node --test` runs only after `mix test.fast` passes. A failure is saved for later delivery.
- An edit made while optimistic feedback is running does not start a second run; it marks the active run, which runs its checks again after the current pass finishes.
- `Stop` first delivers saved failures and returns failure immediately when any are delivered. When the Stop input reports `stop_hook_active`, Stop then exits without running further checks.
- Otherwise Stop waits for active optimistic work, then runs every Stop check synchronously in file-name order: `readme-sync` runs `.fasset-harness/scripts/check-readme-sync.sh`, and `unit-integration-tests` runs `mix test` and then, because its script uses `set -e`, runs `node --test` only after `mix test` passes. Stop then delivers every saved failure.
- Saved failures are delivered together in file-name order. A combined report larger than 8192 bytes is written to `.fasset-harness/state/optimistic-feedback/diagnostics/`, and only its path is delivered.
- During Functional RED and GREEN, the coding agent runs only the current focused Functional test.
- When implementation appears finished, the coding agent runs `mix test.functional`.
- After a Journey tree or test change, the coding agent runs `mix test.journey`.
- After a substantive production change affecting operator-visible behavior, a public interface, persistence, an external-system boundary, architecture boundaries, or orchestration spanning components, the coding agent runs `mix test.journey`.
- Documentation, formatting, and behavior-preserving local refactors do not trigger Journey.
- Setup and CI own `mix test.all`; ordinary coding-agent work does not duplicate it.
- Do not run two test VMs against the embedded backend at the same time. The first `Gralkor.Python` boot in each VM kills every `redislite/bin/redis-server` process, and it cannot distinguish another VM's live server from an orphan. This applies to Functional and Journey runs that use the embedded backend.

The shared ExUnit helper initializes the packaged Python interpreter before tag selection. This test infrastructure initialization does not make a Unit subject's dependencies real: Unit tests still substitute every dependency outside their subject. Tests that execute the real embedded Python or Graphiti boundary are Integration or Functional tests, according to their consumer seam.
