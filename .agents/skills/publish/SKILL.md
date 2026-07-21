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
4. Stop if the worktree contains changes outside the current trunk-sync session.
5. Inspect `.trunk-sync/timeclock/`. Require no other active trunk-sync session on the current branch so the release commit cannot move during publication.
6. Require non-empty `GRALKOR_HEX_TOKEN` and `GH_TOKEN` values from `<repo-root>/.env`. Require both credentials before running tests or editing files. Load them without printing their values.
7. Read the current branch and local commit with `git branch --show-current` and `git rev-parse HEAD`.
8. Read `@version` from `mix.exs` and calculate the requested semantic-version change.
9. Query the remote without updating local refs:

```sh
git ls-remote --symref origin HEAD refs/heads/<current-branch>
```

Require the current branch to be the remote default branch. Require the local commit to equal the remote branch tip.

Query `refs/tags/jido-gralkor-v<version>` with a standalone `git ls-remote`. Require `refs/tags/jido-gralkor-v<version>` to be absent from the remote.

Run every read-only Git inspection as its own standalone command. Do not compose a Git command with `cd`, pipes, command substitution, environment assignments, shell wrappers, or another command.

Do not run direct write-side Git commands, including `git fetch`, `git add`, `git commit`, `git tag`, or `git push`. Trunk-sync exclusively owns commits and branch synchronization. Do not run `scripts/publish.sh` because it performs direct write-side Git commands.

Run `mix test`, `mix test.functional`, and `mix test.journey` before editing the version.

Do not change release state before every preflight check and test command passes.

## Prepare

1. Edit only `@version` in `mix.exs` with `apply_patch`.
2. Require the command's trunk-sync hook result to succeed.
3. Require trunk-sync to commit and push the version change, leaving a clean worktree.
4. Record the synchronized release commit with `git rev-parse HEAD`.
5. Inspect the release commit and query `refs/heads/<current-branch>` with `git ls-remote`.

Require the remote branch tip to equal the synchronized release commit before publishing to Hex.

## Publish

Re-read `mix.exs`, `HEAD`, and the remote branch tip. Require `mix.exs` still to contain the prepared version. Require `HEAD` and the remote branch tip still to equal the synchronized release commit.

Load `<repo-root>/.env` without printing it. Create a temporary directory, substitute its absolute path for `<temporary-hex-home>`, and isolate Hex from cached user authentication when publishing:

```sh
HEX_HOME="<temporary-hex-home>" HEX_API_KEY="$GRALKOR_HEX_TOKEN" mix hex.publish --yes
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

Report the version, release commit, release tag, test commands, Hex package, and remote branch only after remote verification succeeds.

## Failure handling

Fail visibly on every command error. Do not retry Hex publication automatically because a failed response may follow a completed publish. Never replace a local or remote release tag.

If synchronization, Hex publication, tag creation, or verification fails, stop and inspect the state with read-only commands. Report the prepared version, synchronized release commit, Hex result, and exact remote branch and tag state. Do not report the release as complete until every remote check succeeds.
