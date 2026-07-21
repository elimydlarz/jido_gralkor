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

Run every read-only Git inspection as its own standalone command. Do not compose a Git command with `cd`, pipes, command substitution, environment assignments, shell wrappers, or another command.

Do not run direct write-side Git commands, including `git fetch`, `git add`, `git commit`, `git tag`, or `git push`. Trunk-sync exclusively owns commits and branch synchronization. Do not run `scripts/publish.sh` because it performs direct write-side Git commands.

Require non-empty `GRALKOR_HEX_TOKEN` and `GH_TOKEN` values from `<repo-root>/.env`. Load them without printing their values.

Run `mix test`, `mix test.functional`, and `mix test.journey` before editing the version.

## Prepare

1. Read `@version` from `mix.exs` and calculate the requested semantic-version change.
2. Edit only `@version` in `mix.exs` with `apply_patch`.
3. Require the command's trunk-sync hook result to succeed.
4. Require trunk-sync to commit and push the version change, leaving a clean worktree.
5. Record the synchronized release commit with `git rev-parse HEAD`.
6. Inspect the release commit and query `refs/heads/<current-branch>` with `git ls-remote`.

Require the remote branch tip to equal the synchronized release commit before publishing to Hex.

## Publish

Re-read `mix.exs`, `HEAD`, and the remote branch tip. Require `mix.exs` still to contain the prepared version. Require `HEAD` and the remote branch tip still to equal the synchronized release commit.

Load `<repo-root>/.env` without printing it, isolate Hex from cached user authentication with a temporary `HEX_HOME`, and publish with:

```sh
HEX_API_KEY="$GRALKOR_HEX_TOKEN" mix hex.publish --yes
```

After Hex succeeds, create `jido-gralkor-v<version>` at the synchronized release commit through GitHub's create-reference API:

```sh
gh api --method POST 'repos/{owner}/{repo}/git/refs' -f 'ref=refs/tags/jido-gralkor-v<version>' -f 'sha=<release-commit>'
```

Create only a lightweight reference. Never update or replace an existing release tag.

Verify the remote state with this standalone inspection:

```sh
git ls-remote origin refs/heads/<current-branch> refs/tags/jido-gralkor-v<version>
```

Require both remote refs to resolve to the synchronized release commit.
