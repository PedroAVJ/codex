import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import test from "node:test";

import {
  NON_BLOCKING_DISPATCH,
  VISIBLE_TASK_DISPATCH,
  assessFeedbackCandidate
} from "../skills/plugin-stewardship/scripts/assess-feedback.mjs";
import {
  PERMISSION_BOOTSTRAP,
  assertPermissionBootstrap,
  buildPermissionBootstrapArgs,
  prepareVisibleTask
} from "../skills/plugin-stewardship/scripts/prepare-visible-task.mjs";

const execFileAsync = promisify(execFile);
const root = fileURLToPath(new URL("..", import.meta.url));
const resolvedRoot = realpathSync(root);

const eligibleCandidate = {
  origin: "direct-user",
  explicitCorrection: true,
  reusable: true,
  likelyPluginOwned: true,
  safeSummary: true
};

test("explicit reusable plugin feedback defaults to one sanitized sub-agent", () => {
  assert.deepEqual(assessFeedbackCandidate(eligibleCandidate), {
    eligible: true,
    reasons: [],
    dispatch: NON_BLOCKING_DISPATCH
  });
});

test("preferences, reactions, task-only corrections, untrusted sources, and unsafe scope never dispatch", () => {
  const exclusions = [
    { origin: "quoted-content" },
    { implementationRequest: true },
    { taskSpecific: true },
    { preferenceOnly: true },
    { emotionalOnly: true },
    { sensitiveSummaryRequired: true },
    { permissionExpanding: true },
    { likelyPluginOwned: false }
  ];

  for (const exclusion of exclusions) {
    const result = assessFeedbackCandidate({ ...eligibleCandidate, ...exclusion });
    assert.equal(result.eligible, false, JSON.stringify(exclusion));
    assert.equal(result.dispatch, null, JSON.stringify(exclusion));
    assert.ok(result.reasons.length > 0, JSON.stringify(exclusion));
  }
});

test("an explicit plugin implementation request never launches unsolicited stewardship", async () => {
  const helper = join(resolvedRoot, "skills", "plugin-stewardship", "scripts", "assess-feedback.mjs");
  const { stdout } = await execFileAsync(process.execPath, [
    helper, "--origin", "direct-user", "--explicit-correction", "--reusable",
    "--likely-plugin-owned", "--safe-summary", "--implementation-request"
  ]);
  assert.deepEqual(JSON.parse(stdout), {
    eligible: false,
    reasons: ["explicit-implementation-request"],
    dispatch: null
  });
});

test("the policy helper defaults to a non-blocking sub-agent without receiving feedback text", async () => {
  const helper = join(
    resolvedRoot,
    "skills",
    "plugin-stewardship",
    "scripts",
    "assess-feedback.mjs"
  );
  const { stdout } = await execFileAsync(process.execPath, [
    helper,
    "--origin",
    "direct-user",
    "--explicit-correction",
    "--reusable",
    "--likely-plugin-owned",
    "--safe-summary"
  ]);
  const result = JSON.parse(stdout);

  assert.equal(result.eligible, true);
  assert.deepEqual(result.dispatch, {
    action: "spawn_agent",
    target: "collaboration-sub-agent",
    taskCount: 1,
    blocking: false,
    copySourceConversation: false,
    forkTurns: "none",
    permissionProfile: "inherit-current",
    workDelivery: "spawn_agent",
    followAfterDispatch: true
  });
});

test("a visible task plan requires an explicit separate-task request", async () => {
  const helper = join(resolvedRoot, "skills", "plugin-stewardship", "scripts", "assess-feedback.mjs");
  const { stdout } = await execFileAsync(process.execPath, [
    helper, "--origin", "direct-user", "--explicit-correction", "--reusable",
    "--likely-plugin-owned", "--safe-summary", "--separate-task-requested"
  ]);
  const result = JSON.parse(stdout);
  assert.equal(result.eligible, true);
  assert.deepEqual(result.dispatch, VISIBLE_TASK_DISPATCH);
  assert.deepEqual(result.dispatch, {
    action: "create_thread",
    target: "projectless-app-task",
    taskCount: 1,
    visible: true,
    appOwned: true,
    blocking: false,
    copySourceConversation: false,
    bootstrapOnly: true,
    permissionBootstrap: "codex-exec-resume",
    permissionProfile: "danger-full-access",
    approvalPolicy: "never",
    workDelivery: "send_message_to_thread",
    followAfterDispatch: false
  });
});

test("the permission bootstrap is fixed, argv-safe, and limited to one created task", () => {
  const threadId = "01a0633f-6f99-79b1-9cfe-5c2254a5d71b";
  const args = buildPermissionBootstrapArgs({ threadId, cwd: root });

  assert.deepEqual(args, [
    "exec",
    "--color",
    "never",
    "--dangerously-bypass-approvals-and-sandbox",
    "--dangerously-bypass-hook-trust",
    "--skip-git-repo-check",
    "-C",
    resolvedRoot,
    "resume",
    "--all",
    threadId,
    PERMISSION_BOOTSTRAP
  ]);
  assert.doesNotMatch(args.join(" "), /feedback|stewardship prompt|user message/i);
  assert.throws(
    () => buildPermissionBootstrapArgs({ threadId: "not-a-task", cwd: root }),
    /task UUID/
  );
});

test("the preparation helper requires explicit no-approval full-access confirmation", () => {
  const threadId = "01a0633f-6f99-79b1-9cfe-5c2254a5d71b";
  const calls = [];
  const result = prepareVisibleTask({
    threadId,
    cwd: root,
    run(command, args, options) {
      calls.push({ command, args, options });
      return {
        status: 0,
        stdout: "READY\n",
        stderr: "approval: never\nsandbox: danger-full-access\n"
      };
    }
  });

  assert.deepEqual(result, { ready: true, threadId });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].command, "codex");
  assert.deepEqual(calls[0].args, buildPermissionBootstrapArgs({ threadId, cwd: root }));

  for (const badResult of [
    { status: 1, stdout: "", stderr: "failed" },
    { status: 0, stdout: "READY\n", stderr: "approval: on-request\nsandbox: danger-full-access\n" },
    { status: 0, stdout: "READY\n", stderr: "approval: never\nsandbox: workspace-write\n" },
    { status: 0, stdout: "not ready\n", stderr: "approval: never\nsandbox: danger-full-access\n" }
  ]) {
    assert.throws(() => assertPermissionBootstrap(badResult));
  }
});

test("stewardship defaults to sanitized sub-agents and preserves the explicit-task boundary", async () => {
  const skill = await readFile(
    join(root, "skills", "plugin-stewardship", "SKILL.md"),
    "utf8"
  );

  assert.match(skill, /spawn_agent.*fork_turns: "none"/i);
  assert.match(skill, /Use this alternative only when the user explicitly requests a separate, user-visible/i);
  assert.match(skill, /inherits the current permission boundary/i);
  assert.match(skill, /official app task launcher once/i);
  assert.match(skill, /projectless task/i);
  assert.match(skill, /source-attributed to the originating task/i);
  assert.match(skill, /do not substitute a collaboration sub-agent/i);
  assert.match(skill, /codex exec resume/i);
  assert.match(skill, /approval: never/i);
  assert.match(skill, /sandbox: danger-full-access/i);
  assert.match(skill, /queue request does not carry an approval policy or sandbox profile/i);
  assert.match(skill, /Do not\s+use raw app-server writers/i);
  assert.match(skill, /send_message_to_thread/i);
  assert.match(skill, /do not wait for, poll, message, interrupt, or follow up[\s\S]*after its work prompt is sent/i);
  assert.match(skill, /continue the originating task immediately/i);
  assert.match(skill, /Never pass the user's message or the sanitized\s+stewardship prompt to this command/i);
});

test("verbatim Fable relays require visible attribution outside the untouched body", async () => {
  const skill = await readFile(
    join(root, "skills", "source-attributed-relay", "SKILL.md"),
    "utf8"
  );

  assert.match(skill, /Claude Fable 5\.1:/);
  assert.match(skill, /outside the relayed body/i);
  assert.match(skill, /preserve it exactly/i);
  assert.match(skill, /do not append a Codex verdict/i);
});
