# Repository guidance

- This repository is the canonical source for the `codex` plugin.
- Keep the Codex and Claude manifests synchronized when both are present. The Claude plugin is intentionally absent for Codex-only plugins.
- Marketplace catalogs reference this repository; do not duplicate runtime behavior back into a marketplace repository.
- Keep credentials and personal data out of Git. Preserve stable command names, service labels, and credential identifiers across releases.
- `products/codex-voice/` contains the Codex Voice product
  source. Its Mac bridge, relay, iPhone companion, and voice-first Apple Watch
  app are part of Codex; do not recreate a standalone `codex-voice` plugin.
- Export the Codex Voice operating skill only from `skills/codex-voice/`. Keep
  live bridge keys, paired-device state, API credentials, logs, and the
  `com.pedro.codexvoice.bridge` service stable across plugin upgrades.
- Bump the plugin version for released behavior changes and run `npm test` before publishing.
- Keep named participants thread-scoped. A one-to-one thread has one participant
  selected by its first substantive request; every later turn remains with that
  participant. The host has no group chat, so do not simulate multiple speakers
  in one thread. Internal model consultation does not change thread ownership.
- Keep unsolicited plugin stewardship opt-in by evidence: only direct, explicit,
  reusable corrections to agent-loaded plugin behavior may create a sanitized
  stewardship sub-agent without copied history. Separate tasks or forks require
  an explicit user request. Never fork or copy the originating conversation for that
  unsolicited handoff, and never block it while stewardship runs. Explicitly
  requested plugin implementation follows normal work routing instead, including
  sub-agents for substantial work; do not force it through stewardship. Keep
  realtime queue advancement user-controlled rather than rotating on feedback.

## Design workspaces

Keep account-specific design mappings and exports in ignored local configuration.
Resolve the user's chosen design workspace before accessing or changing it.
Do not commit private design conversations, screenshots, or account identifiers.
