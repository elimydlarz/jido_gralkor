import assert from "node:assert/strict";
import { readFile, realpath } from "node:fs/promises";
import test from "node:test";

const skillUrl = new URL("../.agents/skills/publish/SKILL.md", import.meta.url);
const openaiYamlUrl = new URL("../.agents/skills/publish/agents/openai.yaml", import.meta.url);
const envExampleUrl = new URL("../.env.example", import.meta.url);
const mixUrl = new URL("../mix.exs", import.meta.url);

async function readmeDocuments() {
  const readme = await readFile(new URL("../README.md", import.meta.url), "utf8");
  const links = [...readme.matchAll(/\[[^\]]*\]\((?!https?:\/\/)([^)\s]+\.md)(?:#[^)\s]*)?\)/g)];
  return [...new Set(["README.md", ...links.map((match) => match[1])])];
}

test("then Codex agents find the publish skill at `.agents/skills/publish` and Claude Code agents find the same skill at `.claude/skills/publish`", async () => {
  const claudeSkillUrl = new URL("../.claude/skills/publish/SKILL.md", import.meta.url);

  assert.equal(await realpath(claudeSkillUrl), await realpath(skillUrl));
});

test("and the skill description says that every jido_gralkor Hex publication and release tag goes through this skill, which needs no interactive Hex login or one-time password", async () => {
  const skill = await readFile(skillUrl, "utf8");
  const description = skill.match(/^---\n[\s\S]*?^description: (.+)$[\s\S]*?^---$/m)[1];

  assert.match(description, /every jido_gralkor Hex publication and release tag/);
  assert.match(description, /`mix hex\.publish`/);
  assert.match(description, /`HEX_TOKEN` and `GH_TOKEN`/);
  assert.match(description, /no interactive Hex login or one-time password/);
});

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

  await context.test("and no other session's activity is waited for or blocks the publication", async () => {
    const skill = await readFile(skillUrl, "utf8");

    assert.match(skill, /Never wait for, coordinate with, or message another session before publishing\./);
    assert.match(skill, /other sessions' releases never block a publication/);
  });

  await context.test(
    "and read-only Git preflight proves the current branch is the remote default branch",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /git branch --show-current/);
      assert.match(skill, /git ls-remote --symref origin HEAD/);
      assert.match(skill, /Require the current branch to be the remote default branch\./);
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
    "and `jido_gralkor` ownership is transferred to `elimydlarz` and verified through that user's owned packages before the test suite runs",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /mix hex\.owner packages/);
      assert.match(skill, /mix hex\.owner transfer jido_gralkor elimydlarz/);
      assert.match(skill, /Require `jido_gralkor` to appear in `elimydlarz`'s owned-package list\./);
      assert.ok(skill.indexOf("mix hex.owner transfer") < skill.indexOf("Run `mix test.all`"));
    },
  );

  await context.test(
    "and the complete test suite passes through `mix test.all` before the version changes",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /Run `mix test\.all` before editing the version\./);
      assert.match(
        skill,
        /Shell-source `<repo-root>\/\.env` before running `mix test\.all` so configured provider credentials override ambient test placeholders\./,
      );
      assert.ok(skill.indexOf("Run `mix test.all`") < skill.indexOf("edit only `@version` in `mix.exs`"));
    },
  );

  await context.test(
    "and the version change is committed and pushed by trunk-sync before Hex publication",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /Read `@version` from `mix\.exs` immediately before editing it\./);
      assert.match(skill, /edit only `@version` in `mix\.exs`/);
      assert.match(skill, /require trunk-sync to commit and push the version change/i);
      assert.ok(skill.indexOf("## Bump") < skill.indexOf("mix hex.publish --yes"));
    },
  );

  await context.test("and no direct write-side Git command is attempted", async () => {
    const skill = await readFile(skillUrl, "utf8");

    assert.match(
      skill,
      /Do not run direct write-side Git commands, including `git fetch`, `git pull`, `git add`, `git commit`, `git tag`, or `git push`\./,
    );
    assert.match(skill, /Run every read-only Git inspection as its own standalone command/);
    assert.match(skill, /Do not run `scripts\/publish\.sh` because it performs direct write-side Git commands\./);
    assert.doesNotMatch(skill, /^git (?:fetch|pull|add|commit|tag [^-]|push)/m);
  });

  await context.test("and the package holds only committed content", async () => {
    const skill = await readFile(skillUrl, "utf8");

    assert.match(skill, /git status --short -- lib priv config mix\.exs README\.md/);
    assert.match(skill, /Require it to print nothing so the package contains only committed content\./);
  });

  await context.test("and the remote branch contains the release commit before Hex publication", async () => {
    const skill = await readFile(skillUrl, "utf8");

    assert.match(
      skill,
      /gh api --method GET 'repos\/\{owner\}\/\{repo\}\/compare\/<release-commit>\.\.\.<remote-branch-tip>'/,
    );
    assert.match(skill, /Require the comparison status to be `identical` or `ahead`\./);
    assert.ok(skill.indexOf("compare/<release-commit>") < skill.indexOf("mix hex.publish --yes"));
  });

  await context.test("and Hex receives the release version as a personally owned public package", async () => {
    const skill = await readFile(skillUrl, "utf8");
    const envExample = await readFile(envExampleUrl, "utf8");

    assert.match(skill, /HEX_API_KEY="\$HEX_TOKEN" mix hex\.publish --yes/);
    assert.match(skill, /Read `@version` from `mix\.exs`\. This is the release version/);
    assert.match(skill, /personally owned public package in the global Hex repository/);
    assert.doesNotMatch(skill, /mix hex\.publish --organization/);
    assert.match(envExample, /personal Hex user `elimydlarz`/);
    assert.doesNotMatch(envExample, /manage both the gralkor organization package/);
  });

  await context.test(
    "and every repository-relative document linked from the published README is included in the Hex package",
    async () => {
      const mix = await readFile(mixUrl, "utf8");

      const files = mix.match(/files:\s*~w\(([^)]+)\)/)?.[1].trim().split(/\s+/);
      assert.ok(files, "Hex package files must be declared");
      for (const document of await readmeDocuments()) {
        assert.ok(files.includes(document), `${document} must be packaged`);
      }
    },
  );

  await context.test(
    "and every repository-relative document linked from the published README is included in the ExDoc extras",
    async () => {
      const mix = await readFile(mixUrl, "utf8");

      const extras = mix.match(/extras:\s*(\[[^\]]+\])/)?.[1];
      assert.ok(extras, "ExDoc extras must be declared");
      const documents = JSON.parse(extras);
      for (const document of await readmeDocuments()) {
        assert.ok(documents.includes(document), `${document} must be an ExDoc extra`);
      }
    },
  );

  await context.test("and the Hex package names `elimydlarz` as its maintainer", async () => {
    const mix = await readFile(mixUrl, "utf8");

    assert.match(mix, /maintainers:\s*\["elimydlarz"\]/);
  });

  await context.test("and GitHub receives a new lightweight release tag for the release commit", async () => {
    const skill = await readFile(skillUrl, "utf8");

    assert.match(skill, /jido-gralkor-v<version>/);
    assert.match(skill, /gh api --method POST 'repos\/\{owner\}\/\{repo\}\/git\/refs'/);
    assert.match(skill, /"ref":"refs\/tags\/jido-gralkor-v<version>"/);
    assert.match(skill, /"sha":"<release-commit>"/);
    assert.match(skill, /--input "<temporary-reference-request>"/);
    assert.doesNotMatch(skill, /-f 'ref=refs\/tags\/jido-gralkor-v<version>'/);
    assert.match(skill, /Create only a lightweight reference/);
    assert.match(skill, /Never update or replace an existing release tag\./);
  });

  await context.test("and remote inspection proves the release tag resolves to the release commit", async () => {
    const skill = await readFile(skillUrl, "utf8");

    assert.match(skill, /git ls-remote origin refs\/tags\/jido-gralkor-v<version>/);
    assert.match(skill, /Require the release tag to resolve to the release commit\./);
  });

  await context.test(
    "and completion reports the version, commit, tag, tests, Hex package, and remote branch",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(
        skill,
        /Report the version, release commit, release tag, test commands, Hex package, and remote branch only after the tag verification succeeds\./,
      );
    },
  );

  await context.test(
    "when another session bumps the version at the same time then the higher of the two versions receives the requested change",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(
        skill,
        /Resolve the conflict by taking the higher of the two versions and applying the requested change to it\./,
      );
    },
  );

  await context.test(
    "if another session has already published the version being released while a major, minor, or patch change was requested then the next patch version is bumped and published instead",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /For `major`, `minor`, or `patch`, return to Bump with `patch`, then restart Publish\./);
      assert.match(
        skill,
        /If Hex rejects the publication because the version already exists, another session published it first\. For `major`, `minor`, or `patch`, return to Bump with `patch` and restart Publish\./,
      );
    },
  );

  await context.test(
    "if another session has already published the version being released while the current version was selected then publishing reports that the version is already published and stops",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /For `current`, report that the version is already published, with its tag, and stop\./);
      assert.match(skill, /For `current`, report that the version is already published and stop\./);
    },
  );
});

test("when the operator selects the current version", async (context) => {
  await context.test("then mix.exs remains unchanged and its existing version is published", async () => {
    const skill = await readFile(skillUrl, "utf8");

    assert.match(skill, /For `current`, do not edit `mix\.exs`\. Continue to Publish\./);
    assert.match(skill, /Read `@version` from `mix\.exs`\. This is the release version/);
  });
});

test(
  "if the version selection is invalid, a required credential is missing, the Hex token does not identify `elimydlarz`, ownership transfer or verification fails, the branch is not the remote default branch, or tests fail",
  async (context) => {
    await context.test("then publishing stops before changing release state", async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /Reject a version selection other than `major`, `minor`, `patch`, or `current`\./);
      assert.match(skill, /Require non-empty `HEX_TOKEN` and `GH_TOKEN` values from `<repo-root>\/\.env`\./);
      assert.match(skill, /Require both credentials before running tests or editing files/);
      assert.match(skill, /Require the authenticated Hex user to equal `elimydlarz`\./);
      assert.match(skill, /Require the current branch to be the remote default branch\./);
      assert.match(skill, /Do not change release state before every preflight check and test command passes\./);
      assert.match(
        skill,
        /Stop before editing `mix\.exs` or publishing to Hex if Hex identity, ownership transfer, or ownership verification fails\./,
      );
    });
  },
);

test(
  "if trunk-sync synchronization, Hex publication, GitHub tag creation, or remote verification fails",
  async (context) => {
    await context.test(
      "then publishing stops without retrying the Hex publication or replacing a release tag",
      async () => {
        const skill = await readFile(skillUrl, "utf8");

        assert.match(skill, /Fail visibly on every command error\./);
        assert.match(skill, /Do not retry a Hex publication automatically after an error other than "version already exists"/);
        assert.match(skill, /Never replace a local or remote release tag\./);
      },
    );

    await context.test(
      "and it reports the release version, release commit, Hex result, and exact remote branch and tag state",
      async () => {
        const skill = await readFile(skillUrl, "utf8");

        assert.match(
          skill,
          /Report the release version, release commit, Hex result, and exact remote branch and tag state\./,
        );
      },
    );
  },
);
