# CR: One complete format for every memory search result

**Context.** `JidoGralkor.MemorySearchPresentation.for_model/2` renders search results as readable text. `memory_search` and `recall/4` use it. Two gaps remain:

- It drops information. An object with a `content` string shows only that text, so a generalisation's `level` and `evolves_from` disappear.
- The generalisation Reflection does not use it. `Gralkor.Reflection.Runner.default_inference/3` pastes the raw search results into its prompt with `Jason.encode!` (`lib/gralkor/reflection/runner.ex:235`). That puts IDs, wrappers and empty fields on one line, with the level-1 text repeated inside each later generalisation's lineage.

The goal is one formatter for every memory search result shown to a model, keeping every field.

---

## 1. The formatter keeps every field

**Problem**
- `bullets/1` and `readable/1` keep only `content` when an object has it, so fields such as `level` and `evolves_from` are lost.
- Entity attributes appear inline in brackets, as in `- Atlas: A rollout (owner: Platform)`. Objects without `content` appear as one line of `key: value` pairs.
- Different memories carry different fields, so a fixed per-type layout cannot work.

**Change**
- The bullet is the memory's main text: a `content` field if there is one, otherwise the fact text, the entity name and summary, or the episode text.
- Every other field goes on an indented `name: value` line under the bullet, in alphabetical order.
- A list of objects becomes nested bullets, laid out the same way. A list of plain values stays on one line, separated by commas.
- A field that is null, an empty string, an empty list or an empty object is left out.
- Nothing is specific to any Reflection or entity type.
- Unchanged:
  - headings, ordering, the `Entities` section and the same-text-once rule
  - the `(valid from …; source: …)` suffix on facts and episodes
  - the `… (truncated)` marker. The 4,000-character ceiling counts a memory's indented lines.
  - dropping a payload's single outer key, such as `generalisations` in `{"generalisations": [...]}`, because it only names the Reflection's output field and the heading already shows the Reflection
- `_gralkor_` attributes stay hidden.

**Examples**

```
Reflection: generalisations
- For any potentially customer-impacting release activity, a mandatory reversible, limited-scope checkpoint must be used…
  level: 2
  evolves_from:
  - For critical deployments, a mandatory reversible, limited-scope canary and checkpoint must be used…
    level: 1

Reflection: erl
- approach: moved Vacuum to 04:00
  lesson: Keep the jobs apart
  problem_kind: job scheduling
  success: true

Entities
- Atlas: A rollout
  owner: Platform
  region: eu-west
- Payments: Customer-impacting release activity needs a checkpoint
```

**Acceptance**
- A generalisation shows its content, `level`, and each `evolves_from` snapshot with its own content and level.
- An object without `content` shows every non-empty field.
- Entities with different attributes each show all of their own.
- No `content`-only rule remains in the formatter.

## 2. The Reflection prompt uses the formatter

**Problem**
- The generalisation Reflection runs the same search as `memory_search` (`Gralkor.Client.search/2`, `runner.ex:116`) but skips the formatter.

**Change**
- `default_inference/3` renders `request.stored_information` with `for_model/2` instead of `Jason.encode!`, using the same 65,536-byte default as `memory_search`.
- `request.stored_information` stays structured, so a consumer's own `:inference` function receives the same data as before.
- The prompt's other JSON sections are unchanged: the new observations ("Lensed representations"), which are the ingestion being reflected on rather than search results, and the output contract.

**Acceptance**
- The default generalisation prompt shows prior memory in the `memory_search` format, including each generalisation's level and lineage.
- A consumer inference function still receives structured `stored_information`.

---

## Tests and docs

- **Trees:**
  - `test-trees/unit/memory-search-presentation_TEST_TREES.md`: replace the `content`-only and one-field leaves with the new rule
  - the Reflection runner tree: add the prompt leaf
- **Tests:**
  - the formatter unit test, with multi-line memories
  - the runner unit test, checking the prompt text
  - Functional tests that assert artefact or entity text. Fixtures with `level` will gain `level:` lines.
- **Docs:** the format sections in README, `DESTINATIONS.md` and CLAUDE.md, plus a CHANGELOG `[Unreleased]` entry
- **Verification:** `mix test.functional`, then the Journey on embedded and remote FalkorDB

**Coordination.** The formatter files belong to the "gralkor search result consistency" session. Message it before editing them, and before any Functional or Journey run.

**Out of scope**
- The new observations section of the Reflection prompt
- The Reflection's output contract, which must stay JSON
- Structured `Gralkor.Client.search/1,2` results
