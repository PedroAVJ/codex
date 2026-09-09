import test from "node:test";
import assert from "node:assert/strict";
import { resolveCodexBinary } from "../scripts/lib/codex-binary.mjs";

test("selects newer desktop runtime when PATH retains an older standalone CLI", () => {
  const result = resolveCodexBinary({ env: {}, candidates: ["old-cli", "desktop"], probe: (command) => ({ available: true, detail: command === "old-cli" ? "codex-cli 0.151.0" : "codex-cli 0.153.4" }) });
  assert.equal(result.command, "desktop");
});
test("retains a newer PATH CLI and skips unavailable bundles", () => {
  const result = resolveCodexBinary({ env: {}, candidates: ["codex", "missing", "older"], probe: (command) => ({ available: command !== "missing", detail: command === "codex" ? "codex-cli 0.154.0" : "codex-cli 0.153.4" }) });
  assert.equal(result.command, "codex");
});
test("explicit binary selection is authoritative, including a failed probe", () => {
  const calls = [];
  const result = resolveCodexBinary({ env: { CODEX_COMPANION_BINARY: "/chosen/codex" }, probe: (command) => { calls.push(command); return { available: false, detail: "not found" }; } });
  assert.deepEqual(calls, ["/chosen/codex"]);
  assert.equal(result.available, false);
});
