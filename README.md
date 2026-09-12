# Codex App

OpenAI Codex as a coding agent: CLI and app-server integration, Claude Code
handoffs, reviews, hooks, prompting, result handling, and the Codex Voice
iPhone and Apple Watch companion.

## Product boundary

ChatGPT and Codex now share one macOS application bundle, but they remain useful
product identities. This plugin owns what is specifically Codex:

- the Codex CLI and app-server runtime;
- rescue and review handoffs from Claude Code;
- lifecycle, shared-memory, and stop-review hooks;
- user-controlled realtime conversation queues and sub-agent-first delegated work;
- coding, image-generation prompting, and source-attributed result handling; and
- the end-to-end encrypted Codex Voice Mac bridge, remote relay, minimal iPhone
  pairing companion, and voice-first Apple Watch app.

The shared desktop bundle, its feature gates, automations, and explicit patch or
restore workflow belong to `chatgpt@package-manager`.

Codex Voice's product source lives under
`products/codex-voice/`. Its active operating skill is exported from
`skills/codex-voice/`, so installing Codex is sufficient; there is no separate
Codex Voice plugin or user-configured prompt. Existing bridge keys, pairing
state, API credentials, and logs live outside the plugin cache and survive an
upgrade.

## Claude Code surface

The `commands/`, `agents/`, `hooks/`, `prompts/`, `schemas/`, and `scripts/`
payload is based on OpenAI's `codex-plugin-cc`. It lets Claude Code hand one
bounded coding task to Codex, run native or adversarial reviews, monitor the
result, enforce an optional stop-time review gate, and use Codex local memory as
the canonical cross-client personal context store.

When `~/.codex/memories/memory_summary.md` exists, the Claude `SessionStart` and
`SubagentStart` hooks inject that compact generated summary. The
`codex:codex-memory` skill searches the deeper registry and accepts explicit
add, correction, or retraction requests as append-only ad-hoc notes for Codex's
background consolidation model. It never edits generated memory files or loads
memory-derived skills. Set `CODEX_MEMORY_BRIDGE=0` to disable context injection.
Claude native auto-memory should remain disabled rather than pointing it at the
Codex memory directory.

The rescue companion host guard intentionally refuses to delegate when the host is already
Codex. Explicit named Spark requests use the separate `scripts/named-participant.mjs`
bounded CLI helper; this does not bypass or change the rescue guard. That keeps installing this product-level plugin in Codex conceptually
correct without asking Codex to rescue itself.

The helper selects the newest available Codex CLI from PATH and the standard
macOS desktop app bundles, avoiding stale standalone runtimes retained by a
long-running Claude Remote server. Set `CODEX_COMPANION_BINARY` to pin an exact
executable; an invalid explicit override fails without switching runtimes.

## Realtime orchestration

The `codex:sub-agents` skill routes participant and role independently. Codex is
the current main assistant, never a pinned version. Claude/Fable selects
`claude-fable-5-1`; Spark selects `gpt-5.3-codex-spark`. A one-to-one thread has
one participant, selected by its first substantive request, and every unnamed
follow-up remains with that participant. The host has no group chat, so a thread
never returns multiple participant voices. Consulted models may contribute
internally, but the thread owner remains the sole speaker and is never
impersonated.

Gemini and Grok can also be called through `scripts/named-participant.mjs` using
their installed native CLIs and existing authentication. Gemini defaults to
`gemini-3.5-flash`; Grok selects `grok-4.6`. The helper verifies native response
model metadata, returns attributed JSON, and refuses silent model fallback.
These CLIs run locally while model inference is hosted. Plugin installation does
not grant provider access or purchase API usage. Authentication and quota failures
remain explicit; the helper never starts or restarts a login challenge.

The initial cloud role adapter supports individual roles only and rejects
unsupported runtime settings. Gemini CLI has no effort flag, so an effort-bound
role (including the configured Undergrad) is rejected rather than downgraded.
Grok supports low, medium, high, and xhigh through its native effort flag. See
the routing skill for exact trust, permission, and verification limits. Grok's
basic OAuth reply is verified; X Search was unavailable in the live probe and
is not claimed as working. Native tool failures remain visible in `toolErrors`.

All participants share the existing live role registry and instructions. A named
participant overrides the role model only; exact reasoning effort and delegation
constraints still apply. An incompatible participant declines that role rather
than downgrading effort or substituting a model. The read-only role resolver's
selected JSON is the shared `--role-contract` for Spark and the Claude helper.
Private role configuration stays outside this repository. See
[the routing skill](skills/sub-agents/SKILL.md) for dispatch and collaboration.

During GPT Live or another active realtime voice conversation, the parent Codex
thread remains the user's conversational coordinator. Trivial questions stay in
the parent. Collaboration sub-agents are the default for delegated research and
substantial implementation alike. Separate tasks or forks require an explicit
user request; size and concurrency limits do not change that rule. The parent
keeps one owner per workstream, tracks its exact agent identity or thread ID,
and verifies live status before saying work is running. Existing in-flight
tasks retain their owner unless the user requests a migration.

Sub-agents are not separate sidebar tasks. The parent remains the mobile control
surface and relays each owner's
meaningful progress, questions, and results.

The parent keeps a verified priority queue and delivers one topic at a time.
Feedback goes to the same owner and stays on that topic; only the user chooses
when to advance. A completed worker run or delivered answer
does not remove a still-open topic.

## Install

```bash
claude plugin install codex@package-manager
```

```bash
codex plugin add codex@package-manager
```

Then ask Codex to set up Codex Voice, show a fresh pairing QR, or check the
bridge. The skill runs the bundled scripts under
`products/codex-voice/scripts/` and preserves existing paired devices unless
you explicitly ask to revoke them.

## Public source and independent deployments

First-party additions are MIT licensed. Vendored OpenAI code remains Apache-2.0;
see `NOTICE.md` and `LICENSE.upstream`. This project is unofficial. Its integration
icon is original, and product names identify supported services only.

The published Pedro Voice Agent product keeps its existing app, service, relay,
and credential identities. To build an independent fork, configure your own
Apple signing team, bundle identifiers, Expo project, relay deployment, and Sentry
projects before distributing an app. Preserve the documented encryption and
pairing protocol. Do not reuse the original operator's deployment or telemetry
configuration.

GitHub publishes Expo updates only when `CODEX_VOICE_PUBLISH_ENABLED=true` is set
as a repository variable and the operator has configured `EXPO_TOKEN`. Forks have
no publication enabled by default. Native builds and device operations retain
their separate explicit authorization and validation requirements.
