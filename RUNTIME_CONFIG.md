# Runtime Configuration

## Purpose

The consumer owns the durable source of truth for Gralkor's domain configuration. Each consuming Jido agent owns one validated in-memory snapshot used by its Gralkor memory operations.

The consumer supplies its complete configuration when it starts the agent and replaces that complete configuration after every committed change. Gralkor does not know about the consumer's database, poll it, subscribe to it, or persist a second copy.

This document describes the implemented runtime-configuration boundary.

## Ownership and supervision

Gralkor is a Jido plugin, not a node-global application service. The plugin contributes one runtime child beneath each consuming `Jido.AgentServer`.

That per-agent runtime owns:

- the agent's active runtime-configuration snapshot;
- background Reflection processing;
- Reflection Destination delivery;
- retry and abandonment for active Reflection work.

Two agents on the same BEAM node therefore have independent configuration and Reflection work. Replacing one agent's configuration does not affect the other.

The runtime is linked to its `AgentServer`. If it terminates unexpectedly, the agent terminates with it. When the agent runs beneath consumer supervision, that supervisor starts a replacement agent and supplies the consumer's current complete durable configuration again. Gralkor does not independently reconstruct consumer configuration after a restart.

## Configuration boundary

One runtime configuration contains the complete consumer-defined set of:

- Destinations;
- Lenses;
- Reflections.

Package-owned structured definitions are installed alongside the consumer configuration:

- the `operator` and `global` Destinations;
- the `operator` Lens;
- the generalisations and ERL Reflections.

The consumer cannot replace package-owned definitions. Before consumer configuration is installed, only those package-owned definitions are available.

Deployment concerns are outside this boundary. FalkorDB connection details, model selection, credentials, operational timeouts, and internal test adapters remain ordinary application configuration.

Agent identity, operator identity, tools, tool context, Lens selection, Destination search selectors, Reflection input, and the invocation callback are invocation data rather than runtime configuration.

## Consumer lifecycle

The consumer performs a whole-state synchronization for one agent:

1. Read the complete desired configuration from its durable store.
2. Start the agent with that configuration, or submit it to the agent's runtime-configuration replacement boundary after a committed change.
3. Continue only after the start or replacement succeeds.
4. Surface a validation failure while retaining the previously active snapshot.

A replacement:

- targets one consuming agent;
- accepts Destination, Lens, and Reflection collections as required lists;
- validates and resolves the complete candidate before changing active state;
- activates the three consumer registries as one snapshot;
- preserves all package-owned definitions;
- returns only after the replacement is active;
- accepts empty consumer collections;
- returns a tagged validation failure without changing active state.

Reads observe either the complete previous snapshot or the complete replacement. They never observe a mixture; one search resolves all of its selected Lens and Destination definitions in a single runtime call.

Every runtime-targeted operation accepts the owning `Jido.AgentServer` PID. A non-PID target or a PID without an available Gralkor runtime raises a deliberate `ArgumentError`; targeted work never falls back to application compatibility configuration.

If the complete durable configuration supplied while an agent starts is invalid, that agent's Gralkor plugin fails to start. No part of the invalid configuration becomes active.

## Definition shape

Runtime definitions are structured Elixir data. They contain no file paths and require no filesystem access.

An illustrative complete consumer value is:

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
    },
    %{
      name: "project-topology",
      destination: "project",
      write: :replace_graph
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

An appending Lens declares `write: :append`, a Destination, and an ingestion module. Its ontology is optional and defaults to `Gralkor.DefaultOntology`.

A replaceable Lens declares `write: :replace_graph` and a Destination. It accepts one complete graph containing nodes and relationships:

```elixir
%Gralkor.Graph{
  nodes: nodes,
  relationships: relationships
}
```

Property graph is Gralkor's only graph representation. There is no graph-format field or format selection in Lens configuration, replacement requests, or `Gralkor.Graph`.

Every Reflection declares exactly one Destination output and an inline Chain of Thought. A Reflection invocation supplies its callback; callbacks are not part of the reusable Reflection definition.

The existing Chain-of-Thought rules remain: steps are ordered and non-empty; labels and directions are non-blank; output contracts are non-empty and typed; output names are unique across steps; and interpolation can reference only an output declared by an earlier step.

## Validation

The complete candidate is rejected when it contains:

- blank or duplicate names;
- malformed or unknown definition fields;
- a name reserved by a package-owned definition;
- a Lens or Reflection that refers to a Destination absent from the candidate and package-owned Destinations;
- a Lens that combines appending and replacement fields;
- an invalid ingestion module, ontology, Reflection Destination, or inline Chain of Thought;
- a custom ontology entity kind named `Entity`, `Episodic`, or `Community`.

`Entity`, `Episodic`, and `Community` are Graphiti's core entity labels. `Person` is not reserved and remains a valid custom kind.

## Snapshot semantics

Each operation retains the relevant definitions active when that operation begins:

- named ingestion retains its Lens definition;
- Reflection submission retains its Reflection definition when admitted;
- search retains its selected Lens and Destination definitions from one snapshot;
- Lens-selected capture resolves and retains every Lens definition before its ingestion worker is scheduled.

A later replacement affects later operations only. It does not mutate work already underway.

When `JidoGralkor.Lifecycle` is wired into an agent, graceful termination schedules the active thread's flush before returning. The scheduled ingestion retains its resolved Lens definitions and can finish after the owning AgentServer and runtime terminate; agent termination does not await that ingestion.

Changing or removing a Lens does not migrate or delete information already stored. Stored provenance retains the Lens name used when the information was written.

Changing or removing a Reflection does not alter an artefact already produced or delivered. Changing runtime Destination registration does not migrate or delete existing graphs.

Destination resolution retains its existing meaning:

- `operator` resolves to `operator/<operator_id>`;
- `global` and consumer Destinations resolve to their exact shared names;
- registration identifies a logical graph and does not eagerly create storage.

## Search behaviour

Search selection is invocation data, not a configurable default.

- Agentic memory search supplies Destination selectors on each call.
- Programmatic search may supply Destination selectors.
- An omitted or empty programmatic selection searches every accessible registered Destination.
- A supplied selection searches only those Destinations.
- No plugin mount or runtime-configuration field defines default search Destinations.

## Reflection submission and results

The consumer triggers a named Reflection through the consuming agent. Submission validates and admits the invocation, then returns a replay-stable invocation identifier without waiting for inference, artefact production, Destination delivery, or callback delivery.

Reflection processing continues under that agent's Gralkor runtime. Each admitted invocation progresses independently, so slow inference or delivery for one Reflection does not block the submitting consumer or another Reflection invocation.

The invocation supplies:

- a non-blank operator identifier;
- a replay-stable invocation identifier;
- input context;
- host tools and tool context;
- a callback through which the consumer eventually receives the terminal outcome.

Artefact identity remains deterministic from the operator identifier, invocation identifier, and Reflection name so repeated canonical storage can converge on one immutable artefact.

When production succeeds, Gralkor delivers the artefact to the Reflection's Destination. After delivery reaches a terminal outcome, the invocation callback receives the produced artefact and that outcome.

When production fails, the callback receives the terminal failure outcome. Gralkor never turns a production or delivery error into an artefact stored in memory.

Programmatic triggers and consumer-owned scheduled jobs use this same asynchronous submission and callback path. Gralkor does not own cron or calendar scheduling.

## Retry and abandonment

The boundary that reports a retryable 5xx server failure owns retrying that operation with exponential backoff. This applies independently to inference, related-memory retrieval, and Destination delivery.

Retries stop when the operation succeeds or twenty-four hours have elapsed since its first failed attempt. At that deadline, Gralkor abandons the invocation and reports the abandonment through its invocation callback.

A non-retryable 4xx client failure is abandoned immediately without retry and is reported through the same callback.

Retries are supervised in memory beneath the consuming agent. If the agent terminates, unfinished work terminates with it without invoking its callback. The consumer remains responsible for durable job state and for deciding whether to submit work again after restarting the agent.

## Generalisation lineage

The packaged generalisations Reflection retrieves related memory and asks the model for structured generalisation output, including lineage. Its prompt directs a new generalisation with no lineage to use level 1 and an evolved generalisation to use one level above its highest lineage snapshot.

Lineage receives the ordinary structural and type validation declared by the Reflection's output contract. Gralkor preserves the model-produced values without comparing them with the related-memory input and does not independently validate whether a lineage claim is eligible or fabricated.

Only a successfully produced generalisation artefact is delivered to its Destination. Retrieval, inference, validation, or delivery failures follow the common callback and retry rules.

## Scheduling boundary

The consumer owns:

- deciding when a Reflection runs;
- reacting to completed ingestion;
- cron or calendar scheduling;
- durable job state and restart recovery;
- application-level concurrency and overlap policy;
- deciding whether terminated work should be submitted again.

Gralkor owns asynchronous execution and in-process retry only after an invocation has been admitted and only for the lifetime of that consuming agent.

The previously removed `Gralkor.Reflection.Scheduler`, durable journal, trigger fields, and automatic post-ingestion admission remain absent. CaptureBuffer's ingestion-flush retry is unrelated and remains owned by CaptureBuffer.

## Structured Reflection definitions

Reflection definitions, including the package-owned generalisations and ERL Reflections, are structured Elixir data. There is no Reflection file root, path field, or YAML fallback. Package-owned structured Reflections are always installed; consumers install only their own Reflections.

## Completion conditions

The implementation is complete when:

- every consuming Jido agent owns an independent Gralkor runtime and configuration snapshot;
- the consumer can atomically replace one agent's complete consumer configuration without changing another agent;
- package-owned Destinations, Lens, and Reflections remain installed;
- invalid configuration never partially changes active state;
- current operations retain their admitted definitions while later operations use replacements;
- runtime-targeted operations require the owning AgentServer PID, fail when its runtime is unavailable, and never cross into application compatibility configuration;
- graph replacement uses one fixed nodes-and-relationships representation with no format configuration;
- Reflection submission returns without waiting and every admitted invocation eventually reports its terminal outcome through its callback while the agent remains alive;
- successful artefacts alone are delivered to memory;
- 5xx failures retry with exponential backoff for up to twenty-four hours and 4xx failures do not retry;
- unfinished Reflection work terminates with the consuming agent;
- generalisation lineage receives structural validation but no comparison with related memory;
- no Gralkor-owned scheduler, journal, YAML Reflection configuration, or graph-format option remains;
- test trees, tests, implementation, mental model, README, and package contents describe the same ownership model;
- focused, complete Functional, and Journey verification pass.
