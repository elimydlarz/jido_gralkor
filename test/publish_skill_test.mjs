import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const skillUrl = new URL("../.agents/skills/publish/SKILL.md", import.meta.url);
const openaiYamlUrl = new URL("../.agents/skills/publish/agents/openai.yaml", import.meta.url);
const envExampleUrl = new URL("../.env.example", import.meta.url);
const mixUrl = new URL("../mix.exs", import.meta.url);

test("when an operator asks to publish jido_gralkor with a semantic-version change kind or the current version", async (context) => {
  await context.test("then the version selection is the only required operator input", async () => {
    const skill = await readFile(skillUrl, "utf8");
    const openaiYaml = await readFile(openaiYamlUrl, "utf8");

    assert.match(skill, /Require exactly `<major\|minor\|patch\|current>` from the operator's request\./);
    assert.match(
      openaiYaml,
      /default_prompt: "Use \$publish patch to publish the next jido_gralkor release\."/,
    );
  });

  await context.test(
    "and read-only Git preflight proves the local default branch matches its remote tip",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /git status --short/);
      assert.match(skill, /git diff/);
      assert.match(skill, /git branch --show-current/);
      assert.match(skill, /git rev-parse HEAD/);
      assert.match(skill, /git ls-remote --symref origin HEAD refs\/heads\/<current-branch>/);
      assert.match(skill, /Require the current branch to be the remote default branch/);
      assert.match(skill, /Require the local commit to equal the remote branch tip/);
    },
  );

  await context.test(
    "and the complete test suite passes through `mix test.all` before release state changes",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /Run `mix test\.all` before editing the version\./);
      assert.match(
        skill,
        /Shell-source `<repo-root>\/\.env` before running `mix test\.all` so configured provider credentials override ambient test placeholders\./,
      );
    },
  );

  await context.test(
    "and the required Hex and GitHub credentials are shell-loaded from the repository environment using their current names",
    async () => {
      const skill = await readFile(skillUrl, "utf8");
      const envExample = await readFile(envExampleUrl, "utf8");

      assert.match(skill, /Require non-empty `HEX_TOKEN` and `GH_TOKEN` values from `<repo-root>\/\.env`\./);
      assert.match(skill, /Shell-source `<repo-root>\/\.env` so its values are interpreted before passing credentials to Hex or GitHub\./);
      assert.match(envExample, /^HEX_TOKEN=$/m);
      assert.doesNotMatch(envExample, /^GRALKOR_HEX_TOKEN=/m);
      assert.match(envExample, /user API key with `api:write` permission/);
      assert.match(envExample, /`jido_gralkor`, `gralkor`, and `gralkor_ex`/);
      assert.match(envExample, /^GH_TOKEN=$/m);
      assert.match(envExample, /Contents write permission/);
    },
  );

  await context.test("and the Hex token identifies the personal user `elimydlarz`", async () => {
    const skill = await readFile(skillUrl, "utf8");

    assert.match(skill, /mix hex\.user whoami/);
    assert.match(skill, /Require the authenticated Hex user to equal `elimydlarz`\./);
  });

  await context.test(
    "and after the test suite passes, `jido_gralkor` ownership is transferred from the gralkor organization to `elimydlarz` and verified through that user's owned packages before the version changes",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /mix hex\.owner packages/);
      assert.match(skill, /mix hex\.owner transfer jido_gralkor elimydlarz/);
      assert.match(skill, /Require `jido_gralkor` to appear in `elimydlarz`'s owned-package list before editing `mix\.exs`\./);
      assert.ok(skill.indexOf("mix test.all") < skill.indexOf("mix hex.owner transfer"));
      assert.ok(skill.indexOf("mix hex.owner transfer") < skill.indexOf("edit only `@version` in `mix.exs`"));
    },
  );

  await context.test(
    "and the version change is synchronized to the remote default branch by trunk-sync before Hex publication",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /Read `@version` from `mix\.exs` and calculate the requested semantic-version change\./);
      assert.match(skill, /edit only `@version` in `mix\.exs`/i);
      assert.match(skill, /require the command's trunk-sync hook result to succeed/i);
      assert.match(skill, /require trunk-sync to commit and push the version change/i);
      assert.match(skill, /Record the synchronized release commit with `git rev-parse HEAD`/);
      assert.match(skill, /Require the remote branch tip to equal the synchronized release commit before publishing to Hex\./);
    },
  );

  await context.test("and no direct write-side Git command is attempted", async () => {
    const skill = await readFile(skillUrl, "utf8");

    assert.match(
      skill,
      /Do not run direct write-side Git commands, including `git fetch`, `git add`, `git commit`, `git tag`, or `git push`\./,
    );
    assert.match(skill, /Run every read-only Git inspection as its own standalone command/);
    assert.match(skill, /Do not run `scripts\/publish\.sh` because it performs direct write-side Git commands\./);
    assert.doesNotMatch(skill, /^git (?:fetch|add|commit|tag [^-]|push)/m);
  });

  await context.test(
    "and Hex receives the synchronized version as a personally owned public package",
    async () => {
      const skill = await readFile(skillUrl, "utf8");
      const envExample = await readFile(envExampleUrl, "utf8");

      assert.match(skill, /HEX_API_KEY="\$HEX_TOKEN" mix hex\.publish --yes/);
      assert.match(skill, /Require `mix\.exs` still to contain the prepared version/);
      assert.match(skill, /Require `HEAD` and the remote branch tip still to equal the synchronized release commit/);
      assert.match(skill, /personally owned public package in the global Hex repository/);
      assert.doesNotMatch(skill, /mix hex\.publish --organization/);
      assert.match(envExample, /personal Hex user `elimydlarz`/);
      assert.doesNotMatch(envExample, /manage both the gralkor organization package/);
    },
  );

  await context.test(
    "and every repository-relative document linked from the published README is included in the Hex package",
    async () => {
      const mix = await readFile(mixUrl, "utf8");

      assert.match(mix, /files:.*README\.md DESTINATIONS\.md CHANGELOG\.md/);
    },
  );

  await context.test(
    "and every repository-relative document linked from the published README is included in the ExDoc extras",
    async () => {
      const mix = await readFile(mixUrl, "utf8");

      assert.match(mix, /extras: \["README\.md", "DESTINATIONS\.md"\]/);
    },
  );

  await context.test(
    "and GitHub receives a new lightweight release tag for the synchronized release commit",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /jido-gralkor-v<version>/);
      assert.match(skill, /gh api --method POST 'repos\/\{owner\}\/\{repo\}\/git\/refs'/);
      assert.match(skill, /-f 'ref=refs\/tags\/jido-gralkor-v<version>'/);
      assert.match(skill, /-f 'sha=<release-commit>'/);
      assert.match(skill, /Create only a lightweight reference/);
      assert.match(skill, /Never update or replace an existing release tag\./);
    },
  );

  await context.test(
    "and remote inspection proves the release tag resolves to the synchronized release commit",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /git ls-remote origin refs\/heads\/<current-branch> refs\/tags\/jido-gralkor-v<version>/);
      assert.match(skill, /Require the release tag to resolve to the synchronized release commit\./);
    },
  );

  await context.test(
    "and the remote branch contains the synchronized release commit even if trunk-sync bookkeeping advances the branch after publication",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(
        skill,
        /gh api --method GET 'repos\/\{owner\}\/\{repo\}\/compare\/<release-commit>\.\.\.<remote-branch-tip>'/,
      );
      assert.match(skill, /Require the comparison status to be `identical` or `ahead`\./);
    },
  );

  await context.test(
    "and completion reports the version, commit, tag, tests, Hex package, and remote branch",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(
        skill,
        /Report the version, release commit, release tag, test commands, Hex package, and remote branch only after remote verification succeeds\./,
      );
    },
  );
});

test("when the operator selects the current version", async (context) => {
  await context.test(
    "then mix.exs remains unchanged and its version is synchronized before Hex publication",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /For `current`, do not edit `mix\.exs`\./);
      assert.match(skill, /Use its existing `@version` as the prepared version/);
    },
  );
});

test(
  "if the version selection is invalid, a required credential is missing, the Hex token does not identify `elimydlarz`, another trunk-sync session can move the branch, the worktree contains unrelated changes, the branch is not the up-to-date remote default branch, tests fail, ownership transfer or verification fails, or the release tag already exists",
  async (context) => {
    await context.test("then publishing stops before changing release state", async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /Stop if the worktree contains changes outside the current trunk-sync session/);
      assert.match(skill, /Require no other active trunk-sync session on the current branch/);
      assert.match(skill, /Require both credentials before running tests or editing files/);
      assert.match(skill, /Require `refs\/tags\/jido-gralkor-v<version>` to be absent from the remote/);
      assert.match(skill, /Do not change release state before every preflight check and test command passes\./);
      assert.match(skill, /Stop before editing `mix\.exs` or publishing to Hex if Hex identity, ownership transfer, or ownership verification fails\./);
    });
  },
);

test(
  "if trunk-sync synchronization, Hex publication, GitHub tag creation, or remote verification fails",
  async (context) => {
    await context.test(
      "then publishing stops without replacing an existing release tag and reports the exact incomplete release state",
      async () => {
        const skill = await readFile(skillUrl, "utf8");

        assert.match(skill, /Fail visibly on every command error\./);
        assert.match(skill, /Do not retry Hex publication automatically/);
        assert.match(skill, /Never replace a local or remote release tag/);
        assert.match(
          skill,
          /Report the prepared version, synchronized release commit, Hex result, and exact remote branch and tag state/,
        );
      },
    );
  },
);
