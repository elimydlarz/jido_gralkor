# WIP: jido_gralkor 13.0.0 release (delete when published)

## Purpose

Ship jido_gralkor 13.0.0 only once it works well, after a full sync. 13.0.0 contains two changes, both uncommitted in this working tree:

- **Packaged `generalisations` Destination** (decided by Eli, 2026-10-28/29). The packaged `generalisations` Reflection writes to, and searches only, its own packaged Destination `generalisations`.
  - Fresh start: existing generalisations stay in `global`, with no backfill.
  - The name is reserved, which breaks consumers, so semver makes this 13.0.0.
  - Why: in `global`, prior generalisations competed with source episodes for the 5 episode slots. Their entities and edges also merged with, and could invalidate, observation facts there, because Graphiti resolves per group_id.
- **Lens-filtered search** (built by the "phil code" session as 12.1.0, folded into 13.0.0 by Eli's decision).
  - Lens selectors return to search, filtered inside the query by patching graphiti-core 0.31.2 (`install_lens_search_filters` in `graphiti_pool.ex`).
  - Content from a replaceable Lens (`_gralkor_lens`) counts for facts and nodes. This interacts with WIP_REMOVE_REPLACEMENT_LENSES.md.

## Status

| Item | State |
|---|---|
| `generalisations` Destination: trees (5), code, tests, docs | Done. Focused Functional 171/171 |
| Lens filter: code, tests, trees, docs | Done by phil code. Its subagent has stopped; this session is the sole writer until publish |
| Combined tree before sync | Journey 43/43, mirror check clean, format clean; phil code reported `mix test` 923, Functional 627 (ontology_extraction not run), Node 65 |
| Sync (fasset-harness:sync) | Audits done. Before the fixes, `mix test.functional` passed 632/632. Tree fixes are written and shown to Eli: functional runtime-configuration, destination-registration, destination-graphs and destination-search; integration graphiti-pool and the new gralkor-application tree; unit capture-buffer, both destination storage trees and gralkor-application; Journey generalisations and Lens selector. A fix agent is implementing them. Its brief also covers the patch install, error summaries, the Lens scope, the capture-buffer exhausted line, in-memory replacement facts, the removals, test fixes, the mental model and the CHANGELOG fold |
| `generalisations` exclusive (Eli, 2026-10-29) | Done: only the packaged generalisation Reflection writes there |
| Sync fixes | Done. After the fixes: `mix test` 934, `mix test.functional` 639, Journey 49 (6 new leaves), Node 65, mirror check and format clean. `:capture_client_4xx` removed; the startup readiness leaf moved to the integration tree. Kept: `remove_episode` (it has tree leaves) and the uncentralised packaged Lens names (optional) |
| Publish gate | Passed: `mix test.all` 1622 ExUnit + 65 Node, exit 0. `@version` set to 13.0.0; CHANGELOG dated 2026-10-29. Waiting for Eli to commit and push (everything except this file). Then: publish, tag, tell phil code, delete this file |
| Publish 13.0.0 | After sync is green. Eli commits and pushes (trunk-sync blocks git writes from this session), then this session publishes via `.agents/skills/publish` flow (`HEX_TOKEN`/`GH_TOKEN` from `.env`, tag via GitHub API) |

## Next

1. Reconcile the sync findings. Show tree diffs to Eli, who gave advance approval for in-scope gaps. Fix gaps and bugs through TDD.
2. Add Journey leaves covering the `generalisations` Destination and Lens-filtered search, then run `mix test.all`.
3. Fold the changelog entries, ask Eli to commit and push, publish 13.0.0, and create the tag.
4. Tell the "phil code" session when 13.0.0 is on Hex, because it moves Phil to 13.0.0.

## Open

- Booting `Gralkor.Python` SIGKILLs every embedded `redislite` redis-server on the machine (`lib/gralkor/python.ex`). Run only one jido_gralkor or Phil VM at a time, and coordinate with peer sessions.

## Deviations

- Sync skips `push-if-green`: commits and pushes are Eli's for this release.
- Audit agents read only. Tests run one VM at a time from this session, because of the redis kill.
