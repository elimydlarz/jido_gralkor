---
name: publish
description: Publish jido_gralkor to Hex and create its GitHub release tag. Use this skill for every jido_gralkor Hex publication and release tag, including any request to publish, release, or tag jido_gralkor, before any `mix hex.publish`, and whenever Hex reports no authenticated user or asks for a one-time password. It loads `HEX_TOKEN` and `GH_TOKEN` from the repository .env, so it needs no interactive Hex login or one-time password. It publishes the current version or a major, minor, or patch change while trunk-sync owns commits and GitHub's API creates the tag. Sessions never wait for each other: whichever session gets there first bumps and publishes, and a later session bumps and publishes again.
---

# Publish jido_gralkor

Require exactly `<major|minor|patch|current>` from the operator's request.

## Concurrent sessions

Many sessions share this repository and publish it independently. Never wait for, coordinate with, or message another session before publishing. Active trunk-sync timecards, other sessions' commits, and other sessions' releases never block a publication.

When another session publishes first, it takes that version. This session then bumps again and publishes the next version. The Publish section states exactly when.

## Preflight

1. Resolve the repository root with `git rev-parse --show-toplevel`.
2. Reject a version selection other than `major`, `minor`, `patch`, or `current`.
3. Require non-empty `HEX_TOKEN` and `GH_TOKEN` values from `<repo-root>/.env`. Require both credentials before running tests or editing files. Shell-source `<repo-root>/.env` so its values are interpreted before passing credentials to Hex or GitHub. Load them without printing their values.
4. Create a temporary Hex home, shell-source `<repo-root>/.env`, and run `HEX_HOME="<temporary-hex-home>" HEX_API_KEY="$HEX_TOKEN" mix hex.user whoami` without printing the token. Require the authenticated Hex user to equal `elimydlarz`.
5. With the same isolated Hex home and `HEX_API_KEY="$HEX_TOKEN"`, run `mix hex.owner packages`. If `jido_gralkor` is absent, run `mix hex.owner transfer jido_gralkor elimydlarz`, then run `mix hex.owner packages` again. Require `jido_gralkor` to appear in `elimydlarz`'s owned-package list. Do not pass `--organization`; this is a personally owned public package in the global Hex repository.
6. Read the current branch with `git branch --show-current`. Query the remote without updating local refs:

```sh
git ls-remote --symref origin HEAD
```

Require the current branch to be the remote default branch.

Run every read-only Git inspection as its own standalone command. Do not compose a Git command with `cd`, pipes, command substitution, environment assignments, shell wrappers, or another command.

Do not run direct write-side Git commands, including `git fetch`, `git pull`, `git add`, `git commit`, `git tag`, or `git push`. Trunk-sync exclusively owns commits and branch synchronization. Do not run `scripts/publish.sh` because it performs direct write-side Git commands.

Shell-source `<repo-root>/.env` before running `mix test.all` so configured provider credentials override ambient test placeholders. Load them without printing their values. Run `mix test.all` before editing the version.

Do not change release state before every preflight check and test command passes.

## Bump

For `current`, do not edit `mix.exs`. Continue to Publish.

For `major`, `minor`, or `patch`:

1. Read `@version` from `mix.exs` immediately before editing it. It may already hold a version another session bumped.
2. Calculate the requested semantic-version change from that version, and edit only `@version` in `mix.exs` with `apply_patch`.
3. Require the command's trunk-sync hook result to succeed, and require trunk-sync to commit and push the version change.
4. If trunk-sync reports a conflict in `mix.exs`, another session bumped the version at the same time. Resolve the conflict by taking the higher of the two versions and applying the requested change to it. Then require the next hook result to succeed.

## Publish

1. Read `HEAD` with `git rev-parse HEAD`. This commit is the release commit.
2. Read `@version` from `mix.exs`. This is the release version, even when another session bumped it beyond the version this session prepared.
3. Run `git status --short -- lib priv config mix.exs README.md DESTINATIONS.md PERSONAL_MEMORY_MIGRATION.md CHANGELOG.md .formatter.exs`. Require it to print nothing so the package contains only committed content. Uncommitted package files belong to an edit whose trunk-sync hook has not committed it yet. Read the status again after that hook has committed and pushed it.
4. Query `refs/tags/jido-gralkor-v<version>` with a standalone `git ls-remote origin refs/tags/jido-gralkor-v<version>`. If the tag exists, another session already published this version:
   - For `major`, `minor`, or `patch`, return to Bump with `patch`, then restart Publish.
   - For `current`, report that the version is already published, with its tag, and stop.
5. Query the remote branch tip with `git ls-remote origin refs/heads/<current-branch>`, then prove it contains the release commit through GitHub's comparison API:

```sh
gh api --method GET 'repos/{owner}/{repo}/compare/<release-commit>...<remote-branch-tip>'
```

Require the comparison status to be `identical` or `ahead`. If the release commit has not reached the remote yet, its trunk-sync hook is still pushing it. Restart Publish once trunk-sync has pushed.

Shell-source `<repo-root>/.env` without printing it. Create a temporary directory, substitute its absolute path for `<temporary-hex-home>`, and isolate Hex from cached user authentication when publishing:

```sh
HEX_HOME="<temporary-hex-home>" HEX_API_KEY="$HEX_TOKEN" mix hex.publish --yes
```

If Hex rejects the publication because the version already exists, another session published it first. For `major`, `minor`, or `patch`, return to Bump with `patch` and restart Publish. For `current`, report that the version is already published and stop.

After Hex succeeds, create `jido-gralkor-v<version>` at the release commit through GitHub's create-reference API:

Write `<temporary-reference-request>` with exactly this JSON request body:

```json
{"ref":"refs/tags/jido-gralkor-v<version>","sha":"<release-commit>"}
```

Submit that explicit JSON body rather than form fields:

```sh
gh api --method POST 'repos/{owner}/{repo}/git/refs' --input "<temporary-reference-request>"
```

Create only a lightweight reference. Never update or replace an existing release tag.

Verify the tag with this standalone inspection:

```sh
git ls-remote origin refs/tags/jido-gralkor-v<version>
```

Require the release tag to resolve to the release commit.

Report the version, release commit, release tag, test commands, Hex package, and remote branch only after the tag verification succeeds.

## Failure handling

Fail visibly on every command error. Do not retry a Hex publication automatically after an error other than "version already exists", because a failed response may follow a completed publish. Never replace a local or remote release tag.

Stop before editing `mix.exs` or publishing to Hex if Hex identity, ownership transfer, or ownership verification fails.

If synchronization, Hex publication, tag creation, or verification fails, stop and inspect the state with read-only commands. Report the release version, release commit, Hex result, and exact remote branch and tag state. Do not report the release as complete until every remote check succeeds.
