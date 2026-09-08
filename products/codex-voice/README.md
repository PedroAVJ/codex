# Codex Voice

Codex Voice is a voice-first Apple Watch client for the Codex agent running on your Mac. The Expo iPhone app is deliberately just a secure pairing companion: scan once, transfer the Mac identity to the paired Watch, and get out of the way. The Watch app and complication remain native Apple targets.

The accepted experience and device-role decisions are recorded in
[`PRODUCT-DIRECTION.md`](PRODUCT-DIRECTION.md). They distinguish settled product
direction from AirPods gesture, wake-phrase, and physical-device hypotheses that
still require validation.

## What works

- One-time QR setup by camera, photo picker, or sharing the QR image directly to the iPhone companion, with automatic transfer to Apple Watch.
- Pinned P-256 Mac identity, per-device identity, ECDH key agreement, and AES-GCM encrypted bridge messages.
- Automatic 24 kHz PCM turns from Apple Watch to the Mac, with on-device end-of-speech detection and no send button, Bonjour, VPN, or Local Network permission prompt.
- Direct OpenRouter audio input and progressively streamed spoken replies from `openai/gpt-audio-mini`, without a separate transcription request or local speech synthesis.
- A `run_codex` OpenRouter tool call that forwards Mac/file/tool work to the authenticated Codex app-server.
- Persistent Codex threads, workspace scoping, streamed status, and Watch approval prompts.
- A login LaunchAgent, Keychain-backed API credential, pairing rotation, health checks, and device revocation.
- An authenticated Cloudflare Durable Object relay using WebSocket Hibernation; idle sockets remain connected without keeping relay compute or memory active, and the relay forwards only opaque end-to-end encrypted frames.
- The bundled `codex` plugin skill that installs and operates the entire Mac side.

The Watch and iPhone never receive the OpenRouter API key or ChatGPT credentials. The iPhone has no chat screen and is not in the audio path after setup.

OpenRouter's documented audio interface is a streaming chat-completion request rather than an OpenAI-style Realtime WebSocket. The Watch still behaves continuously: local voice activity detection opens and closes turns automatically, direct audio goes to OpenRouter, response PCM begins playing as soon as stream deltas arrive, and speaking interrupts playback.

## Architecture

```text
Mac plugin ── one-time QR ──► iPhone companion ── WatchConnectivity ──► Apple Watch
    │                                                                  │
    │      outbound WSS      ┌───────────────────────┐      WSS        │
    └───────────────────────►│ opaque remote relay   │◄────────────────┘
                             └───────────────────────┘
                        pinned ECDH + AES-GCM end to end
    │
    ├── OpenRouter streaming HTTPS
    │      └── audio in + spoken answers + `run_codex` (`openai/gpt-audio-mini`)
    │
    └── extension-free WebSocket over Codex's local Unix control socket
           └── standalone app-server, persistent thread, workspace tools, and approvals
```

This is a custom QR protocol. It does not reuse or impersonate the ChatGPT Remote QR, private relay, GPT Live endpoint, or first-party device credentials.

## Install through the Codex plugin

Codex Voice ships inside the Codex plugin:

```sh
codex plugin add codex@package-manager
```

Then ask Codex: “Set up Codex Voice for this workspace and show the pairing QR.” The `codex:codex-voice` skill will:

1. build the bridge serially;
2. store an existing `OPENROUTER_API_KEY` in the login Keychain;
3. install and start `com.pedro.codexvoice.bridge`, including its outbound encrypted relay connection;
4. generate and open a 10-minute, one-use QR;
5. verify the installed bridge state.

If an API key is not already in the environment, run this directly in Terminal
from the Codex plugin root so the key is entered through a hidden prompt and
never through chat:

```sh
./products/codex-voice/scripts/configure-api-key.sh
./products/codex-voice/scripts/install-bridge.sh --cwd /absolute/path/to/workspace
```

OpenRouter bills the audio-model requests against the OpenRouter account. ChatGPT and Codex subscriptions do not provide OpenRouter credit.

On the iPhone, share the QR image to **Codex Voice**, choose it from **Choose QR Image**, or use **Scan Mac QR**. Sharing an image launches the companion directly and Vision decodes the QR locally. The phone stores its identity in the device Keychain, sends the same device-only credentials to its paired Watch, and waits for the Watch to acknowledge them before showing **Ready on Apple Watch**. If the Watch was installed or updated later, tap **Send to Apple Watch**; you do not need another QR. The Watch can then reach the Mac remotely over Wi-Fi or cellular; neither app asks for local-network access.

## Operations

```sh
./products/codex-voice/scripts/bridge-status.sh
./products/codex-voice/scripts/check-openrouter.sh
./products/codex-voice/scripts/show-pairing-qr.sh
./products/codex-voice/scripts/revoke-devices.sh
./products/codex-voice/scripts/uninstall-bridge.sh
```

`check-openrouter.sh` reports sanitized key usage and its remaining spending limit. It also reports the account-wide purchased-credit balance when the stored credential is a management key; otherwise use the signed-in OpenRouter dashboard for that account-level figure. `show-pairing-qr.sh` replaces only the pending one-time ticket. It does not disconnect paired devices. Revocation is explicit. Uninstalling stops the bridge but preserves keys, device state, and logs for recovery.

The bridge log records the Watch microphone path without recording audio or
credentials. `Watch audio` entries distinguish audio-session category and
activation, the exact capture startup stage, sanitized native error domain and
code, shared-duplex-engine state, first-buffer timeout or success, level
snapshots, speech start/end, conversion failures, relayed chunks, output-engine
startup and playback, and accepted or rejected commits. This makes a silent
Watch session diagnosable as session activation, input format, conversion, tap
installation, engine startup, buffer delivery, turn detection, transport,
provider response, or playback instead of collapsing into a generic failure.
Watch audio turns are buffered in volatile memory with strict duration, size,
and envelope bounds. A reconnect re-encrypts and replays the whole active turn;
the Mac bridge deduplicates turn sequences and accepts the commit only after all
audio is present, so a relay outage cannot silently create a partial request or
start the provider twice. The Watch also retries the observed pre-buffer
`engine_start` failure twice with fresh audio-session and graph setup while
leaving any in-flight provider response untouched.
Privacy-filtered Sentry logs, errors, and traces mirror those stages across the
iPhone companion, Watch app, complication, Mac bridge, and relay. They exclude
audio, transcripts, pairing material, credentials, request bodies, headers,
query strings, screenshots, view hierarchies, and default user PII.

## Build and test

```sh
npm ci
npm run export:ios
(cd ios && pod install)
swift test --disable-keychain --jobs 1
npm run eas:validate
```

Use `npm run ios` for normal Expo iPhone development. The committed `ios/`
project is required because it embeds the native Watch app and complication; do
not regenerate it casually after CocoaPods integration. CI publishes EAS
Updates with `npm run eas:update` and never starts a native build. After that
deployment, `npm run eas:plan` checks whether its fingerprint needs a new
binary. When it does, `npm run eas:build:local` creates the signed archive on
the operator's Mac, then uses Expo for managed credentials, TestFlight
submission, and artifact registration. See [`EXPO.md`](EXPO.md).

To smoke-test the deployed relay with the Mac's existing public identity:

```sh
CODEX_VOICE_RELAY_URL=wss://codex-voice-relay.codex-voice-hibernating-relay.workers.dev/api/relay \
CODEX_VOICE_SERVER_KEY_PATH="$HOME/Library/Application Support/CodexVoice/server-key.bin" \
node relay/scripts/smoke-relay.mjs
```

After deploying the Vercel compatibility route, verify an old device endpoint
without reconnecting the always-on host through Vercel:

```bash
CODEX_VOICE_RELAY_URL=wss://codex-voice-relay.codex-voice-hibernating-relay.workers.dev/api/relay \
CODEX_VOICE_DEVICE_RELAY_URL=wss://codex-voice-relay.vercel.app/api/relay \
node relay/scripts/smoke-relay.mjs
```

The smoke test verifies authenticated, bidirectional opaque forwarding. Normal setup exposes the one-time ticket only as a mode-0600 QR image.

The legacy Vercel endpoint remains only as an on-demand compatibility proxy for
already-paired devices. The always-on Mac host connects directly to the hibernating
relay, so an idle bridge cannot pin Vercel Function memory. New pairings use the
Cloudflare endpoint directly.

## Security boundary

- The Mac and Apple devices make outbound TLS connections; the bridge exposes no inbound port.
- The QR carries a short-lived one-time ticket, the Mac's public key, relay address, relay encryption key, and a signed short-lived relay authorization. It never carries an API key or Codex credential.
- Relay frames are additionally sealed with AES-GCM. Cloudflare sees routing metadata and opaque ciphertext, not plaintext voice or Codex messages. The legacy Vercel compatibility proxy sees the same opaque material only while an older device has an active session.
- The Mac private key, device registry, and OpenRouter API key stay in mode-0600 local storage or Keychain.
- Codex runs in the selected workspace with workspace-write sandboxing and on-request approvals.
- OpenRouter receives each automatically detected utterance and the short voice conversation context; Codex receives only requests that the voice model routes through `run_codex`.
- The bridge keeps a bounded local voice history and sends each utterance as a separate OpenRouter request; Codex threads remain visible in Codex history.

## Design assets

The public release identity is **Pedro Voice Agent**. Its app icon and Watch pulse are original project assets: two endpoints joined by a compact voice waveform in the product's existing cobalt, cyan, violet, and navy palette. The source master is tracked at `assets/pedro-voice-agent.png`; `ICON-SOURCES.md` records its generation prompt and derived sizes.

The companion retains the established paper, ink, spacing, typography, status-card, and connection-route system. The Watch retains the headerless circular focal point, native progress UI, mute/end hierarchy, and icon-only 44-point recovery action. No OpenAI, ChatGPT, or Codex logo, terminal-flower, voice-orb frame, or other third-party artwork ships in the public UI. The complication uses the native `waveform` SF Symbol so it remains legible in tinted and vibrant rendering without carrying third-party brand artwork.

Internal target, bundle, URL-scheme, telemetry, bridge, and protocol identifiers keep their existing Codex Voice names for update compatibility. They are implementation details, not public product branding.

## References

- [Codex app-server](https://learn.chatgpt.com/docs/app-server)
- [OpenRouter audio input and output](https://openrouter.ai/docs/guides/overview/multimodal/audio)
- [OpenRouter tool calling](https://openrouter.ai/docs/guides/features/tool-calling)
