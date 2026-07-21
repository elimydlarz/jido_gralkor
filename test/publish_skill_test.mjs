import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const skillUrl = new URL("../.agents/skills/publish/SKILL.md", import.meta.url);
const openaiYamlUrl = new URL("../.agents/skills/publish/agents/openai.yaml", import.meta.url);

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
});
