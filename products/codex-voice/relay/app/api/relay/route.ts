import { experimental_upgradeWebSocket, type WebSocketData } from "@vercel/functions";
import WebSocket from "ws";
import { authenticate } from "@/lib/auth";
import { relayFailure, relayStage, relayWarning } from "@/lib/telemetry";

export const dynamic = "force-dynamic";
export const maxDuration = 300;

const MAX_BUFFERED_BYTES = 2 * 1_024 * 1_024;

function targetURL(request: Request): URL | null {
  try {
    const configured = process.env.CODEX_VOICE_EDGE_RELAY_URL;
    if (!configured) return null;
    const target = new URL(configured);
    if (target.protocol !== "wss:") return null;
    const source = new URL(request.url);
    target.search = "";
    for (const name of ["room", "role", "channel", "server"]) {
      const value = source.searchParams.get(name);
      if (value) target.searchParams.set(name, value);
    }
    return target;
  } catch {
    return null;
  }
}

function asBuffer(value: WebSocketData): Buffer {
  if (Array.isArray(value)) return Buffer.concat(value);
  if (value instanceof ArrayBuffer) return Buffer.from(new Uint8Array(value));
  return Buffer.from(value);
}

export function GET(request: Request) {
  const identity = authenticate(request);
  if (!identity) {
    relayWarning("authentication_rejected");
    return new Response("Unauthorized", {
      status: 401,
      headers: { "Cache-Control": "no-store" },
    });
  }

  // The always-on Mac must bypass Vercel so it cannot pin Function memory.
  if (identity.role === "host") {
    relayWarning("legacy_host_rejected");
    return new Response("Use the hibernating relay endpoint", {
      status: 410,
      headers: { "Cache-Control": "no-store" },
    });
  }

  const target = targetURL(request);
  const authorization = request.headers.get("authorization");
  if (!target || !authorization) {
    relayWarning("edge_relay_unavailable", { role: identity.role });
    return new Response("Relay unavailable", {
      status: 503,
      headers: { "Cache-Control": "no-store" },
    });
  }

  return experimental_upgradeWebSocket((client) => {
    relayStage("compatibility_proxy_upgraded", { role: identity.role });
    const upstream = new WebSocket(target, {
      headers: { Authorization: authorization },
      maxPayload: MAX_BUFFERED_BYTES,
    });
    const pending: Buffer[] = [];
    let pendingBytes = 0;
    let closed = false;

    const closeClient = (code: number, reason: string) => {
      if (closed) return;
      closed = true;
      if (client.readyState === WebSocket.OPEN) client.close(code, reason);
      if (
        upstream.readyState === WebSocket.OPEN ||
        upstream.readyState === WebSocket.CONNECTING
      ) {
        upstream.close(code, reason);
      }
      relayStage("compatibility_proxy_closed", { role: identity.role, close_code: code });
    };

    upstream.on("open", () => {
      relayStage("compatibility_upstream_opened", { role: identity.role });
      for (const frame of pending) upstream.send(frame);
      pending.length = 0;
      pendingBytes = 0;
    });
    upstream.on("message", (data) => {
      if (client.readyState === WebSocket.OPEN) client.send(data);
    });
    upstream.on("close", (code) => closeClient(code || 1011, "Relay connection ended"));
    upstream.on("error", (error) => {
      relayFailure("compatibility_upstream", error, { role: identity.role });
      closeClient(1011, "Relay connection failed");
    });

    client.on("message", (data: WebSocketData) => {
      const frame = asBuffer(data);
      if (upstream.readyState === WebSocket.OPEN) {
        upstream.send(frame);
        return;
      }
      pendingBytes += frame.byteLength;
      if (pendingBytes > MAX_BUFFERED_BYTES) {
        closeClient(1009, "Relay buffer exceeded");
        return;
      }
      pending.push(frame);
    });
    client.on("close", () => closeClient(1000, "Device disconnected"));
    client.on("error", (error) => {
      relayFailure("compatibility_client", error, { role: identity.role });
      closeClient(1011, "Device connection failed");
    });
  });
}
