---
name: codex-voice
description: Set up, pair, diagnose, repair, or revoke the Codex Voice iPhone and Apple Watch companion, its remote encrypted relay, OpenRouter voice path, and Mac bridge. Use when the user mentions Codex Voice, the Watch voice app, its pairing QR, voice bridge, remote connection, OpenRouter credits, or the com.pedro.codexvoice.bridge LaunchAgent.
---

# Codex Voice

Operate the bundled Mac bridge for the minimal iPhone pairing companion and voice-first Apple Watch app.

## Boundaries

- The Mac makes an outbound `wss://` connection to the Codex Voice relay. The relay forwards only opaque AES-GCM ciphertext and must never receive the OpenRouter key, Codex credentials, or plaintext audio.
- The bridge exposes no inbound listener. The iPhone and Watch do not require Bonjour or Local Network access.
- The QR belongs only to Codex Voice. It does not reuse ChatGPT Remote pairing, credentials, or relay infrastructure.
- Never ask the user to paste an OpenRouter API key into chat, log it, print it, or put it in a LaunchAgent plist. The bundled command stores it in the login Keychain.
- OpenRouter audio input and output are API-billed. A ChatGPT or Codex subscription does not supply OpenRouter credit.
- Preserve the bridge server key and paired-device state unless the user explicitly asks to revoke devices or remove all data.

## Locate commands

Resolve the Codex plugin root as the directory two levels above this
`SKILL.md`. The Codex Voice product root is
`<plugin-root>/products/codex-voice`; run scripts from
`<plugin-root>/products/codex-voice/scripts` using their absolute paths.
Preserve the user's current working directory before changing directories.

## Setup or repair

1. Check `<plugin-root>/products/codex-voice/scripts/bridge-status.sh` when an installation may already exist.
2. If the API key is not configured, use `OPENROUTER_API_KEY` only when it is already available in the process environment. Otherwise, tell the user to run `<plugin-root>/products/codex-voice/scripts/configure-api-key.sh` directly in Terminal; it uses a hidden prompt. Do not request the secret in chat.
3. Run `<plugin-root>/products/codex-voice/scripts/install-bridge.sh --cwd <absolute-user-workspace>`. Use the user's current workspace unless they named another folder. For a repair with an already paired device, add `--no-pair` so the existing pairing remains the only active handoff.
4. The installer ensures the managed Codex app-server daemon is running, builds serially, installs a persistent LaunchAgent, and, unless `--no-pair` was used, opens a 10-minute one-time pairing QR. Report a newly created QR path and tell the user they can share the PNG directly to Pedro Voice Agent, choose it inside the iPhone companion, or scan it with the camera.
5. Run `<plugin-root>/products/codex-voice/scripts/bridge-status.sh` and require `serverKeyReady`, `openRouterAPIKeyConfigured`, `voiceProvider: openrouter`, `relayConfigured`, `relayConnected`, `Codex app-server daemon running: true`, `LaunchAgent running: true`, and `Relay state fresh: true` before calling setup complete.

## Pair another device

Run `<plugin-root>/products/codex-voice/scripts/show-pairing-qr.sh`. This replaces any unconsumed ticket, opens a fresh shareable PNG, and does not revoke already paired devices. The iPhone companion can receive that image directly from the iOS share sheet.

## Sync an already paired Watch

When the iPhone companion says the Mac is paired but the Watch is pending, do not generate another QR or revoke the device. Open Codex Voice on the Watch, then tap **Send to Apple Watch** in the iPhone companion. Require **Ready on Apple Watch**, which is shown only after the Watch acknowledges the transferred secure Mac identity.

## Diagnose

Run `<plugin-root>/products/codex-voice/scripts/bridge-status.sh`, then inspect only these logs as needed:

- `~/Library/Application Support/CodexVoice/Logs/bridge.log`
- `~/Library/Application Support/CodexVoice/Logs/bridge-error.log`

Do not display secrets or full unrelated logs. An OpenRouter credit, key-limit, or payment-required error is a provider billing block, not a pairing or remote-relay failure. The `/api/v1/key` endpoint can report a key's own usage and remaining limit; account-wide purchased credits require an OpenRouter management key or the signed-in dashboard.

Run `<plugin-root>/products/codex-voice/scripts/check-openrouter.sh` to print only sanitized OpenRouter metadata. Never print or log the key itself.

For Watch audio, require a complete sanitized event chain rather than treating a
paired bridge as proof: `audio_session_activated`, `capture_attempt`,
`capture_started`, `first_buffer`, `speech_started`, bridge `first_chunk`,
`commit_accepted`, `output_first_buffer`, and `output_finished`. A
`capture_failed` record must include its exact stage plus native error domain and
code; a running engine without `first_buffer` must emit `first_buffer_timeout`.
Never log PCM, credentials, request contents, or full unrelated logs.

Before releasing a Watch audio change, run the synthetic PCM-to-wire-to-WAV Swift
integration test and, when a compatible runtime is available, a DEBUG Watch
simulator microphone probe. Require `first_buffer` when that runtime exposes a
nonzero input format. If the probe instead reports zero input sample rate or
channels, preserve the exact sanitized diagnostic and report that simulator
limitation. Also exercise the encrypted device protocol through the relay, Mac
bridge, Codex thread, provider request, streamed audio response, and device-side
receipt. A physical Watch turn is separate device evidence and is not a release
prerequisite unless the user explicitly requests that test. Before releasing a complication change, install the
candidate Watch build, place Codex in Solar Dial Digital's Bottom Left slot,
inspect both the actual face and iPhone Watch-app preview, cold-restart once, and
verify the tap launches Codex. Generic WidgetKit previews, source-string
assertions, an uploaded binary, and bridge health are not substitutes for those
complication-specific gates.

## Revoke

Only after explicit authorization, run `<plugin-root>/products/codex-voice/scripts/revoke-devices.sh`. The user must then generate and scan a fresh QR. Use `<plugin-root>/products/codex-voice/scripts/uninstall-bridge.sh` only when they ask to stop or uninstall the bridge; it deliberately preserves keys, device state, and logs for recovery.
