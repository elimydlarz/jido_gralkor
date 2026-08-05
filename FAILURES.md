# Journey test failures — bug report

Written for a session with no prior context. Everything needed to reproduce and
diagnose is below.

## Environment

- Repo: `jido_gralkor`, branch `main`, 2026-08-05.
- `.env` (gitignored) pins both inference roles to OpenAI, so no `GOOGLE_API_KEY`
  is required:
  ```
  OPENAI_API_KEY=<real key>
  GRALKOR_LLM_MODEL=openai:gpt-4.1
  GRALKOR_EMBEDDER_MODEL=openai:text-embedding-3-small
  GRALKOR_DATA_DIR=/tmp/gralkor
  ```
  `test/test_helper.exs` loads these via `Gralkor.TestEnv.load/1`.
- graphiti-core 0.29.3 in the PythonX-managed venv; embedded FalkorDB via
  `falkordblite`, which spawns a `redis-server` grandchild.
- The three LLM-backed suites build their `GraphitiPool` child spec from
  `Gralkor.Config.llm_model/0` / `embedder_model/0`, so they follow the pins above.
  They previously hardcoded `%{provider: :google, ...}`.

Baseline for comparison: `mix test` → 507 passed; `mix test.functional` → 91/93.

## Headline

`mix test.journey` reports **3/7**. Run the same modules one at a time and you get
**3/5**, with a smaller and different failure set. The gap is Bug 1, which is an
artefact of running them together — not a defect in the code under test.

| | whole-suite run | run separately |
| --- | --- | --- |
| `jido_memory_journey` | fails ERL round-trip (and varies) | **2/3** |
| `generalise_journey` | fails after-flush | **1/2** |

Judge these modules by the separate runs until Bug 1 is fixed.

---

## Bug 1 — orphan reaper kills a live redis-server owned by the same VM

**Severity:** high for test reliability; affects any VM that starts more than one
`Gralkor.Python`.

**Symptom.** In a whole-suite `mix test.journey`, a module that ran earlier loses
its database mid-run:

```
1) test jido-memory-journey > ERL round-trip a captured turn becomes a learning
   recalled by the kind of problem (Gralkor.JidoMemoryJourneyTest)
   ** (MatchError) no match of right hand side value:
      {:error, {:python, "... ConnectionRefusedError: [Errno 61] Connection refused
        redis/asyncio/connection.py:1703 in _connect
        await asyncio.open_unix_connection(path=self.path)  ..."}}
```

**Reproduce.**
```bash
mix test.journey                      # ERL round-trip dies on a refused socket
mix test test/functional/jido_memory_journey_test.exs --include journey --include functional
                                      # 2/3 — ERL round-trip PASSES
```

**Cause.** `Gralkor.Python.init/1` reaps orphaned servers before booting, matching
on argv:

```elixir
System.cmd("pgrep", ["-af", "redislite/bin/redis-server"], stderr_to_stdout: true)
```

and SIGKILLing every hit. Each journey module's `setup_all` calls
`start_supervised(Gralkor.Python)`. The second module's boot therefore kills the
**first module's live server**, not an orphan, and the older graph's next query
gets a refused unix socket.

The reap is only sound for the first `Gralkor.Python` in a VM. The behaviour is
incidental — argv matching cannot distinguish "orphan from a previous hard kill"
from "live server this VM started".

**Suggested fix.** Record the pids this VM spawned and reap only unrecognised
ones, or reap once per VM rather than per `Gralkor.Python` start. Either makes
whole-suite journey runs meaningful again.

**Deliberately not documented in code or trees.** The behaviour is unwanted, and
writing it into the `Gralkor.Python` moduledoc or `python-runtime_TEST_TREES.md`
would enshrine a defect as intent. It lives here instead, until it is fixed.

---

## Bug 2 — recall surfaces a fact belonging to a different test

**Severity:** medium. Real — reproduces with the module run alone.

**Symptom.**

```
test jido-memory-journey > round-trip memory_add stores a fact, recall surfaces
it under the same group_id
  expected recall to surface a fact about Eli's employer or location; got:
    Susu informed Eli that they moved the vacuum job to 04:00 to prevent it from
    overlapping with the nightly database backup ...
```

The fixture writes *"Eli works at Anthropic in Sydney. He prefers concise
technical explanations…"* and asserts the recall block mentions `anthropic` or
`sydney`. What comes back is the vacuum-job/backup narrative, which is the
fixture of a **different test in the same module** (the ERL round-trip test,
`jido_memory_journey_test.exs:151`).

**Reproduce.**
```bash
mix test test/functional/jido_memory_journey_test.exs --include journey --include functional
```

**Not stale storage — ruled out.** `setup_all` builds a fresh
`Path.join(System.tmp_dir!(), "gralkor_journey_<unique>")` per module and
`File.rm_rf!`s it on exit. `/tmp/gralkor` does not exist on this machine.

**Which test fails varies between runs.** One run failed `round-trip` and `flush`
while passing `ERL round-trip`; the next failed `ERL round-trip` and passed
`round-trip`. Treat the specific names as variance and the *class* of failure —
recall returning a semantically unrelated fact from the same group — as the bug.

**Leading hypothesis: the embedder swap.** The suite was written against
`gemini-embedding-2-preview`. `text-embedding-3-small` returns 1024 dimensions
and graphiti slices every vector to `EmbedderConfig.embedding_dim` **silently**
(`graphiti_core/embedder/openai.py`, `create/1`). Nothing anywhere in the stack
checks cross-provider embedding compatibility. If retrieval is ranking poorly,
this is the first thing to test.

**Unmeasured, and important:** no Google baseline was ever captured, because no
`GOOGLE_API_KEY` was available. So it is **not** established that this suite
passed on the Google defaults, nor that OpenAI is worse. Getting a
`GOOGLE_API_KEY` and running the same module is the cheapest way to settle
whether this is a provider regression or a long-standing weakness.

---

## Bug 3 — generalisation pipeline stores nothing after flush

**Severity:** medium. Real — reproduces with the module run alone.

**Symptom.**

```
test ex-generalise-journey > after flush with generalise_fn the generalise
pipeline saves generalisations to the _gen group
  expected at least one fact in the _gen group; got []
  generalise_journey_test.exs:157
```

**Reproduce.**
```bash
mix test test/functional/generalise_journey_test.exs --include journey --include functional
# 1/2 — the direct add_episode test passes, so the _gen group and its search path work
```

The sibling test that writes an episode straight into the `_gen` group and finds
it again **passes**. So storage and retrieval for that group are fine; what
produced nothing is distillation.

**Cause, as far as established.** `Gralkor.Generalise` asked the LLM for durable
generalisations from the flushed transcript and kept none — either it returned
none, or all fell below `:generalise_min_confidence` (default `0.3`).

**Weakness in the test itself, worth fixing either way.** A pipeline that
legitimately keeps zero generalisations is indistinguishable here from one that
is broken, because the assertion only checks the group is non-empty. It cannot
say which happened. Logging the distillation result, or asserting on the
pipeline's return value rather than only on the resulting graph, would make the
next failure diagnosable.

---

## Other known failures (not journey)

Recorded so a clean session does not mistake them for regressions.

**`ontology-extraction` — flaky by construction.** `mix test.functional` → 91/93,
both failures here. Each assertion demands a specific label out of a single real
extraction, so it samples the model. On `gpt-4.1`: the no-ontology case
(`at least one generic Entity`) went fail, fail, pass across three identical runs;
the open case (`at least one Preference`) has both passed and failed on identical
input. Expect 1–2 of 3 to fail per run. `gpt-4.1-mini` is not viable — it extracts
`User` but never `Preference`, failing strict and open every time, which is why
`gpt-4.1` is pinned.

**`Gralkor.DistillTest` — latent order-dependent flake.** Pre-existing.

```elixir
refute function_exported?(Distill, :format_transcript, 4)
assert function_exported?(Distill, :format_transcript, 3)
```

`function_exported?/3` returns `false` for a module the VM has not loaded, so this
fails when random ordering runs it before anything loads `Gralkor.Distill`.
Observed once, then 507 passed across `--seed 1..6`. Fix:
`Code.ensure_loaded!(Distill)` before the assertions.

## What is working, and should not be re-investigated

All of this was broken earlier and is now verified:

- **Credentials reach the embedded interpreter.** Erlang's `os:putenv` keeps its
  own table and never calls C `setenv()`, so anything `System.put_env` writes is
  invisible to Python's `os.environ` — including `OPENAI_API_KEY` loaded from
  `.env`. Every graphiti client constructor now takes its key as an explicit
  argument via `Gralkor.GraphitiPool.api_key!/1`. Three tests pin this, one of
  which asserts the interpreter's environment does *not* carry the key, so the
  constraint cannot silently reverse.
- **Every suite runs on `OPENAI_API_KEY` alone.** No `GOOGLE_API_KEY` needed
  unless a role is pointed back at Google.
- `mix test` → 507 passed. `mix compile --warnings-as-errors` and
  `mix format --check-formatted` are clean.
