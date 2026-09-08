import * as Sentry from "@sentry/cloudflare/nodejs_compat";
import type { ErrorEvent, Log, SpanJSON, TransactionEvent } from "@sentry/core";
import { DurableObject } from "cloudflare:workers";
import { authenticate } from "./auth";
import {
  type ConnectionAttachment,
  type RelayMessage,
  MAX_FRAME_BYTES,
  messageByteCount,
  normalize,
  rateLimit,
  textMessage,
} from "./protocol";

type Env = {
  ROOMS: DurableObjectNamespace;
  ALLOWED_SERVER_PUBLIC_KEYS: string;
  ENVIRONMENT: string;
  RELEASE: string;
  SENTRY_DSN: string;
};

type RelayAttributes = Record<string, string | number | boolean>;

const noStoreHeaders = {
  "Cache-Control": "no-store",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};

function sentryOptions(env: Env) {
  return {
    dsn: env.SENTRY_DSN,
    environment: env.ENVIRONMENT,
    release: env.RELEASE,
    enableLogs: true,
    tracesSampleRate: 1.0,
    enableRpcTracePropagation: true,
    sendDefaultPii: false,
    dataCollection: {
      userInfo: false,
      cookies: false,
      httpHeaders: { request: false, response: false },
      httpBodies: [],
      urlQueryParams: false,
      stackFrameVariables: false,
    },
    beforeSend(event: ErrorEvent) {
      delete event.request;
      event.user = { ip_address: "0.0.0.0" };
      return event;
    },
    beforeSendTransaction(event: TransactionEvent) {
      delete event.request;
      return event;
    },
    beforeSendLog(log: Log) {
      for (const key of [
        "room",
        "channel",
        "server",
        "authorization",
        "payload",
        "audio",
        "device_id",
        "user.id",
        "user.name",
        "user.email",
      ]) {
        delete log.attributes?.[key];
      }
      return log;
    },
    beforeSendSpan(span: SpanJSON) {
      for (const key of [
        "url.full",
        "url.query",
        "http.url",
        "http.request.header.authorization",
      ]) {
        delete span.data?.[key];
      }
      return span;
    },
  };
}

function relayLog(
  level: "info" | "warn" | "error",
  code: string,
  attributes: RelayAttributes = {},
) {
  const values = { component: "relay", code, ...attributes };
  const message = "Codex Voice hibernating relay transition";
  if (level === "error") Sentry.logger.error(message, values);
  else if (level === "warn") Sentry.logger.warn(message, values);
  else Sentry.logger.info(message, values);
}

function json(value: unknown, status = 200) {
  return Response.json(value, { status, headers: noStoreHeaders });
}

const worker = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/api/health") {
      return json({
        ok: true,
        relayProtocol: 1,
        transport: "durable-object-websocket-hibernation",
      });
    }
    if (url.pathname !== "/api/relay") return json({ ok: false }, 404);
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected WebSocket", {
        status: 426,
        headers: { ...noStoreHeaders, Upgrade: "websocket" },
      });
    }

    const identity = await authenticate(request, env.ALLOWED_SERVER_PUBLIC_KEYS);
    if (!identity) {
      relayLog("warn", "authentication_rejected");
      return new Response("Unauthorized", { status: 401, headers: noStoreHeaders });
    }

    const stub = env.ROOMS.getByName(identity.room);
    const internalRequest = new Request("https://relay.internal/connect", {
      method: "GET",
      headers: {
        Upgrade: "websocket",
        "X-Relay-Role": identity.role,
        "X-Relay-Channel": identity.channel,
      },
    });
    relayLog("info", "connection_authorized", { role: identity.role });
    return stub.fetch(internalRequest);
  },
} satisfies ExportedHandler<Env>;

class RelayRoomBase extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    if (
      request.headers.get("upgrade")?.toLowerCase() !== "websocket" ||
      new URL(request.url).pathname !== "/connect"
    ) {
      return new Response("Not found", { status: 404, headers: noStoreHeaders });
    }

    const role = request.headers.get("x-relay-role");
    const channel = request.headers.get("x-relay-channel") ?? "";
    if (
      (role !== "host" && role !== "device") ||
      !/^[a-zA-Z0-9_-]{1,128}$/.test(channel) ||
      (role === "host" && channel !== "host")
    ) {
      return new Response("Unauthorized", { status: 401, headers: noStoreHeaders });
    }

    for (const existing of this.ctx.getWebSockets()) {
      const attachment = this.attachment(existing);
      if (attachment.role === role && attachment.channel === channel) {
        attachment.superseded = true;
        existing.serializeAttachment(attachment);
        existing.close(1000, "Connection replaced");
      }
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    const attachment: ConnectionAttachment = {
      version: 1,
      role,
      channel,
      windowStartedAt: Date.now(),
      messageCount: 0,
      byteCount: 0,
    };
    server.serializeAttachment(attachment);
    this.ctx.acceptWebSocket(server);
    this.send(server, { kind: "ready", channel }, { target_role: role });
    relayLog("info", "connection_registered", {
      role,
      connection_count: this.ctx.getWebSockets().length,
      hibernation_eligible: true,
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(socket: WebSocket, value: string | ArrayBuffer): void {
    const attachment = this.attachment(socket);
    const frameBytes = messageByteCount(value);
    if (!rateLimit(attachment, frameBytes)) {
      socket.serializeAttachment(attachment);
      relayLog("warn", "rate_limit_exceeded", {
        role: attachment.role,
        frame_bytes: frameBytes,
      });
      this.send(socket, { kind: "error", message: "Relay rate limit exceeded" });
      socket.close(1008, "Rate limit exceeded");
      return;
    }
    socket.serializeAttachment(attachment);

    const text = textMessage(value);
    const message = text ? normalize(attachment, text) : null;
    if (!message) {
      relayLog("warn", "invalid_frame", {
        role: attachment.role,
        frame_bytes: frameBytes,
        maximum_frame_bytes: MAX_FRAME_BYTES,
      });
      this.send(socket, { kind: "error", message: "Invalid relay frame" });
      return;
    }

    let matchedConnections = 0;
    let queuedConnections = 0;
    const targetRole = attachment.role === "host" ? "device" : "host";
    for (const candidate of this.ctx.getWebSockets()) {
      if (candidate === socket) continue;
      const target = this.attachment(candidate);
      if (target.role !== targetRole) continue;
      if (
        targetRole === "device" &&
        message.channel &&
        target.channel !== message.channel
      ) {
        continue;
      }
      matchedConnections += 1;
      if (this.send(candidate, message, { target_role: targetRole })) {
        queuedConnections += 1;
      }
    }
    relayLog("info", "frame_delivery_attempted", {
      source_role: attachment.role,
      target_role: targetRole,
      relay_message_kind: message.kind,
      frame_bytes: frameBytes,
      payload_bytes: message.payload ? messageByteCount(message.payload) : 0,
      matched_connections: matchedConnections,
      queued_connections: queuedConnections,
    });
  }

  webSocketClose(
    socket: WebSocket,
    code: number,
    _reason: string,
    wasClean: boolean,
  ): void {
    this.notifyDisconnect(socket, "connection_closed", {
      websocket_close_code: code,
      websocket_close_clean: wasClean,
    });
  }

  webSocketError(socket: WebSocket, error: unknown): void {
    const errorName = error instanceof Error ? error.name : "UnknownError";
    this.notifyDisconnect(socket, "connection_failed", { error_name: errorName });
    Sentry.captureException(new Error("Codex Voice relay WebSocket failed"), {
      tags: { component: "relay", operation: "websocket" },
      extra: { error_name: errorName },
    });
  }

  private attachment(socket: WebSocket): ConnectionAttachment {
    const value = socket.deserializeAttachment() as ConnectionAttachment | null;
    if (!value || value.version !== 1) {
      throw new Error("Relay connection attachment is unavailable");
    }
    return value;
  }

  private send(
    socket: WebSocket,
    message: RelayMessage,
    attributes: RelayAttributes = {},
  ): boolean {
    if (socket.readyState !== WebSocket.OPEN) return false;
    try {
      const serialized = JSON.stringify(message);
      socket.send(serialized);
      relayLog("info", "websocket_send_completed", {
        relay_message_kind: message.kind,
        frame_bytes: messageByteCount(serialized),
        payload_bytes: message.payload ? messageByteCount(message.payload) : 0,
        ...attributes,
      });
      return true;
    } catch (error) {
      relayLog("error", "websocket_send_failed", {
        error_name: error instanceof Error ? error.name : "UnknownError",
        ...attributes,
      });
      return false;
    }
  }

  private notifyDisconnect(
    socket: WebSocket,
    code: string,
    attributes: RelayAttributes,
  ) {
    const attachment = this.attachment(socket);
    if (attachment.disconnectNotified) return;
    attachment.disconnectNotified = true;
    socket.serializeAttachment(attachment);

    if (!attachment.superseded) {
      const targetRole = attachment.role === "host" ? "device" : "host";
      const message: RelayMessage =
        attachment.role === "host"
          ? { kind: "close" }
          : { kind: "close", channel: attachment.channel };
      for (const candidate of this.ctx.getWebSockets()) {
        if (candidate === socket) continue;
        const target = this.attachment(candidate);
        if (target.role !== targetRole) continue;
        this.send(candidate, message, { target_role: targetRole });
      }
    }

    relayLog(code === "connection_failed" ? "error" : "info", code, {
      role: attachment.role,
      ...attributes,
    });
  }
}

export const RelayRoom = Sentry.instrumentDurableObjectWithSentry(
  sentryOptions,
  RelayRoomBase,
);

export default Sentry.withSentry(sentryOptions, worker);
