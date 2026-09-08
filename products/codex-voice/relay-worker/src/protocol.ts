export type RelayRole = "host" | "device";

export type RelayMessage = {
  kind: "ready" | "frame" | "close" | "error";
  channel?: string;
  payload?: string;
  message?: string;
  deliveryId?: string;
  sequence?: number;
};

export type ConnectionAttachment = {
  version: 1;
  role: RelayRole;
  channel: string;
  windowStartedAt: number;
  messageCount: number;
  byteCount: number;
  superseded?: boolean;
  disconnectNotified?: boolean;
};

export const MAX_FRAME_BYTES = 1_500_000;
export const RATE_WINDOW_MS = 10_000;
export const MAX_MESSAGES_PER_WINDOW = 800;
export const MAX_BYTES_PER_WINDOW = 8_000_000;

const CHANNEL = /^[a-zA-Z0-9_-]{1,128}$/;
const DELIVERY_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function messageByteCount(value: string | ArrayBuffer): number {
  return typeof value === "string"
    ? new TextEncoder().encode(value).byteLength
    : value.byteLength;
}

export function textMessage(value: string | ArrayBuffer): string | null {
  if (typeof value === "string") return value;
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(value);
  } catch {
    return null;
  }
}

export function rateLimit(
  attachment: ConnectionAttachment,
  byteCount: number,
  now: number = Date.now(),
): boolean {
  if (now - attachment.windowStartedAt >= RATE_WINDOW_MS) {
    attachment.windowStartedAt = now;
    attachment.messageCount = 0;
    attachment.byteCount = 0;
  }
  attachment.messageCount += 1;
  attachment.byteCount += byteCount;
  return (
    attachment.messageCount <= MAX_MESSAGES_PER_WINDOW &&
    attachment.byteCount <= MAX_BYTES_PER_WINDOW
  );
}

export function normalize(
  attachment: ConnectionAttachment,
  value: string,
): RelayMessage | null {
  if (messageByteCount(value) > MAX_FRAME_BYTES) return null;
  try {
    const message = JSON.parse(value) as RelayMessage;
    if (message.kind !== "frame" && message.kind !== "close") return null;
    const channel = attachment.role === "device" ? attachment.channel : message.channel;
    if (!channel || channel === "host" || !CHANNEL.test(channel)) return null;

    const deliveryId = message.deliveryId;
    const sequence = message.sequence;
    if (
      (deliveryId === undefined) !== (sequence === undefined) ||
      (deliveryId !== undefined && !DELIVERY_ID_PATTERN.test(deliveryId)) ||
      (sequence !== undefined &&
        (!Number.isSafeInteger(sequence) || sequence < 1))
    ) {
      return null;
    }

    if (message.kind === "frame") {
      if (
        typeof message.payload !== "string" ||
        messageByteCount(message.payload) > MAX_FRAME_BYTES
      ) {
        return null;
      }
      return {
        kind: "frame",
        channel,
        payload: message.payload,
        deliveryId,
        sequence,
      };
    }
    return { kind: "close", channel, deliveryId, sequence };
  } catch {
    return null;
  }
}
