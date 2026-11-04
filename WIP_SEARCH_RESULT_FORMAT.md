# CR: One complete format for every memory search result

**Context.** `JidoGralkor.MemorySearchPresentation.for_model/2` renders search results as readable text. `memory_search` and `recall/4` use it. Two gaps remain:

- It drops information. An object with a `content` string shows only that text, so a generalisation's `level` and `evolves_from` disappear. The current docs describe this as deliberate ("keeps `level` and `evolves_from` out of generalisations"). This CR reverses that decision.
- The generalisation Reflection does not use it. `Gralkor.Reflection.Runner.default_inference/3` pastes the raw search results into its prompt with `Jason.encode!` (`lib/gralkor/reflection/runner.ex:235`). That puts IDs, wrappers, and empty fields on one line.

The goal is one formatter for every memory search result shown to a model. The formatter keeps every field that the memory itself carries.

---

## 1. The formatter keeps every field

**Problem**
- `bullets/1` and `readable/1` keep only `content` when an object has it, so fields such as `level` and `evolves_from` are lost.
- At every depth, an object with one field shows only that field's value, so the field name is lost.
- Entity attributes appear inline in brackets, as in `- Atlas: A rollout (owner: Platform)`. Objects without `content` appear as one line of `key: value` pairs.
- Different memories carry different fields, so a fixed per-type layout cannot work.

**Which fields count**
- An artefact payload or a structured-record episode: the fields of its decoded JSON.
- An entity: its attributes, without the `_gralkor` attributes, which stay hidden.
- A fact, or an episode that is not a structured record: none. These memories show only their text.
- Record metadata is never shown. This includes uuids, `group_id`, embeddings, the artefact ID, the Destination, and timestamps. Timestamps appear only in the `(valid from …)` suffix.

**Layout**
- Each memory is one bullet. The first line of the bullet is the memory's main text:
  - a fact: the fact text
  - an entity: `name: summary`, or only `name` when there is no summary
  - an object with a `content` string: that string
  - an object without `content`: its first field in alphabetical order, written `key: value`
  - an episode that is not a structured record: its text
- Each other field of the memory goes on its own line under the bullet, indented two spaces further than the bullet's `- `:
  - Fields that fit on one line come first, in alphabetical order. These are a plain value or a list of plain values.
  - Fields that need more lines come next, in alphabetical order. These are a nested object or a list that contains an object.
- A plain value is written as `key: value`. Numbers and booleans are written as they are, for example `level: 2` or `success: true`.
- A list of plain values is written as `key: a, b, c`.
- A list that contains an object is written as `key:` on its own line. Each item follows as a nested bullet at the same indent as the field name. A nested bullet follows the same layout rules as a memory, so its own fields are two spaces further in. A plain value in such a list is a nested bullet that contains only that value.
- A nested object is written as `key:` on its own line. Its fields follow two spaces further in, with the same ordering rules.
- These fields are left out: null, an empty string, an empty list, an empty object, and a field whose only contents are other fields that are left out.
- Inside each line, runs of whitespace (including newlines in a value) become one space.
- Payload unwrapping:
  - If an artefact payload, or the decoded JSON of a structured-record episode, is an object with exactly one key, that key is dropped and its value is rendered instead. An example is `generalisations` in `{"generalisations": [...]}`: the key only names the Reflection's output field, and the heading already shows the Reflection. This happens once, at the outer level only.
  - If the value after unwrapping is a list, each item is its own memory. This rule is unchanged.
  - No other one-field rule remains. A nested object with one field keeps its field name.
- Nothing is specific to any Reflection or entity type.

**Date and source suffix.** The `(valid from …; source: …)` suffix is unchanged. It goes at the end of the bullet's first line. Entities still have no suffix.

**Truncation.** A memory is cut only when its text is longer than 4,000 characters. The text is all of its lines, with their indentation and line breaks. The cut keeps the first 4,000 characters, and `… (truncated)` ends the last line that is kept. The date and source suffix is added after the cut, and it does not count toward the 4,000 characters.

**Unchanged**
- Headings, the order of headings and sections, and the `Entities` section last.
- The same-text-once rule. It compares the complete text of each memory, with all of its lines.
- The 16,384-character ceiling, the byte budget, and the omission notice. A memory is kept or omitted whole.

**Examples**

```
Reflection: generalisations
- For any potentially customer-impacting release activity, a mandatory reversible, limited-scope checkpoint must be used… (valid from 2026-10-02)
  level: 2
  evolves_from:
  - For critical deployments, a mandatory reversible, limited-scope canary and checkpoint must be used…
    level: 1

Reflection: erl
- approach: moved Vacuum to 04:00 (valid from 2026-10-12)
  lesson: Keep the jobs apart
  problem_kind: job scheduling
  success: true

Entities
- Atlas: A rollout
  owner: Platform
  region: eu-west
- Payments: Customer-impacting release activity needs a checkpoint
```

The lineage repeats the text of each earlier generalisation. That is intended. The formatter presents what the payload carries, and it does not remove repeated text.

## 2. The Reflection prompt uses the formatter

**Problem**
- The generalisation Reflection runs the same search as `memory_search` (`Gralkor.Client.search/2`, `runner.ex:116`), but it does not use the formatter.

**Change**
- `default_inference/3` renders `request.stored_information` with `for_model/2`, at the same 65,536-byte default as `memory_search`. The `result` text goes under "Related stored information available to this Reflection step:" in place of `Jason.encode!`.
- The prompt has the same limits as `memory_search`: the 16,384-character ceiling and the byte budget. If prior memory is longer than that, the formatter omits whole memories and adds its omission notice. Before this change the prompt had no limit. The search caps (20 facts, 20 nodes, 5 episodes) keep the usual result within the limit.
- If `for_model/2` returns an error, `default_inference/3` returns that error as `{:error, reason}` and does not call the model.
- `request.stored_information` stays structured, so a consumer's own `:inference` function gets the same data as before.
- The other sections of the prompt are unchanged and stay JSON. These are the new observations ("Lensed representations"), which are the ingestion being reflected on and not search results, and the output contract.

---

## Tests and docs

- **Trees:**
  - `test-trees/unit/memory-search-presentation_TEST_TREES.md`:
    - Replace "every memory is one line of plain text": each memory is one bullet whose first line is its main text, with each other field on an indented line.
    - Replace "the formatter adds no Destination, artefact identifier, level, or lineage metadata": the formatter adds no record metadata, and `level` and lineage appear only as fields of the payload.
    - Replace the `content`-only, one-field, and semicolon leaves under the Reflection artefact branch with the layout, ordering, nesting, empty-field, and outer-key rules above.
    - Change the entity leaf: attributes are indented lines and not inline brackets.
    - Change the truncation leaves: multi-line counting, the marker on the last kept line, and the suffix that does not count.
  - `test-trees/unit/reflection-runner_TEST_TREES.md`: add leaves for the formatted stored information in the default prompt, for an error from the formatter, and for a consumer inference function that still gets structured data.
- **Tests:**
  - the formatter unit test, with multi-line memories
  - the runner unit test, checking the prompt text
  - Functional tests that assert artefact or entity text. Fixtures with `level` will gain `level:` lines.
- **Docs:** these places describe the old format, and each one must change:
  - the `MemorySearchPresentation` moduledoc
  - the `MemorySearch` moduledoc ("every memory is one line")
  - README (the "Memory search results" paragraph and the `MemorySearch` module entry)
  - `DESTINATIONS.md` (the readable memory search section, including "keeps `level` and `evolves_from` out of generalisations")
  - CLAUDE.md (the `MemorySearch` entry, including "Reflection inference alone keeps raw JSON")
  - a CHANGELOG `[Unreleased]` entry
- **Verification:** `mix test.functional`, then the Journey on embedded and remote FalkorDB.

**Coordination.** The formatter files belong to the "gralkor search result consistency" session. Send it a message before you edit them, and before any Functional or Journey run.

**Out of scope**
- The new observations section of the Reflection prompt
- The Reflection's output contract, which must stay JSON
- Structured `Gralkor.Client.search/1,2` results
- Removing repeated lineage text
- Showing a fact's relationship name or its source and target entities
