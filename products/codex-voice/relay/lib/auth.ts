import { createPublicKey, verify } from "node:crypto";

export type RelayRole = "host" | "device";

export type RelayIdentity = {
  room: string;
  role: RelayRole;
  channel: string;
  serverPublicKey: string;
};

type RelayAccessClaims = {
  version: number;
  room: string;
  role: RelayRole;
  clientID?: string;
  expiresAt: number;
};

const BASE64URL_32 = /^[A-Za-z0-9_-]{43}$/;
const BASE64URL_PUBLIC_KEY = /^[A-Za-z0-9_-]{86}$/;
const CHANNEL = /^[a-zA-Z0-9_-]{1,128}$/;

function decodeBase64URL(value: string): Buffer {
  return Buffer.from(value, "base64url");
}

function allowedServerKeys(): Set<string> {
  return new Set(
    (process.env.ALLOWED_SERVER_PUBLIC_KEYS ?? "")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  );
}

function publicKeyFromRaw(rawEncoded: string) {
  const raw = decodeBase64URL(rawEncoded);
  if (raw.length !== 64) throw new Error("invalid public key");
  return createPublicKey({
    format: "jwk",
    key: {
      kty: "EC",
      crv: "P-256",
      x: raw.subarray(0, 32).toString("base64url"),
      y: raw.subarray(32, 64).toString("base64url"),
    },
  });
}

function bearerToken(request: Request): string | null {
  const authorization = request.headers.get("authorization") ?? "";
  const match = /^Bearer ([^\s]+)$/.exec(authorization);
  return match?.[1] ?? null;
}

export function authenticate(request: Request): RelayIdentity | null {
  try {
    const url = new URL(request.url);
    const room = url.searchParams.get("room") ?? "";
    const role = url.searchParams.get("role") as RelayRole | null;
    const channel = url.searchParams.get("channel") ?? "";
    const serverPublicKey = url.searchParams.get("server") ?? "";
    const token = bearerToken(request);
    if (
      !BASE64URL_32.test(room) ||
      (role !== "host" && role !== "device") ||
      !CHANNEL.test(channel) ||
      (role === "host" && channel !== "host") ||
      !BASE64URL_PUBLIC_KEY.test(serverPublicKey) ||
      !token ||
      !allowedServerKeys().has(serverPublicKey)
    ) {
      return null;
    }

    const pieces = token.split(".");
    if (pieces.length !== 2) return null;
    const [payloadEncoded, signatureEncoded] = pieces;
    if (!payloadEncoded || !signatureEncoded) return null;
    const publicKey = publicKeyFromRaw(serverPublicKey);
    const valid = verify(
      "sha256",
      Buffer.from(payloadEncoded, "utf8"),
      publicKey,
      decodeBase64URL(signatureEncoded),
    );
    if (!valid) return null;

    const claims = JSON.parse(decodeBase64URL(payloadEncoded).toString("utf8")) as RelayAccessClaims;
    const now = Math.floor(Date.now() / 1000);
    if (
      claims.version !== 1 ||
      claims.room !== room ||
      claims.role !== role ||
      !Number.isSafeInteger(claims.expiresAt) ||
      claims.expiresAt <= now
    ) {
      return null;
    }
    if (role === "device" && claims.clientID && claims.clientID !== channel) {
      // Paired credentials use their stable client ID as the relay channel.
      return null;
    }
    return { room, role, channel, serverPublicKey };
  } catch {
    return null;
  }
}
