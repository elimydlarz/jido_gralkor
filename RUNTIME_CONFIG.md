# Runtime Configuration

## Purpose

The consumer owns the durable source of truth for Gralkor's domain configuration. Gralkor owns one validated in-memory snapshot used by memory operations on the current BEAM node.

The consumer stores configuration in its database, loads it during application startup, and pushes the complete active configuration to Gralkor after every committed change. Gralkor does not know about the database, poll it, subscribe to it, or persist a second copy.

This document describes intended behaviour. The current implementation does not yet provide it.

## Configuration boundary

One runtime configuration contains the complete consumer-defined set of:

- Destinations
- Lenses
- Reflections

The packaged `operator` and `global` Destinations remain permanently available and are not supplied by the consumer. The packaged `operator` Lens remains the fixed default ingestion Lens and is not configurable.

Deployment concerns are not part of runtime domain configuration. FalkorDB connection details, model selection, credentials, operational timeouts, and internal test adapters remain separate from this API.

Agent identity, user identity, tools, tool context, Lens selection, and search selectors are invocation data rather than configuration.

## Consumer lifecycle

The consumer performs the same synchronization at startup and after a change:

1. Read the complete desired configuration from its database.
2. Call `Gralkor.RuntimeConfig.replace/1` with that complete value.
3. Continue only after the call returns `:ok`.
4. Surface a returned validation error and keep the previously active configuration in service.

Each BEAM node owns its own in-memory snapshot. The consumer is responsible for delivering the complete configuration to every node and for replaying it after a node or application restart. Calls are applied in call order; the last successful replacement wins.

Before the consumer installs configuration, only the packaged Destinations and packaged `operator` Lens exist. Named consumer Lenses and Reflections fail as unknown.

## Public replacement operation

The public operation is a synchronous, whole-state replacement:

```elixir
Gralkor.RuntimeConfig.replace(%{
  destinations: destination_definitions,
  lenses: lens_definitions,
  reflections: reflection_definitions
})
```

Incremental register, update, and delete operations are intentionally absent. The consumer already owns the complete durable state, and whole-state replacement prevents ordering windows in which a Lens or Reflection references a Destination that is not active yet.

`replace/1`:

- accepts all three collections as required lists;
- validates and resolves the complete candidate before changing active state;
- activates the three registries as one snapshot;
- returns `:ok` only after that snapshot is active;
- returns an explicit tagged validation error without changing active state;
- accepts empty consumer collections;
- rejects blank or duplicate names and malformed definitions;
- rejects names reserved by packaged definitions;
- rejects every Lens or Reflection Destination output whose Destination is absent from the candidate plus packaged Destinations;
- validates Lens write behaviour, ontology, ingestion module, and graph format;
- validates every Reflection output and inline Chain of Thought completely.

Reads observe either the complete previous snapshot or the complete replacement. They never observe a mixture.

## Definition shape

Runtime definitions are structured Elixir data. They contain no file paths and require no filesystem access.

An illustrative complete value is:

```elixir
%{
  destinations: [
    %{name: "project"}
  ],
  lenses: [
    %{
      name: "observations",
      destination: "project",
      write: :append,
      ingestion: Gralkor.Lens.Ingestion.Store,
      ontology: MyApp.ObservationOntology
    }
  ],
  reflections: [
    %{
      name: "release-review",
      outputs: [
        %{
          kind: :destination,
          destination: "project",
          ontology: MyApp.ReleaseOntology
        },
        %{
          kind: :return,
          handler: MyApp.ReleaseReviewHandler
        }
      ],
      chain_of_thought: %{
        steps: [
          %{
            label: "review",
            directions: "Review the supplied release evidence.",
            output: %{
              "assessment" => "string",
              "approved" => "boolean"
            }
          }
        ]
      }
    }
  ]
}
```

Reflection definitions have no trigger declaration. Lens definitions have no configurable default designation.

Every Reflection declares exactly one Destination output and at most one return-handler output. Its Destination output selects the extraction ontology, defaulting to `Gralkor.DefaultOntology`. A return handler implements the existing `Gralkor.Artefact.ReturnHandler.return/3` contract.

The existing Chain-of-Thought rules remain: steps are ordered and non-empty; labels and directions are non-blank; output contracts are non-empty and typed; output names are unique across steps; and interpolation can reference only an output declared by an earlier step.

## Runtime replacement semantics

An operation resolves the relevant definition once when that operation is accepted. A later configuration replacement does not mutate an operation already underway.

For Lenses:

- omitting a Lens continues to select the fixed packaged `operator` Lens;
- a consumer overrides that default only on the individual ingestion or capture operation;
- a subsequent named ingestion uses the current Lens definition;
- removing a Lens makes subsequent selection of that name fail;
- changing or removing a Lens does not migrate or delete information already stored;
- stored provenance retains the Lens name used when the information was written.

For Reflections:

- a subsequent invocation resolves the current Reflection definition by name;
- removing a Reflection makes subsequent invocation of that name fail;
- an invocation already underway retains the resolved Reflection definition with which it began;
- every declared output receives the same producer-independent artefact;
- changing or removing a Reflection does not alter an artefact already delivered.

For Destinations:

- registration identifies a logical graph and does not eagerly create storage;
- `operator` continues to resolve to `operator/<operator_id>`;
- `global` and consumer Destinations continue to resolve to their exact shared names;
- changing runtime configuration does not migrate or delete existing graphs.

## Search behaviour

Search selection is invocation data, not a configurable default.

- Agentic memory search supplies Destination selectors on each call.
- Programmatic `Gralkor.Client.search/1` may supply Destination selectors.
- An omitted or empty programmatic Destination selection searches every accessible registered Destination.
- A supplied selection searches only those Destinations.
- No agent mount or runtime configuration field defines default search Destinations.

## Reflection execution ownership

The consumer explicitly invokes a named Reflection. Gralkor resolves its current definition, executes its ordered steps, validates the final structured output, delivers the resulting artefact once to each declared output, and returns completion or failure to the caller.

Reflection execution is synchronous from Gralkor's public boundary. Each call makes at most one Runner attempt and one attempt for each declared output. Gralkor does not enqueue, retry, recover, drain, or schedule the invocation.

The consumer owns:

- deciding when a Reflection runs;
- reacting to completed ingestion;
- cron or calendar scheduling;
- asynchronous jobs and concurrency limits;
- retry and timeout policy;
- durable job state and crash recovery;
- preventing overlapping execution when that matters;
- deciding how to retry partially delivered outputs.

The consumer supplies a non-blank operator identifier, a replay-stable invocation identifier, input context, host tools, and tool context for each invocation. Artefact identity remains deterministic from the operator identifier, invocation identifier, and Reflection name so repeated canonical storage can converge on one immutable artefact.

## Scheduling baseline

Gralkor-owned Reflection scheduling was removed rather than retained behind a compatibility path.

The completed removal covered:

- Reflection trigger fields and validation;
- automatic Reflection admission after direct or buffered Lens ingestion;
- asynchronous programmatic admission;
- `Gralkor.Reflection.Scheduler`;
- `Gralkor.Reflection.Journal`;
- `Gralkor.Reflection.Supervisor`;
- Reflection retry, timeout, restart recovery, admission deduplication, and drain behaviour;
- `:reflection_scheduler_journal_path`;
- Reflection declarations, callbacks, and scheduler state from `Gralkor.CaptureBuffer`;
- automatic Reflection tool and tool-context forwarding from `JidoGralkor.Plugin` and the native client;
- application supervision of Reflection scheduling;
- scheduler- and journal-specific test trees, tests, documentation, and configuration examples.

CaptureBuffer's own ingestion-flush retry behaviour remains. It is unrelated to Reflection scheduling and stays owned by CaptureBuffer.

There was no `Gralkor.Reflection.Schedule` cron process. `Gralkor.Reflection.Scheduler`, its durable journal, its supervisor, and their integrations are now absent from the production and test surfaces. This scheduling-free ownership boundary is the starting point for the future runtime-configuration work described here.

## YAML removal

Remove repository-YAML Reflection configuration:

- `:reflection_root`;
- YAML paths in Reflection declarations;
- YAML loading from `Gralkor.Reflection.ChainOfThought` and the Reflection registry;
- packaged YAML Reflection declarations and implicit default Reflection registration;
- Reflection documentation and tests that create or load YAML files;
- the direct `yaml_elixir` dependency when no remaining package code uses it.

No YAML fallback remains. Consumers must install every Reflection they intend to invoke through runtime configuration.

## Verified current-state gap

The scheduling baseline is complete and verified: the Scheduler, Journal, and Reflection Supervisor modules and their dedicated tests are absent, and production/test searches find no Reflection trigger, scheduler-journal configuration, automatic-admission context, or Scheduler API references.

The runtime-configuration work remains intentionally unimplemented for a future session. Current production code still:

- has no `Gralkor.RuntimeConfig.replace/1` operation or atomic in-memory snapshot;
- resolves Destination, Lens, and Reflection definitions from application configuration and their existing registries;
- loads Reflection Chain-of-Thought definitions from YAML using `:reflection_root`;
- supplies packaged YAML Reflection definitions implicitly;
- exposes the Runner primitive without the proposed public synchronous boundary that resolves a named Reflection and delivers all declared outputs.

## Outside-in implementation sequence

The scheduling-free baseline above is already complete. A future session should implement only the runtime-configuration and direct-execution design in this sequence:

1. Change the Functional test-tree contract to describe atomic runtime configuration and direct synchronous Reflection execution.
2. Add failing Functional coverage for complete configuration replacement, invalid replacement preservation, current-definition resolution, and invocation snapshot isolation.
3. Add failing Functional coverage for direct synchronous Reflection execution and immediate Runner or output failures without retries.
4. Implement the smallest runtime configuration owner and route Destination, Lens, and Reflection resolution through its active snapshot.
5. Replace YAML-backed Reflection parsing with validation of inline structured steps.
6. Add the public synchronous execution boundary that resolves one accepted Reflection snapshot, makes one Runner attempt, attempts each declared output once, and returns completion or failure to the consumer.
7. Remove obsolete Reflection configuration keys, YAML assets, direct dependencies, documentation, and mental-model statements.
8. Run the focused Functional test during RED and GREEN, then the complete Functional and Journey commands required by `TEST_STRATEGY.md` for this substantive public orchestration change.

TDD may reveal a substantive inner runtime-configuration subject. Its Integration or Unit tree should be introduced only when consumer-test pressure reveals that subject, not in advance.

## Completion conditions

The work is complete when:

- the consumer can atomically install a complete runtime configuration;
- invalid configuration never changes active state;
- all references resolve within one coherent snapshot;
- current operations retain their accepted definitions while later operations use replacements;
- Reflections are supplied inline and execute only through explicit consumer calls;
- no Gralkor-owned Reflection scheduling, retry, recovery, journal, or drain code remains;
- no Reflection YAML configuration or implicit Reflection registry remains;
- Lens and search defaults are not consumer-configurable;
- stored information and delivered artefacts survive configuration replacement unchanged;
- test trees, tests, implementation, mental model, README, and package contents describe the same ownership model;
- focused, complete Functional, and Journey verification pass.
