#!/usr/bin/env node

import fs from "node:fs";
import process from "node:process";

import {
  buildClaudeMemoryContext,
  formatMemorySearchResults,
  memoryBridgeEnabled,
  readClaudeAutoMemoryStatus,
  resolveMemoryPaths,
  searchMemoryRegistry,
  submitMemoryUpdate
} from "./lib/memory.mjs";

function readStdin() {
  return fs.readFileSync(0, "utf8");
}

function takeOption(args, name) {
  const index = args.indexOf(name);
  if (index < 0) return null;
  const value = args[index + 1];
  if (value == null) throw new Error(`${name} requires a value.`);
  args.splice(index, 2);
  return value;
}

function hasFlag(args, name) {
  const index = args.indexOf(name);
  if (index < 0) return false;
  args.splice(index, 1);
  return true;
}

function usage() {
  return [
    "Usage:",
    "  codex-memory.mjs status",
    "  codex-memory.mjs context",
    "  codex-memory.mjs search [--limit N] [query]",
    "  codex-memory.mjs submit <add|correct|retract> <slug> --confirm [--session-id ID] [--cwd PATH]",
    "",
    "Search queries and submit content may be supplied on stdin. Submissions require --confirm."
  ].join("\n");
}

function status() {
  const paths = resolveMemoryPaths();
  const claudeMemory = readClaudeAutoMemoryStatus();
  process.stdout.write(`${JSON.stringify({
    enabled: memoryBridgeEnabled(),
    codexHome: paths.codexHome,
    summaryFile: paths.summary,
    summaryExists: fs.existsSync(paths.summary),
    registryFile: paths.registry,
    registryExists: fs.existsSync(paths.registry),
    updateNotesDirectory: paths.notes,
    claudeAutoMemory: claudeMemory
  }, null, 2)}\n`);
}

function context() {
  const value = buildClaudeMemoryContext();
  if (value) process.stdout.write(`${value}\n`);
}

function search(args) {
  const limit = Number(takeOption(args, "--limit") ?? 5);
  const argumentQuery = args.join(" ").trim();
  const query = argumentQuery || readStdin().trim();
  const { path, results } = searchMemoryRegistry(query, { limit });
  process.stdout.write(`${formatMemorySearchResults(results, { file: path })}\n`);
}

function submit(args) {
  const operation = args.shift();
  const slug = args.shift();
  const confirmed = hasFlag(args, "--confirm");
  const sessionId = takeOption(args, "--session-id") ?? process.env.CODEX_COMPANION_SESSION_ID ?? "";
  const cwd = takeOption(args, "--cwd") ?? process.cwd();
  if (!confirmed) throw new Error("Refusing to submit a memory update without --confirm.");
  if (args.length > 0) throw new Error(`Unexpected submit arguments: ${args.join(" ")}`);
  const content = readStdin();
  const result = submitMemoryUpdate({ operation, slug, content, sessionId, cwd });
  process.stdout.write(`${JSON.stringify({
    status: "submitted-for-consolidation",
    ...result
  }, null, 2)}\n`);
}

function main() {
  const args = process.argv.slice(2);
  const command = args.shift();
  if (command === "status") return status();
  if (command === "context") return context();
  if (command === "search") return search(args);
  if (command === "submit") return submit(args);
  throw new Error(usage());
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}
