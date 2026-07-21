import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const skillUrl = new URL("../.agents/skills/publish/SKILL.md", import.meta.url);
const openaiYamlUrl = new URL("../.agents/skills/publish/agents/openai.yaml", import.meta.url);
const envExampleUrl = new URL("../.env.example", import.meta.url);

test("when an operator asks to publish jido_gralkor with a semantic-version change kind", async (context) => {
  await context.test("then the semantic-version change kind is the only required operator input", async () => {
    const skill = await readFile(skillUrl, "utf8");
    const openaiYaml = await readFile(openaiYamlUrl, "utf8");

    assert.match(skill, /Require exactly `<major\|minor\|patch>` from the operator's request\./);
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

  await context.test("and the complete test suite passes before release state changes", async () => {
    const skill = await readFile(skillUrl, "utf8");

    assert.match(skill, /Run `mix test`, `mix test\.functional`, and `mix test\.journey` before editing the version\./);
  });

  await context.test(
    "and the required Hex and GitHub credentials are loaded from the repository environment",
    async () => {
      const skill = await readFile(skillUrl, "utf8");
      const envExample = await readFile(envExampleUrl, "utf8");

      assert.match(skill, /Require non-empty `GRALKOR_HEX_TOKEN` and `GH_TOKEN` values from `<repo-root>\/\.env`\./);
      assert.match(envExample, /^GRALKOR_HEX_TOKEN=$/m);
      assert.match(envExample, /^GH_TOKEN=$/m);
      assert.match(envExample, /Contents write permission/);
    },
  );

  await context.test(
    "and the version change is synchronized to the remote default branch by trunk-sync before Hex publication",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /Read `@version` from `mix\.exs` and calculate the requested semantic-version change\./);
      assert.match(skill, /Edit only `@version` in `mix\.exs`/);
      assert.match(skill, /Require the command's trunk-sync hook result to succeed/);
      assert.match(skill, /Require trunk-sync to commit and push the version change/);
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
    "and Hex receives the synchronized version through the gralkor organization token",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /HEX_API_KEY="\$GRALKOR_HEX_TOKEN" mix hex\.publish --yes/);
      assert.match(skill, /Require `mix\.exs` still to contain the prepared version/);
      assert.match(skill, /Require `HEAD` and the remote branch tip still to equal the synchronized release commit/);
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
    "and remote inspection proves the branch and release tag resolve to the release commit",
    async () => {
      const skill = await readFile(skillUrl, "utf8");

      assert.match(skill, /git ls-remote origin refs\/heads\/<current-branch> refs\/tags\/jido-gralkor-v<version>/);
      assert.match(skill, /Require both remote refs to resolve to the synchronized release commit\./);
    },
  );
});
