#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import process from "node:process";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";

const THREAD_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ANSI_PATTERN = /\u001b\[[0-?]*[ -\/]*[@-~]/g;

export const PERMISSION_BOOTSTRAP =
  "Permission bootstrap only. Do not call tools, inspect files, or begin stewardship work. Reply exactly READY.";

export function buildPermissionBootstrapArgs({ threadId, cwd }) {
  if (!THREAD_ID_PATTERN.test(threadId ?? "")) {
    throw new Error("--thread-id must be a Codex task UUID");
  }

  const resolvedCwd = realpathSync(cwd);
  return [
    "exec",
    "--color",
    "never",
    "--dangerously-bypass-approvals-and-sandbox",
    "--dangerously-bypass-hook-trust",
    "--skip-git-repo-check",
    "-C",
    resolvedCwd,
    "resume",
    "--all",
    threadId,
    PERMISSION_BOOTSTRAP
  ];
}

export function assertPermissionBootstrap(result) {
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const detail = String(result.stderr ?? "").trim();
    throw new Error(`Codex permission bootstrap failed${detail ? `: ${detail}` : ""}`);
  }

  const stderr = String(result.stderr ?? "").replace(ANSI_PATTERN, "");
  const stdout = String(result.stdout ?? "").replace(ANSI_PATTERN, "").trim();
  if (!/^approval:\s*never$/im.test(stderr)) {
    throw new Error("Codex did not confirm approval policy never");
  }
  if (!/^sandbox:\s*danger-full-access$/im.test(stderr)) {
    throw new Error("Codex did not confirm the danger-full-access sandbox");
  }
  if (!/(?:^|\n)READY$/i.test(stdout)) {
    throw new Error("Codex permission bootstrap did not finish with READY");
  }
}

export function prepareVisibleTask({
  threadId,
  cwd,
  command = "codex",
  run = spawnSync
}) {
  const args = buildPermissionBootstrapArgs({ threadId, cwd });
  const result = run(command, args, {
    cwd: realpathSync(cwd),
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
    timeout: 60_000
  });
  assertPermissionBootstrap(result);
  return { ready: true, threadId };
}

function main() {
  const { values } = parseArgs({
    args: process.argv.slice(2),
    strict: true,
    allowPositionals: false,
    options: {
      "thread-id": { type: "string" },
      cwd: { type: "string" }
    }
  });

  if (!values["thread-id"] || !values.cwd) {
    throw new Error("usage: prepare-visible-task.mjs --thread-id <uuid> --cwd <directory>");
  }

  const result = prepareVisibleTask({
    threadId: values["thread-id"],
    cwd: values.cwd
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}
