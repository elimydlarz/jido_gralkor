Unit: publish-jido-gralkor (src: .agents/skills/publish/SKILL.md, .agents/skills/publish/agents/openai.yaml, .claude/skills/publish, .env.example, mix.exs, README.md, DESTINATIONS.md, PERSONAL_MEMORY_MIGRATION.md; unit: test/publish_skill_test.mjs)

then Codex agents find the publish skill at `.agents/skills/publish` and Claude Code agents find the same skill at `.claude/skills/publish`
and the skill description says that every jido_gralkor Hex publication and release tag goes through this skill, which needs no interactive Hex login or one-time password

when an operator asks to publish jido_gralkor with a semantic-version change kind or the current version
  then the version selection is the only required operator input
  and no other session's activity is waited for or blocks the publication
  and read-only Git preflight proves the current branch is the remote default branch
  and the required Hex and GitHub credentials are shell-loaded from the repository environment using their current names
  and the Hex token identifies the personal user `elimydlarz`
  and `jido_gralkor` ownership is transferred to `elimydlarz` and verified through that user's owned packages before the test suite runs
  and the complete test suite passes through `mix test.all` before the version changes
  and the version change is committed and pushed by trunk-sync before Hex publication
  and no direct write-side Git command is attempted
  and the package holds only committed content
  and the remote branch contains the release commit before Hex publication
  and Hex receives the release version as a personally owned public package
  and every repository-relative document linked from the published README is included in the Hex package
  and every repository-relative document linked from the published README is included in the ExDoc extras
  and the Hex package names `elimydlarz` as its maintainer
  and GitHub receives a new lightweight release tag for the release commit
  and remote inspection proves the release tag resolves to the release commit
  and completion reports the version, commit, tag, tests, Hex package, and remote branch
  when another session bumps the version at the same time
    then the higher of the two versions receives the requested change
  if another session has already published the version being released
    while a major, minor, or patch change was requested
      then the next patch version is bumped and published instead
    while the current version was selected
      then publishing reports that the version is already published and stops

when the operator selects the current version
  then mix.exs remains unchanged and its existing version is published

if the version selection is invalid, a required credential is missing, the Hex token does not identify `elimydlarz`, ownership transfer or verification fails, the branch is not the remote default branch, or tests fail
  then publishing stops before changing release state

if trunk-sync synchronization, Hex publication, GitHub tag creation, or remote verification fails
  then publishing stops without retrying the Hex publication or replacing a release tag
  and it reports the release version, release commit, Hex result, and exact remote branch and tag state
