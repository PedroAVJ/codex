# Notices

## Vendored: `openai/codex-plugin-cc`

The review surface of this plugin — `commands/`, `prompts/`, `schemas/`,
and `scripts/` — is vendored from
[`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc) v1.0.4.

Copyright 2026 OpenAI. Licensed under the Apache License, Version 2.0. The
upstream license text is kept alongside this file as
[`LICENSE.upstream`](./LICENSE.upstream), and the upstream changelog as
[`CHANGELOG.upstream.md`](./CHANGELOG.upstream.md).

### Modifications

- Vendored into this repository so everything Claude Code does specifically
  with the Codex coding agent remains under one `codex:` namespace.
- Added `scripts/lib/host-guard.mjs` and a call to it in
  `scripts/codex-companion.mjs`, so the companion refuses to run when
  `$CLAUDECODE` is unset. Upstream ships only to Claude Code and had no reason
  to guard this; the guard keeps a review call from asking Codex to review
  itself.
- Removed the upstream `setup` command and the `codex-result-handling` and
  `gpt-5-5-prompting` skills.

Desktop-host `automations`, `internals`, and `patching` are original to this
repository and now live in `chatgpt@package-manager`. ChatGPT and Codex share one macOS
bundle, but the bundle-level workflows are separate from this vendored Codex
coding-agent surface.
