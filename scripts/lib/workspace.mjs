import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ensureGitRepository } from "./git.mjs";

export function resolveWorkspaceRoot(cwd) {
  try {
    return ensureGitRepository(cwd);
  } catch {
    return cwd;
  }
}

// State stays keyed to the calling workspace; only the task execution directory
// moves. This preserves existing tracked resume IDs after upgrading the plugin.
export function resolveTaskWorkspace(cwd, options = {}) {
  const env = options.env ?? process.env;
  const homeDir = options.homeDir ?? os.homedir();
  const absoluteCwd = path.resolve(cwd);
  if (options.explicitCwd) return absoluteCwd;

  const broadRoots = [homeDir, path.join(homeDir, "Developer"), path.join(homeDir, "Desktop")];
  if (!broadRoots.includes(absoluteCwd)) return absoluteCwd;

  const identity = `${absoluteCwd}\0${env.CODEX_COMPANION_SESSION_ID ?? "default"}`;
  const key = createHash("sha256").update(identity).digest("hex").slice(0, 16);
  const dataRoot = env.CLAUDE_PLUGIN_DATA || path.join(homeDir, ".local", "share", "codex-companion");
  const workspace = path.join(dataRoot, "workspaces", key);
  if (options.create !== false) fs.mkdirSync(workspace, { recursive: true });
  return workspace;
}
