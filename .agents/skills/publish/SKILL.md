---
name: publish
description: Publish the current jido_gralkor version or a major, minor, or patch semantic-version change to Hex while trunk-sync exclusively owns commits and branch synchronization and GitHub's API creates the release tag. Use when an operator asks to publish or release jido_gralkor from this repository.
---

# Publish jido_gralkor

Require exactly `<major|minor|patch|current>` from the operator's request.

## Preflight

1. Resolve the repository root with `git rev-parse --show-toplevel`.
2. Reject a version selection other than `major`, `minor`, `patch`, or `current`.
3. Inspect `git status --short` and the complete `git diff`.
4. Stop if the worktree contains changes outside the current trunk-sync session.
5. Inspect `.trunk-sync/timeclock/`. Require no other active trunk-sync session on the current branch so the release commit cannot move during publication.
6. Require non-empty `HEX_TOKEN` and `GH_TOKEN` values from `<repo-root>/.env`. Require both credentials before running tests or editing files. Shell-source `<repo-root>/.env` so its values are interpreted before passing credentials to Hex or GitHub. Load them without printing their values.
7. Create a temporary Hex home, shell-source `<repo-root>/.env`, and run `HEX_HOME="<temporary-hex-home>" HEX_API_KEY="$HEX_TOKEN" mix hex.user whoami` without printing the token. Require the authenticated Hex user to equal `elimydlarz`.
8. Read the current branch and local commit with `git branch --show-current` and `git rev-parse HEAD`.
9. Read `@version` from `mix.exs` and calculate the requested semantic-version change. For `current`, use the existing version.
10. Query the remote without updating local refs:

```sh
git ls-remote --symref origin HEAD refs/heads/<current-branch>
```

Require the current branch to be the remote default branch. Require the local commit to equal the remote branch tip.

Query `refs/tags/jido-gralkor-v<version>` with a standalone `git ls-remote`. Require `refs/tags/jido-gralkor-v<version>` to be absent from the remote.

Run every read-only Git inspection as its own standalone command. Do not compose a Git command with `cd`, pipes, command substitution, environment assignments, shell wrappers, or another command.

Do not run direct write-side Git commands, including `git fetch`, `git add`, `git commit`, `git tag`, or `git push`. Trunk-sync exclusively owns commits and branch synchronization. Do not run `scripts/publish.sh` because it performs direct write-side Git commands.

Run `mix test.all` before editing the version.

Do not change release state before every preflight check and test command passes.

## Prepare

1. Shell-source `<repo-root>/.env` and use an isolated temporary Hex home with `HEX_API_KEY="$HEX_TOKEN"`. Run `mix hex.owner packages`. If `jido_gralkor` is absent, run `mix hex.owner transfer jido_gralkor elimydlarz`, then run `mix hex.owner packages` again. Require `jido_gralkor` to appear in `elimydlarz`'s owned-package list before editing `mix.exs`. Do not pass `--organization`; this is a personally owned public package in the global Hex repository.
2. For `current`, do not edit `mix.exs`. Use its existing `@version` as the prepared version.
3. For `major`, `minor`, or `patch`, edit only `@version` in `mix.exs` with `apply_patch`.
4. When the version changes, require the command's trunk-sync hook result to succeed and require trunk-sync to commit and push the version change, leaving a clean worktree.
5. Record the synchronized release commit with `git rev-parse HEAD`.
6. Inspect the release commit and query `refs/heads/<current-branch>` with `git ls-remote`.

Require the remote branch tip to equal the synchronized release commit before publishing to Hex.

## Publish

Re-read `mix.exs`, `HEAD`, and the remote branch tip. Require `mix.exs` still to contain the prepared version. Require `HEAD` and the remote branch tip still to equal the synchronized release commit.

Shell-source `<repo-root>/.env` without printing it. Create a temporary directory, substitute its absolute path for `<temporary-hex-home>`, and isolate Hex from cached user authentication when publishing:

```sh
HEX_HOME="<temporary-hex-home>" HEX_API_KEY="$HEX_TOKEN" mix hex.publish --yes
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

Stop before editing `mix.exs` or publishing to Hex if Hex identity, ownership transfer, or ownership verification fails.

If ownership transfer, synchronization, Hex publication, tag creation, or verification fails, stop and inspect the state with read-only commands. Report the prepared version, synchronized release commit, Hex result, and exact remote branch and tag state. Do not report the release as complete until every remote check succeeds.
