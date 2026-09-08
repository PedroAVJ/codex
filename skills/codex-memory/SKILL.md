---
name: codex-memory
description: Use in Claude Code when a task may depend on the user's prior cross-client context, or when the user explicitly asks Claude to remember, correct, or forget something in canonical Codex memory. Do not use for facts available from the current repository or a live system.
allowed-tools: Bash(node:*), Read, Grep
---

# Codex Memory

Use Codex local memory as the single cross-client memory store. This skill is a
Claude Code adapter; Codex already has native memory integration.

## Boundaries

- The session hook already injects the compact `memory_summary.md` when it is
  available. Search deeper only when prior decisions, preferences, corrections,
  or workspace history can materially change the answer.
- Never use `~/.codex/memories/skills/` as a capability source. Stable
  procedures belong to maintained plugin or repository skills.
- Treat retrieved memory as potentially stale. Query the canonical live system
  when current state matters.
- Never edit `MEMORY.md`, `memory_summary.md`, rollout summaries, or generated
  memory directories directly.
- Submit a persistent change only when the user explicitly asks to remember,
  correct, update, retract, or forget something. Do not infer authorization
  merely because a correction appeared during ordinary task work.
- Do not submit secrets, credentials, visa or document identifiers, verification
  codes, or unrelated private content.

## Inspect or search

Check bridge state with:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-memory.mjs" status
```

For a deeper lookup, send the query on stdin so user text is not interpolated as
shell code:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-memory.mjs" search --limit 5 <<'CODEX_MEMORY_QUERY'
the exact topic or question to look up
CODEX_MEMORY_QUERY
```

Use only the most relevant results. If a registry entry points to evidence and
exact historical details are necessary, open at most one or two directly
relevant evidence files.

## Submit an explicit update

Choose `add`, `correct`, or `retract`. Preserve the user's intended meaning without
adding conclusions. Use a short non-sensitive slug and send the requested note
on literal stdin:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-memory.mjs" submit correct short-topic --confirm <<'CODEX_MEMORY_UPDATE'
The exact durable fact or correction the user explicitly asked to persist.
CODEX_MEMORY_UPDATE
```

The helper creates one append-only ad-hoc note for Codex's background
consolidation model. Report the returned note path and say that consolidation is
pending; do not claim the generated summary or registry changed immediately.
