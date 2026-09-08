#!/usr/bin/env node

import process from "node:process";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";

export const NON_BLOCKING_DISPATCH = Object.freeze({
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

export const VISIBLE_TASK_DISPATCH = Object.freeze({
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

export function assessFeedbackCandidate(candidate = {}) {
  const reasons = [];

  if (candidate.origin !== "direct-user") reasons.push("not-direct-user-feedback");
  if (candidate.explicitCorrection !== true) reasons.push("not-an-explicit-correction");
  if (candidate.reusable !== true) reasons.push("not-reusable-future-behavior");
  if (candidate.likelyPluginOwned !== true) reasons.push("plugin-owner-not-likely");
  if (candidate.safeSummary !== true) reasons.push("no-safe-minimal-summary");
  if (candidate.implementationRequest === true) reasons.push("explicit-implementation-request");
  if (candidate.taskSpecific === true) reasons.push("task-specific-only");
  if (candidate.preferenceOnly === true) reasons.push("preference-only");
  if (candidate.emotionalOnly === true) reasons.push("emotional-reaction-only");
  if (candidate.sensitiveSummaryRequired === true) reasons.push("sensitive-context-required");
  if (candidate.permissionExpanding === true) reasons.push("would-expand-permissions");

  const eligible = reasons.length === 0;
  return {
    eligible,
    reasons,
    dispatch: eligible
      ? (candidate.separateTaskRequested === true ? VISIBLE_TASK_DISPATCH : NON_BLOCKING_DISPATCH)
      : null
  };
}

function candidateFromArgs(argv) {
  const { values } = parseArgs({
    args: argv,
    strict: true,
    allowPositionals: false,
    options: {
      origin: { type: "string", default: "unknown" },
      "explicit-correction": { type: "boolean", default: false },
      reusable: { type: "boolean", default: false },
      "likely-plugin-owned": { type: "boolean", default: false },
      "safe-summary": { type: "boolean", default: false },
      "implementation-request": { type: "boolean", default: false },
      "separate-task-requested": { type: "boolean", default: false },
      "task-specific": { type: "boolean", default: false },
      "preference-only": { type: "boolean", default: false },
      "emotional-only": { type: "boolean", default: false },
      "sensitive-summary-required": { type: "boolean", default: false },
      "permission-expanding": { type: "boolean", default: false }
    }
  });

  return {
    origin: values.origin,
    explicitCorrection: values["explicit-correction"],
    reusable: values.reusable,
    likelyPluginOwned: values["likely-plugin-owned"],
    safeSummary: values["safe-summary"],
    implementationRequest: values["implementation-request"],
    separateTaskRequested: values["separate-task-requested"],
    taskSpecific: values["task-specific"],
    preferenceOnly: values["preference-only"],
    emotionalOnly: values["emotional-only"],
    sensitiveSummaryRequired: values["sensitive-summary-required"],
    permissionExpanding: values["permission-expanding"]
  };
}

function main() {
  const result = assessFeedbackCandidate(candidateFromArgs(process.argv.slice(2)));
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 2;
  }
}
