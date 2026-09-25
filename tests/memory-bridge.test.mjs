import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  formatMemorySearchResults,
  searchMemoryText,
  submitMemoryUpdate
} from "../scripts/lib/memory.mjs";

function fixture() {
  const directory = mkdtempSync(path.join(os.tmpdir(), "codex-memory-bridge-"));
  const codexHome = path.join(directory, ".codex");
  const memories = path.join(codexHome, "memories");
  mkdirSync(memories, { recursive: true });
  return {
    directory,
    codexHome,
    memories,
    env: { ...process.env, CODEX_HOME: codexHome }
  };
}

test("memory search ranks relevant registry paragraphs and reports source lines", () => {
  const text = [
    "# Travel",
    "",
    "The user prefers concise answers.",
    "",
    "# Browser",
    "",
    "Use Chrome for interactive browser work.",
    ""
  ].join("\n");
  const results = searchMemoryText(text, "which browser should I use", { limit: 2 });
  assert.equal(results.length, 1);
  assert.match(results[0].content, /Chrome/);
  assert.match(formatMemorySearchResults(results), /MEMORY\.md:7-7/);
});

test("submitMemoryUpdate writes one append-only note and leaves generated files unchanged", (t) => {
  const state = fixture();
  t.after(() => rmSync(state.directory, { recursive: true, force: true }));
  const registry = path.join(state.memories, "MEMORY.md");
  const summary = path.join(state.memories, "memory_summary.md");
  writeFileSync(registry, "registry-before\n");
  writeFileSync(summary, "summary-before\n");

  const result = submitMemoryUpdate({
    operation: "correct",
    slug: "Browser Preference",
    content: "Use Chrome for interactive browser tasks.",
    source: "claude-code",
    sessionId: "session-123",
    cwd: "/tmp/project",
    env: state.env,
    now: new Date("2026-08-24T21:45:33.000Z")
  });

  assert.match(path.basename(result.file), /^20260824T214533Z-browser-preference\.md$/);
  const note = readFileSync(result.file, "utf8");
  assert.match(note, /Codex memory correct request/);
  assert.match(note, /Use Chrome for interactive browser tasks/);
  assert.equal(readFileSync(registry, "utf8"), "registry-before\n");
  assert.equal(readFileSync(summary, "utf8"), "summary-before\n");
});
