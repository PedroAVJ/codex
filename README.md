# Codex

A Claude Code plugin for OpenAI image generation, plus the Codex code-review
commands.

## Claude Code surface

- `codex:image-generation` is the plugin's only skill. It tells Claude how to
  generate and edit images with OpenAI image generation: the ChatGPT-authenticated
  Codex CLI (`codex exec` with its built-in image tool) by default, and the
  OpenAI Image API through the Codex-bundled `image_gen.py` CLI as an explicit
  fallback. It also covers settings, prompt structure, inspection, and delivery.
- `/codex:review`, `/codex:adversarial-review`, `/codex:status`,
  `/codex:result`, and `/codex:cancel` run Codex reviews of local Git state and
  manage those jobs. They are user-invoked only. The `commands/`, `prompts/`,
  `schemas/`, and `scripts/` payload is based on OpenAI's `codex-plugin-cc`; the
  companion host guard refuses to run inside Codex.

The helper selects the newest available Codex CLI from PATH and the standard
macOS desktop app bundles. Set `CODEX_COMPANION_BINARY` to pin an exact
executable; an invalid explicit override fails without switching runtimes.

## Claude only

The plugin is listed only in Package Manager's Claude catalog. Codex generates
images natively, so it has no Codex manifest.

```bash
claude plugin install codex@package-manager
```

## Codex Voice product source

`products/codex-voice/` keeps the source of the published Codex Voice (Pedro
Voice Agent) product: the Mac bridge, relay, iPhone companion, and Apple Watch
app, with its CI workflow. The plugin no longer exposes a skill for it. Bridge
keys, pairing state, API credentials, logs, and the
`com.pedro.codexvoice.bridge` service identity live outside the plugin cache.

The published product keeps its existing app, service, relay, and credential
identities. To build an independent fork, configure your own Apple signing
team, bundle identifiers, Expo project, relay deployment, and Sentry projects
before distributing an app. Preserve the documented encryption and pairing
protocol. Do not reuse the original operator's deployment or telemetry
configuration.

GitHub publishes Expo updates only when `CODEX_VOICE_PUBLISH_ENABLED=true` is set
as a repository variable and the operator has configured `EXPO_TOKEN`. Forks have
no publication enabled by default.

## License

First-party additions are MIT licensed. Vendored OpenAI code remains Apache-2.0;
see `NOTICE.md` and `LICENSE.upstream`. This project is unofficial. Its
integration icon is original, and product names identify supported services only.
