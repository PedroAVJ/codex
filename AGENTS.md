# Repository guidance

- This repository is the canonical source for the `codex` plugin.
- The plugin is Claude-only: keep `.claude-plugin/plugin.json` and do not add a
  Codex manifest, because Codex generates images natively.
- `skills/image-generation/` is the only skill. Keep its Codex CLI and Image API
  guidance verified against the installed Codex CLI rather than frozen model
  limits.
- The review commands stay user-invoked only (`disable-model-invocation: true`).
- Marketplace catalogs reference this repository; do not duplicate runtime
  behavior back into a marketplace repository.
- Keep credentials and personal data out of Git. Preserve stable command names,
  service labels, and credential identifiers across releases.
- `products/codex-voice/` is Codex Voice product source, not a plugin surface.
  Keep live bridge keys, paired-device state, API credentials, logs, and the
  `com.pedro.codexvoice.bridge` service stable; do not recreate a standalone
  `codex-voice` plugin.
- Bump the plugin version for released behavior changes and run `npm test` before publishing.
