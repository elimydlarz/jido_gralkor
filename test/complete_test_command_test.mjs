import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import test from "node:test";

const run = promisify(execFile);
const projectRoot = fileURLToPath(new URL("..", import.meta.url));
const { stdout: mixPathOutput } = await run("which", ["mix"]);
const mixPath = mixPathOutput.trim();

async function runAllTests({ mixStatus = 0, nodeStatus = 0 } = {}) {
  const bin = await mkdtemp(join(tmpdir(), "jido-gralkor-test-all-"));
  const callsPath = join(bin, "calls");

  await writeFile(
    join(bin, "mix"),
    `#!/bin/sh\nprintf 'mix %s\\n' "$*" >> "$TEST_ALL_CALLS"\nexit ${mixStatus}\n`,
    { mode: 0o755 },
  );
  await writeFile(
    join(bin, "node"),
    `#!/bin/sh\nprintf 'node %s\\n' "$*" >> "$TEST_ALL_CALLS"\nexit ${nodeStatus}\n`,
    { mode: 0o755 },
  );

  let result;

  try {
    result = await run(mixPath, ["test.all"], {
      cwd: projectRoot,
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        TEST_ALL_CALLS: callsPath,
      },
    });
  } catch (error) {
    result = error;
  }

  const calls = await readFile(callsPath, "utf8");
  await rm(bin, { recursive: true });
  return { calls, status: result.code ?? 0 };
}

test("when a maintainer asks Mix to run all tests", async (context) => {
  await context.test(
    "then `mix test.all` runs all Unit, Integration, Functional, Journey, and publish-skill contract tests",
    async () => {
      const { calls } = await runAllTests();

      assert.equal(
        calls,
        "mix test --include functional --include journey\nnode --test\n",
      );
    },
  );

  await context.test("if the ExUnit suite fails", async (failure) => {
    const outcome = await runAllTests({ mixStatus: 1 });

    await failure.test("then the Node contract tests still run", () => {
      assert.match(outcome.calls, /node --test/);
    });

    await failure.test("and the complete command fails", () => {
      assert.equal(outcome.status, 1);
    });
  });

  await context.test("if the Node contract tests fail", async (failure) => {
    await failure.test("then the complete command fails", async () => {
      const { status } = await runAllTests({ nodeStatus: 1 });
      assert.equal(status, 1);
    });
  });

  await context.test("if both test runners pass", async (success) => {
    await success.test("then the complete command succeeds", async () => {
      const { status } = await runAllTests();
      assert.equal(status, 0);
    });
  });
});
