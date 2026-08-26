---
name: run-journey
description: Run and verify jido_gralkor's single production-like Journey. Use when an operator asks to run, check, verify, diagnose, or explain the Journey or Journey suite, especially after changing memory Destinations, Lenses, Reflections, Graphiti storage, recall, or replacement.
---

# Run Journey

Run the repository's one broad memory adventure against the real embedded Graphiti/FalkorDB runtime and configured inference providers.

## Establish the Journey

1. From the repository root, list `test-trees/journey/` and `test/journey/` with `rg --files`.
2. Require exactly one Journey tree and one corresponding `*_journey_test.exs` file. Treat extra, missing, or mismatched files as test-tree drift.
3. Read the tree and test completely. The tree comment narrates the adventure; the executable path is deliberately shorter because ExUnit combines descriptions into a BEAM function name.
4. Describe fixture threads as parts of the one Journey, never as separate Journeys.

## Protect the Embedded Runtime

- Do not run this Journey concurrently with another Elixir test VM using the embedded backend. Check active test VMs first; report a conflict instead of killing it.
- Do not combine the Journey with Unit or Functional runs. Run other tiers only after the Journey process exits.

## Authorize External Inference

The Journey may send fixture-derived prompts to configured external inference providers.

1. Inspect the current test and identify the exact fixture categories that can leave the machine.
2. Tell the operator those categories and that they will go to the configured inference providers.
3. Obtain explicit authorization after that disclosure. A prior generic request to "run the Journey" is not sufficient when the execution environment requires payload-specific egress consent.
4. Never bypass a rejected approval by changing commands, tags, providers, or invocation paths.

## Run

Run the discovered Journey file through the project alias:

```sh
mix test.journey test/journey/memory_adventure_journey_test.exs --max-failures 1
```

The command starts real PythonX, Graphiti, embedded FalkorDB, extraction, recall presentation, and ERL inference. Allow up to the test's declared timeout. Provide a concise progress update at least once per minute while it runs.

Warnings about deprecated Req/Finch options do not fail the Journey. Report them only if they obscure or cause the outcome.

## Interpret the Adventure

The Journey's final memory view should jointly prove:

- implicit memory works without consumer ontology configuration;
- captured appending-Lens information remains searchable;
- ERL stores a structured `Learning` artefact;
- global memory is visible to both operators while local memory is isolated;
- appending and replaceable Lenses can share one Destination;
- replacing one Lens's graph preserves other information at that Destination;
- the current replacement is returned and the superseded graph is absent.

Journey coverage is broad and curated, not exhaustive. Unit and Functional tests own individual branches and errors.

## Finish

- Report the exact Journey result, elapsed time, and any failure.
- If the Journey fails during an inspection-only request, diagnose and report without changing code. If the operator asked to build or fix it, use the project TDD workflow and rerun to green.
- After Journey-related edits, run `mix format --check-formatted`, the non-Journey regression suite, and `.fasset-harness/scripts/check-readme-sync.sh` before completion.
- Confirm the repository still has exactly one Journey tree and one Journey test file.
