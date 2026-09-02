import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import test from "node:test";

const run = promisify(execFile);
const projectRoot = fileURLToPath(new URL("..", import.meta.url));

test("when Stop observes an active saved-file feedback run that remains active for two minutes", async () => {
  const fixture = await mkdtemp(join(tmpdir(), "jido-gralkor-stop-feedback-"));
  const hooks = join(fixture, ".fasset-harness", "hooks");
  const checks = join(fixture, ".fasset-harness", "feedback", "stop.d");
  const running = join(fixture, ".fasset-harness", "state", "optimistic-feedback", "running");
  const owner = join(running, ".edit.owner.test");
  const bin = join(fixture, "bin");
  const checkMarker = join(fixture, "stop-check-started");
  const dateCalls = join(fixture, "date-calls");
  const activeRun = spawn("sleep", ["30"]);

  await Promise.all([
    mkdir(hooks, { recursive: true }),
    mkdir(checks, { recursive: true }),
    mkdir(owner, { recursive: true }),
    mkdir(bin, { recursive: true }),
  ]);

  await copyFile(
    join(projectRoot, ".fasset-harness", "hooks", "stop-feedback.sh"),
    join(hooks, "stop-feedback.sh"),
  );
  await writeFile(join(owner, "owner"), `${activeRun.pid}\n`);
  await writeFile(join(running, "edit"), ".edit.owner.test", { flag: "wx" }).catch(async () => {
    await rm(join(running, "edit"));
  });
  await rm(join(running, "edit"), { force: true });
  await import("node:fs/promises").then(({ symlink }) =>
    symlink(".edit.owner.test", join(running, "edit")),
  );
  await writeFile(
    join(checks, "record-start"),
    `#!/bin/sh\ntouch "${checkMarker}"\n`,
    { mode: 0o755 },
  );
  await writeFile(
    join(bin, "date"),
    `#!/bin/sh\nif [ -e "${dateCalls}" ]; then printf '121\\n'; else touch "${dateCalls}"; printf '0\\n'; fi\n`,
    { mode: 0o755 },
  );
  await writeFile(join(bin, "sleep"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });

  let outcome;

  try {
    outcome = await run("bash", [join(hooks, "stop-feedback.sh")], {
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
      input: "{}",
      timeout: 1000,
    });
  } catch (error) {
    outcome = error;
  }

  assert.equal(outcome.code, 2);
  assert.match(outcome.stderr, /edit.*120 seconds/i);
  await assert.rejects(readFile(checkMarker));

  await new Promise((resolve) => activeRun.once("exit", resolve));
  await rm(fixture, { recursive: true });
});
