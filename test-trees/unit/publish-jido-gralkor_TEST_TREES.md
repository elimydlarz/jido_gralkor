Unit: publish-jido-gralkor (src: .agents/skills/publish/SKILL.md, .agents/skills/publish/agents/openai.yaml, .env.example, mix.exs, README.md, DESTINATIONS.md; unit: test/publish_skill_test.mjs)

when an operator asks to publish jido_gralkor with a semantic-version change kind or the current version
  then the version selection is the only required operator input
  and read-only Git preflight proves the local default branch matches its remote tip
  and the complete test suite passes through `mix test.all` before release state changes
  and the required Hex and GitHub credentials are shell-loaded from the repository environment using their current names
  and the version change is synchronized to the remote default branch by trunk-sync before Hex publication
  and no direct write-side Git command is attempted
  and the Hex token identifies the personal user `elimydlarz`
  and after the test suite passes, `jido_gralkor` ownership is transferred from the gralkor organization to `elimydlarz` and verified through that user's owned packages before the version changes
  and Hex receives the synchronized version as a personally owned public package
  and every repository-relative document linked from the published README is included in the Hex package
  and every repository-relative document linked from the published README is included in the ExDoc extras
  and GitHub receives a new lightweight release tag for the synchronized release commit
  and remote inspection proves the branch and release tag resolve to the release commit
  and completion reports the version, commit, tag, tests, Hex package, and remote branch

when the operator selects the current version
  then mix.exs remains unchanged and its version is synchronized before Hex publication

if the version selection is invalid, a required credential is missing, the Hex token does not identify `elimydlarz`, another trunk-sync session can move the branch, the worktree contains unrelated changes, the branch is not the up-to-date remote default branch, tests fail, ownership transfer or verification fails, or the release tag already exists
  then publishing stops before changing release state

if trunk-sync synchronization, Hex publication, GitHub tag creation, or remote verification fails
  then publishing stops without replacing an existing release tag and reports the exact incomplete release state
