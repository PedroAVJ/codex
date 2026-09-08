#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import WebSocket from "ws";

const argumentsAfterScript = process.argv.slice(2);
const linkPath = argumentsAfterScript.shift();
let handshakeOnly = false;
const audioPaths = [];
const expectedTranscripts = [];
let outputPCMPath;
let outputDirectory;
let clientIDOutputPath;

while (argumentsAfterScript.length > 0) {
  const argument = argumentsAfterScript.shift();
  if (argument === "--handshake-only") {
    handshakeOnly = true;
  } else if (argument === "--output-pcm") {
    outputPCMPath = argumentsAfterScript.shift();
    if (!outputPCMPath) usage();
  } else if (argument === "--output-dir") {
    outputDirectory = argumentsAfterScript.shift();
    if (!outputDirectory) usage();
  } else if (argument === "--expect") {
    const expectation = argumentsAfterScript.shift();
    if (!expectation) usage();
    expectedTranscripts.push(expectation);
  } else if (argument === "--expect-any") {
    expectedTranscripts.push(null);
  } else if (argument === "--client-id-output") {
    clientIDOutputPath = argumentsAfterScript.shift();
    if (!clientIDOutputPath) usage();
  } else if (!argument.startsWith("--")) {
    audioPaths.push(argument);
  } else {
    usage();
  }
}

if (!linkPath) {
  usage();
}
if (outputPCMPath && (audioPaths.length !== 1 || handshakeOnly)) {
  usage();
}
if (outputPCMPath && outputDirectory) {
  usage();
}
if (outputDirectory && (audioPaths.length === 0 || handshakeOnly)) {
  usage();
}
if (expectedTranscripts.length > 0 && expectedTranscripts.length !== audioPaths.length) {
  usage();
}
for (const audioPath of audioPaths) {
  if (!fs.existsSync(audioPath) || fs.statSync(audioPath).size === 0) {
    console.error(`Audio input is missing or empty: ${audioPath}`);
    process.exit(2);
  }
}
if (outputDirectory) fs.mkdirSync(outputDirectory, { recursive: true, mode: 0o700 });

const link = new URL(fs.readFileSync(linkPath, "utf8").trim());
const ticket = link.searchParams.get("ticket");
const serverEncoded = link.searchParams.get("server") ?? "";
const serverPublicKey = fromBase64URL(serverEncoded);
const relayEndpoint = link.searchParams.get("relay");
const relayRoom = link.searchParams.get("room");
const relayKey = fromBase64URL(link.searchParams.get("key") ?? "");
const relayAuth = link.searchParams.get("auth");
if (
  link.protocol !== "codexvoice:" ||
  link.hostname !== "pair" ||
  link.searchParams.get("v") !== "2" ||
  !ticket ||
  serverPublicKey.length !== 64 ||
  !relayEndpoint ||
  !relayRoom ||
  relayKey.length !== 32 ||
  !relayAuth
) {
  console.error("The pairing link file is invalid");
  process.exit(2);
}

const ecdh = crypto.createECDH("prime256v1");
ecdh.generateKeys();
const clientNonce = crypto.randomBytes(32);
const sharedSecret = ecdh.computeSecret(Buffer.concat([Buffer.from([4]), serverPublicKey]));
const acknowledgementKey = deriveKey(sharedSecret, clientNonce, "codex-voice-ack-v1");
const channel = crypto.randomUUID().toLowerCase();
let sessionKey;
let pairedClientID;
let nextOutboundSequence = 0;
let turnIndex = 0;
let turnInFlight = false;
let awaitingFinalReady = false;
let outputAudioChunks = [];
let assistantTranscript = "";
const turnsCompleted = [];
let finished = false;

const relayURL = new URL(relayEndpoint);
relayURL.searchParams.set("room", relayRoom);
relayURL.searchParams.set("role", "device");
relayURL.searchParams.set("channel", channel);
relayURL.searchParams.set("server", serverEncoded);
const socket = new WebSocket(relayURL, {
  headers: { Authorization: `Bearer ${relayAuth}` },
});
const timeout = setTimeout(() => fail("Timed out waiting for the remote bridge"), 300_000);

socket.on("message", (data) => {
  const relayMessage = JSON.parse(data.toString("utf8"));
  if (relayMessage.kind === "ready") {
    sendPacket({
      kind: "hello",
      version: 2,
      clientPublicKey: toBase64URL(ecdh.getPublicKey(undefined, "uncompressed").subarray(1)),
      clientNonce: toBase64URL(clientNonce),
      ticket,
    });
    return;
  }
  if (relayMessage.kind === "error") return fail(relayMessage.message ?? "Relay rejected the probe");
  if (relayMessage.kind !== "frame" || relayMessage.channel !== channel) return;
  const packet = decryptJSON(relayMessage.payload, relayKey);
  if (relayMessage.deliveryId !== packet.deliveryId || relayMessage.sequence !== packet.sequence) {
    return fail("Relay delivery metadata did not match the encrypted bridge packet");
  }
  handlePacket(packet);
});

socket.on("error", (error) => fail(error.message));
socket.on("close", () => {
  if (!finished) fail("Remote bridge closed before the probe completed");
});

function handlePacket(packet) {
  if (packet.kind === "error") return fail(packet.message ?? "Bridge rejected the probe");
  if (packet.kind === "helloAck") {
    const acknowledgement = decryptJSON(packet.data, acknowledgementKey);
    pairedClientID = acknowledgement.clientID;
    const serverNonce = fromBase64URL(acknowledgement.serverNonce);
    sessionKey = deriveKey(
      sharedSecret,
      Buffer.concat([clientNonce, serverNonce]),
      "codex-voice-session-v1",
    );
    if (handshakeOnly) {
      console.log("Remote QR ticket and pinned Mac handshake verified without consuming the ticket.");
      return succeed();
    }
    sendEnvelope({
      kind: "pair",
      clientId: acknowledgement.clientID,
      deviceName: "Bridge integration probe",
      capabilities: ["reliable-audio-turn-v1"],
    });
    return;
  }
  if (packet.kind !== "sealed" || !sessionKey) return fail("Unexpected bridge packet");

  const envelope = decryptJSON(packet.data, sessionKey);
  if (isDeliveryAcknowledgement(envelope, "bridge.delivery")) return;
  acknowledgeDelivery(envelope);
  if (envelope.kind === "audioOutput") {
    outputAudioChunks.push(Buffer.from(envelope.data ?? "", "base64"));
  } else if (envelope.kind === "transcriptDelta") {
    assistantTranscript += envelope.text ?? "";
  } else if (envelope.kind === "transcriptDone") {
    assistantTranscript = envelope.text ?? assistantTranscript;
  }
  if (envelope.kind === "paired") {
    if (clientIDOutputPath) {
      fs.writeFileSync(clientIDOutputPath, pairedClientID, { mode: 0o600 });
    }
    sendEnvelope({ kind: "start" });
  } else if (envelope.kind === "ready" && !turnInFlight) {
    if (audioPaths.length === 0) {
      console.log(JSON.stringify({ status: "ready", clientId: pairedClientID }));
      return succeed();
    }
    if (awaitingFinalReady && turnIndex === audioPaths.length) {
      console.log(JSON.stringify({
        clientId: pairedClientID,
        turnCount: turnsCompleted.length,
        turns: turnsCompleted,
      }));
      return succeed();
    }
    if (turnIndex < audioPaths.length) sendAudio(turnIndex);
  } else if (envelope.kind === "audioOutputDone" && turnInFlight) {
    const outputAudio = Buffer.concat(outputAudioChunks);
    if (outputAudio.length === 0) return fail("OpenRouter returned no audio bytes");
    const expectedTranscript = expectedTranscripts[turnIndex];
    const transcriptMatched = expectedTranscript
      ? includesExpectedWords(assistantTranscript, expectedTranscript)
      : null;
    if (transcriptMatched === false) {
      return fail(`Turn ${turnIndex + 1} transcript did not contain the expected synthetic phrase`);
    }
    if (outputPCMPath) fs.writeFileSync(outputPCMPath, outputAudio, { mode: 0o600 });
    if (outputDirectory) {
      const outputPath = `${outputDirectory}/turn-${String(turnIndex + 1).padStart(2, "0")}.pcm`;
      fs.writeFileSync(outputPath, outputAudio, { mode: 0o600 });
    }
    turnsCompleted.push({
      turn: turnIndex + 1,
      inputBytes: fs.statSync(audioPaths[turnIndex]).size,
      outputBytes: outputAudio.length,
      outputSaved: Boolean(outputPCMPath || outputDirectory),
      transcriptAvailable: assistantTranscript.length > 0,
      transcriptMatched,
    });
    turnIndex += 1;
    turnInFlight = false;
    outputAudioChunks = [];
    assistantTranscript = "";
    awaitingFinalReady = turnIndex === audioPaths.length;
  } else if (envelope.kind === "error") {
    fail(envelope.message ?? "Bridge returned an error");
  }
}

function sendAudio(index) {
  turnInFlight = true;
  awaitingFinalReady = false;
  const audio = fs.readFileSync(audioPaths[index]);
  const turnId = crypto.randomUUID().toLowerCase();
  let turnSequence = 1;
  for (let offset = 0; offset < audio.length; offset += 8_192) {
    const chunk = audio.subarray(offset, Math.min(offset + 8_192, audio.length));
    sendEnvelope({
      kind: "audioInput",
      data: chunk.toString("base64"),
      sampleRate: 24_000,
      numChannels: 1,
      samplesPerChannel: Math.floor(chunk.length / 2),
      turnId,
      turnSequence,
    });
    turnSequence += 1;
  }
  sendEnvelope({
    kind: "commitAudio",
    turnId,
    turnSequence,
    finalAudioSequence: turnSequence - 1,
  });
}

function normalizeTranscript(value) {
  return value
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

function includesExpectedWords(transcript, expectation) {
  const transcriptWords = normalizeTranscript(transcript).split(" ").filter(Boolean);
  const expectedWords = normalizeTranscript(expectation).split(" ").filter(Boolean);
  let transcriptIndex = 0;
  for (const expectedWord of expectedWords) {
    const matchIndex = transcriptWords.indexOf(expectedWord, transcriptIndex);
    if (matchIndex === -1) return false;
    transcriptIndex = matchIndex + 1;
  }
  return expectedWords.length > 0;
}

function sendEnvelope(envelope) {
  const outbound = { ...envelope };
  const acknowledgement = isDeliveryAcknowledgement(outbound, "device.delivery");
  if (!acknowledgement) {
    nextOutboundSequence += 1;
    outbound.deliveryId = crypto.randomUUID().toLowerCase();
    outbound.sequence = nextOutboundSequence;
    outbound.deliveryKind = outbound.kind;
  }
  sendPacket({
    kind: "sealed",
    version: 2,
    data: encryptJSON(outbound, sessionKey),
    deliveryId: outbound.deliveryId,
    sequence: outbound.sequence,
  });
}

function acknowledgeDelivery(envelope) {
  if (!envelope.deliveryId || !Number.isInteger(envelope.sequence)) return;
  sendEnvelope({
    kind: "status",
    code: "delivery_ack",
    role: "device.delivery",
    deliveryId: envelope.deliveryId,
    sequence: envelope.sequence,
    deliveryKind: envelope.kind,
    deliveryOutcome: "probe_received",
  });
}

function isDeliveryAcknowledgement(envelope, role) {
  return envelope.kind === "status"
    && envelope.code === "delivery_ack"
    && envelope.role === role
    && envelope.deliveryId
    && Number.isInteger(envelope.sequence);
}

function sendPacket(packet) {
  socket.send(JSON.stringify({
    kind: "frame",
    channel,
    payload: encryptJSON(packet, relayKey),
    ...(packet.deliveryId ? { deliveryId: packet.deliveryId } : {}),
    ...(Number.isInteger(packet.sequence) ? { sequence: packet.sequence } : {}),
  }));
}

function deriveKey(secret, salt, context) {
  return Buffer.from(crypto.hkdfSync("sha256", secret, salt, Buffer.from(context), 32));
}

function encryptJSON(value, key) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, nonce);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(value), "utf8"), cipher.final()]);
  return toBase64URL(Buffer.concat([nonce, ciphertext, cipher.getAuthTag()]));
}

function decryptJSON(value, key) {
  const combined = fromBase64URL(value);
  const nonce = combined.subarray(0, 12);
  const ciphertext = combined.subarray(12, -16);
  const tag = combined.subarray(-16);
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAuthTag(tag);
  return JSON.parse(Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8"));
}

function toBase64URL(value) {
  return Buffer.from(value).toString("base64url");
}

function fromBase64URL(value) {
  return Buffer.from(value, "base64url");
}

function usage() {
  console.error(
    "Usage: probe-bridge.mjs PAIRING_LINK_FILE [--handshake-only] [PCM16_24KHZ_MONO_FILE ...] [--expect TEXT | --expect-any ...] [--output-pcm OUTPUT_FILE | --output-dir DIRECTORY] [--client-id-output FILE]",
  );
  process.exit(2);
}

function succeed() {
  if (finished) return;
  finished = true;
  clearTimeout(timeout);
  socket.close(1000);
}

function fail(message) {
  if (finished) return;
  finished = true;
  clearTimeout(timeout);
  console.error(message);
  socket.close();
  process.exitCode = 1;
}
