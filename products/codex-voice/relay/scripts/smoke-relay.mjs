import { createECDH, createPrivateKey, createHash, randomBytes, randomUUID, sign } from "node:crypto";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import process from "node:process";
import WebSocket from "ws";

const suppliedEndpoint = process.env.CODEX_VOICE_RELAY_URL;
const legacyEndpoint = "wss://codex-voice-relay.vercel.app/api/relay";
const hibernatingEndpoint = "wss://codex-voice-relay.codex-voice-hibernating-relay.workers.dev/api/relay";
const endpoint = suppliedEndpoint === legacyEndpoint ? hibernatingEndpoint : suppliedEndpoint;
const deviceEndpoint = process.env.CODEX_VOICE_DEVICE_RELAY_URL ?? suppliedEndpoint;
const idleMilliseconds = Number.parseInt(
  process.env.CODEX_VOICE_RELAY_IDLE_MS ?? "0",
  10,
);
const keyPath = process.env.CODEX_VOICE_SERVER_KEY_PATH
  ?? join(homedir(), "Library", "Application Support", "CodexVoice", "server-key.bin");
if (!endpoint) throw new Error("CODEX_VOICE_RELAY_URL is required");
if (!Number.isSafeInteger(idleMilliseconds) || idleMilliseconds < 0 || idleMilliseconds > 60_000) {
  throw new Error("CODEX_VOICE_RELAY_IDLE_MS must be between 0 and 60000");
}

const base64url = (value) => Buffer.from(value).toString("base64url");
const privateRaw = await readFile(keyPath);
if (privateRaw.length !== 32) throw new Error("Unexpected P-256 private-key length");
const ecdh = createECDH("prime256v1");
ecdh.setPrivateKey(privateRaw);
const publicRaw = ecdh.getPublicKey(undefined, "uncompressed").subarray(1);
const server = base64url(publicRaw);
const privateKey = createPrivateKey({
  format: "jwk",
  key: {
    kty: "EC",
    crv: "P-256",
    x: base64url(publicRaw.subarray(0, 32)),
    y: base64url(publicRaw.subarray(32, 64)),
    d: base64url(privateRaw),
  },
});

const relayKey = randomBytes(32);
const room = base64url(createHash("sha256").update(relayKey).digest());
const channel = randomUUID().toLowerCase();
const expiresAt = Math.floor(Date.now() / 1000) + 300;

function token(role) {
  const payload = base64url(
    JSON.stringify({ clientID: null, expiresAt, role, room, version: 1 }),
  );
  return `${payload}.${base64url(sign("sha256", Buffer.from(payload), privateKey))}`;
}

function url(role, connectionChannel, targetEndpoint = endpoint) {
  const value = new URL(targetEndpoint);
  value.searchParams.set("room", room);
  value.searchParams.set("role", role);
  value.searchParams.set("channel", connectionChannel);
  value.searchParams.set("server", server);
  return value;
}

function open(role, connectionChannel) {
  return new Promise((resolve, reject) => {
    const targetEndpoint = role === "device" ? deviceEndpoint : endpoint;
    const socket = new WebSocket(url(role, connectionChannel, targetEndpoint), {
      headers: { Authorization: `Bearer ${token(role)}` },
    });
    const timer = setTimeout(() => reject(new Error(`${role} relay connection timed out`)), 15_000);
    socket.once("error", reject);
    socket.on("message", (data) => {
      const message = JSON.parse(data.toString());
      if (message.kind === "ready") {
        clearTimeout(timer);
        resolve(socket);
      }
    });
  });
}

function verifyUnauthorizedIsRejected() {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url("device", channel, deviceEndpoint));
    const timer = setTimeout(() => reject(new Error("Unauthorized relay probe timed out")), 15_000);
    socket.once("open", () => reject(new Error("Relay accepted an unauthenticated socket")));
    socket.once("unexpected-response", (_request, response) => {
      clearTimeout(timer);
      socket.on("error", () => {});
      response.resume();
      socket.terminate();
      if (response.statusCode === 401) resolve();
      else reject(new Error(`Unexpected unauthenticated status ${response.statusCode}`));
    });
    socket.once("error", (error) => {
      clearTimeout(timer);
      if (!String(error.message).includes("401")) reject(error);
    });
  });
}

function verifyCompatibilityHostIsRejected() {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url("host", "host", deviceEndpoint), {
      headers: { Authorization: `Bearer ${token("host")}` },
    });
    const timer = setTimeout(() => reject(new Error("Compatibility host probe timed out")), 15_000);
    socket.once("open", () => reject(new Error("Compatibility endpoint accepted an always-on host")));
    socket.once("unexpected-response", (_request, response) => {
      clearTimeout(timer);
      socket.on("error", () => {});
      response.resume();
      socket.terminate();
      if (response.statusCode === 410) resolve();
      else reject(new Error(`Unexpected compatibility host status ${response.statusCode}`));
    });
    socket.once("error", (error) => {
      clearTimeout(timer);
      if (!String(error.message).includes("410")) reject(error);
    });
  });
}

function waitFor(socket, expectedPayload) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Relay did not forward ${expectedPayload}`)), 15_000);
    const listener = (data) => {
      const message = JSON.parse(data.toString());
      if (message.kind === "frame" && message.payload === expectedPayload) {
        clearTimeout(timer);
        socket.off("message", listener);
        resolve(message);
      }
    };
    socket.on("message", listener);
  });
}

await verifyUnauthorizedIsRejected();
if (deviceEndpoint !== endpoint) await verifyCompatibilityHostIsRejected();
const [host, device] = await Promise.all([open("host", "host"), open("device", channel)]);
if (idleMilliseconds > 0) {
  await new Promise((resolve) => setTimeout(resolve, idleMilliseconds));
}
const hostReceived = waitFor(host, "opaque-device-to-host");
device.send(JSON.stringify({ kind: "frame", channel, payload: "opaque-device-to-host" }));
await hostReceived;
const deviceReceived = waitFor(device, "opaque-host-to-device");
host.send(JSON.stringify({ kind: "frame", channel, payload: "opaque-host-to-device" }));
await deviceReceived;

host.terminate();
device.terminate();
console.log(
  deviceEndpoint === endpoint
    ? `Production relay rejected anonymous access and forwarded authenticated opaque frames both ways after ${idleMilliseconds}ms idle.`
    : `Compatibility relay rejected anonymous and always-on host access, then forwarded authenticated device frames through the hibernating host relay after ${idleMilliseconds}ms idle.`,
);
process.exit(0);
