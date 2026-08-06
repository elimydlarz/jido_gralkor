import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import test from "node:test";

const run = promisify(execFile);
const projectRoot = new URL("..", import.meta.url);

test("when a maintainer asks Mix to run all tests", async (context) => {
  await context.test(
    "then `mix test.all` runs all Unit, Integration, Functional, Journey, and publish-skill contract tests",
    async () => {
      const { stdout } = await run("mix", ["help", "test.all"], { cwd: projectRoot });

      assert.match(stdout, /mix test\.all/);
      assert.match(stdout, /&test_all\/1/);
    },
  );
});
