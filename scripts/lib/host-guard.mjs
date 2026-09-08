import process from "node:process";

/**
 * The companion exists so Claude Code can hand work to Codex. Run from Codex
 * it would spawn a nested `codex exec` to have GPT rescue, review, or second-
 * opinion its own output — the failure is silent and the result looks correct,
 * which is exactly why it has to fail closed.
 *
 * `CLAUDECODE` is set in every Claude Code session and absent under Codex, so
 * host detection here is a fact rather than a heuristic.
 *
 * Only the delegation surface is guarded. The `internals` and `patching`
 * skills inspect the local desktop app and are legitimately useful from either
 * host, so they carry no guard.
 */
export function runningInsideClaudeCode() {
  return Boolean(process.env.CLAUDECODE);
}

export function assertClaudeCodeHost(surface) {
  if (runningInsideClaudeCode()) return;
  process.stderr.write(
    `${surface} refused: this is Claude Code's handoff to Codex, and $CLAUDECODE is not set, ` +
      `so the host is already Codex. Asking Codex to rescue or review itself does not ` +
      `produce an outside pass — do the work directly instead.\n`
  );
  process.exit(2);
}
