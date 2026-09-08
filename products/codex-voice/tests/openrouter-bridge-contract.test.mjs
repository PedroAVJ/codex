import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import test from "node:test";

const root = fileURLToPath(new URL("..", import.meta.url));
const read = (...parts) => readFileSync(join(root, ...parts), "utf8");

test("Mac voice traffic is routed through OpenRouter and never the direct OpenAI API", () => {
  const voice = read("Bridge/Sources/CodexVoiceBridge/OpenRouterVoiceSession.swift");
  const keyStore = read("Bridge/Sources/CodexVoiceBridge/OpenRouterAPIKeyStore.swift");
  const configuration = read("Bridge/Sources/CodexVoiceBridge/BridgeConfiguration.swift");
  const installer = read("scripts/install-bridge.sh");
  const combined = [voice, keyStore, configuration, installer].join("\n");

  assert.match(voice, /openrouter\.ai\/api\/v1\/chat\/completions/);
  assert.match(voice, /"type": "input_audio"/);
  assert.match(voice, /"stream": true/);
  assert.match(voice, /onAudio\?\(encoded\)/);
  assert.match(configuration, /openai\/gpt-audio-mini/);
  assert.match(keyStore, /OPENROUTER_API_KEY/);
  assert.match(installer, /configure-openrouter-key/);
  assert.doesNotMatch(combined, /audio\/transcriptions|transcription-model|api\.openai\.com|OPENAI_API_KEY|gpt-realtime/);
});

test("bridge installation and status enforce the managed Codex daemon", () => {
  const installer = read("scripts/install-bridge.sh");
  const status = read("scripts/bridge-status.sh");
  const relay = read("Bridge/Sources/CodexVoiceBridge/RelayHostClient.swift");
  const server = read("Bridge/Sources/CodexVoiceBridge/BridgeServer.swift");

  assert.match(installer, /app-server daemon start/);
  assert.match(installer, /app-server daemon version/);
  assert.doesNotMatch(installer, /app-server daemon bootstrap/);
  assert.match(installer, /--codex-binary/);
  assert.match(installer, /--no-pair/);
  assert.match(status, /app-server daemon version/);
  assert.match(status, /state = running/);
  assert.match(status, /Relay state fresh/);
  assert.match(relay, /onLiveness/);
  assert.match(server, /relay\.onLiveness/);
});

test("bridge probe exercises reliable audio turns and acknowledges delivery", () => {
  const probe = read("scripts/probe-bridge.mjs");

  assert.match(probe, /reliable-audio-turn-v1/);
  assert.match(probe, /delivery_ack/);
  assert.match(probe, /device\.delivery/);
  assert.match(probe, /turnId/);
  assert.match(probe, /turnSequence/);
  assert.match(probe, /finalAudioSequence/);
  assert.match(probe, /const audioPaths = \[\]/);
  assert.match(probe, /turnsCompleted/);
  assert.match(probe, /transcriptMatched/);
  assert.match(probe, /includesExpectedWords/);
  assert.match(probe, /awaitingFinalReady/);
  assert.match(probe, /relayMessage\.deliveryId !== packet\.deliveryId/);
  assert.match(probe, /deliveryId: packet\.deliveryId/);
  assert.match(probe, /sequence: packet\.sequence/);
});
