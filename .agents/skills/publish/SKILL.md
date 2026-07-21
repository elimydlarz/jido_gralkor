---
name: publish
description: Publish jido_gralkor to Hex with a major, minor, or patch semantic-version change while trunk-sync exclusively owns commits and branch synchronization and GitHub's API creates the release tag. Use when an operator asks to publish or release jido_gralkor from this repository.
---

# Publish jido_gralkor

Require exactly `<major|minor|patch>` from the operator's request.

## Preflight

1. Resolve the repository root with `git rev-parse --show-toplevel`.
2. Reject a change kind other than `major`, `minor`, or `patch`.
3. Inspect `git status --short` and the complete `git diff`.
4. Read the current branch and local commit with `git branch --show-current` and `git rev-parse HEAD`.
5. Query the remote without updating local refs:

```sh
git ls-remote --symref origin HEAD refs/heads/<current-branch>
```

Require the current branch to be the remote default branch. Require the local commit to equal the remote branch tip.

Require non-empty `GRALKOR_HEX_TOKEN` and `GH_TOKEN` values from `<repo-root>/.env`. Load them without printing their values.

Run `mix test`, `mix test.functional`, and `mix test.journey` before editing the version.
