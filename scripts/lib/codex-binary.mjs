import os from "node:os";
import path from "node:path";
import process from "node:process";
import { binaryAvailable } from "./process.mjs";

// Claude Remote may retain an older standalone CLI at the front of PATH.
// Prefer the newest installed runtime, while preserving an explicit override.
export function resolveCodexBinary(options = {}) {
  const env = options.env ?? process.env;
  const probe = options.probe ?? ((command) => binaryAvailable(command, ["--version"], { cwd: options.cwd, env }));
  if (env.CODEX_COMPANION_BINARY) {
    const status = probe(env.CODEX_COMPANION_BINARY);
    return { command: env.CODEX_COMPANION_BINARY, ...status };
  }
  const platform = options.platform ?? process.platform;
  const home = options.home ?? os.homedir();
  const candidates = options.candidates ?? [
    "codex",
    ...(platform === "darwin" ? [
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/Applications/Codex.app/Contents/Resources/codex",
      path.join(home, "Applications/ChatGPT.app/Contents/Resources/codex"),
      path.join(home, "Applications/Codex.app/Contents/Resources/codex")
    ] : [])
  ];
  const checked = candidates.map((command) => ({ command, ...probe(command) }));
  const available = checked.filter((entry) => entry.available);
  const version = (detail) => (detail.match(/(\d+)\.(\d+)\.(\d+)/)?.slice(1).map(Number) ?? [0, 0, 0]);
  available.sort((a, b) => {
    const av = version(a.detail), bv = version(b.detail);
    for (let i = 0; i < 3; i += 1) if (av[i] !== bv[i]) return bv[i] - av[i];
    return 0;
  });
  return available[0] ?? checked[0];
}
