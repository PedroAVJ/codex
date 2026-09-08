import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../src/protocol.ts", import.meta.url), "utf8");
const worker = readFileSync(new URL("../src/index.ts", import.meta.url), "utf8");

test("relay uses the hibernation WebSocket API without timers", () => {
  assert.match(worker, /ctx\.acceptWebSocket\(server\)/);
  assert.match(worker, /webSocketMessage\(/);
  assert.match(worker, /serializeAttachment/);
  assert.doesNotMatch(worker, /setInterval|setTimeout/);
});

test("relay keeps opaque payloads out of operational logs", () => {
  assert.match(worker, /payload_bytes/);
  assert.doesNotMatch(worker, /relayLog\([^\n]+message\.payload/);
  assert.doesNotMatch(worker, /relayLog\([^\n]+room/);
  assert.doesNotMatch(worker, /relayLog\([^\n]+channel/);
});

test("relay preserves frame and rate limits", () => {
  assert.match(source, /MAX_FRAME_BYTES = 1_500_000/);
  assert.match(source, /MAX_MESSAGES_PER_WINDOW = 800/);
  assert.match(source, /MAX_BYTES_PER_WINDOW = 8_000_000/);
  assert.match(source, /DELIVERY_ID_PATTERN/);
});
