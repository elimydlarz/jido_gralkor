import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import test from "node:test";

const run = promisify(execFile);
const projectRoot = new URL("..", import.meta.url);

test("when a maintainer asks Mix to run the complete test suite", async (context) => {
  await context.test(
    "then `mix test.all` runs Unit, Integration, Functional, and Journey coverage in one ExUnit virtual machine",
    async () => {
      const { stdout } = await run("mix", ["help", "test.all"], { cwd: projectRoot });

      assert.match(stdout, /mix test\.all/);
      assert.match(stdout, /test --include functional --include journey/);
    },
  );

  await context.test("and the publish-skill contract runs after ExUnit succeeds", async () => {
    const { stdout } = await run("mix", ["help", "test.all"], { cwd: projectRoot });
    const exUnit = stdout.indexOf("test --include functional --include journey");
    const node = stdout.indexOf("cmd node --test");

    assert.ok(node > exUnit);
  });
});
