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
- Only configured employees may become persistent thread owners and inherit
  unnamed follow-ups. Claude/Fable, Near, Spark, and Gemini are app/model
  sources: invoke them only for turns that explicitly ask, address, use, or
  consult them, and return their results with source attribution. Mentioning or
  discussing an app is never an invocation. Grok is the sole app exception: an
  explicitly established Grok/X research lane may retain related unnamed
  follow-ups because it is the X/Twitter API route. The host has no group chat;
  internal consultation never creates another participant.
- Keep realtime queue advancement user-controlled rather than rotating on
  feedback.

## Design workspaces

Keep account-specific design mappings and exports in ignored local configuration.
Resolve the user's chosen design workspace before accessing or changing it.
Do not commit private design conversations, screenshots, or account identifiers.
