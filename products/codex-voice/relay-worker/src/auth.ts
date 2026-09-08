export type RelayRole = "host" | "device";

export type RelayIdentity = {
  room: string;
  role: RelayRole;
  channel: string;
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

function decodeBase64URL(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function arrayBuffer(value: Uint8Array): ArrayBuffer {
  return value.buffer.slice(
    value.byteOffset,
    value.byteOffset + value.byteLength,
  ) as ArrayBuffer;
}

async function publicKeyFromRaw(rawEncoded: string): Promise<CryptoKey> {
  const raw = decodeBase64URL(rawEncoded);
  if (raw.length !== 64) throw new Error("invalid public key");
  const uncompressed = new Uint8Array(65);
  uncompressed[0] = 4;
  uncompressed.set(raw, 1);
  return crypto.subtle.importKey(
    "raw",
    uncompressed,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
}

function readDERLength(value: Uint8Array, offset: number): [number, number] {
  const first = value[offset];
  if (first === undefined) throw new Error("invalid signature length");
  if ((first & 0x80) === 0) return [first, offset + 1];
  const byteCount = first & 0x7f;
  if (byteCount < 1 || byteCount > 2 || offset + byteCount >= value.length) {
    throw new Error("invalid signature length");
  }
  let length = 0;
  for (let index = 0; index < byteCount; index += 1) {
    length = (length << 8) | value[offset + 1 + index];
  }
  return [length, offset + 1 + byteCount];
}

function normalizeInteger(value: Uint8Array): Uint8Array {
  let start = 0;
  while (value.length - start > 32 && value[start] === 0) start += 1;
  const integer = value.subarray(start);
  if (integer.length > 32) throw new Error("invalid signature integer");
  const normalized = new Uint8Array(32);
  normalized.set(integer, 32 - integer.length);
  return normalized;
}

function p1363Signature(derEncoded: string): Uint8Array {
  const value = decodeBase64URL(derEncoded);
  let offset = 0;
  if (value[offset++] !== 0x30) throw new Error("invalid signature sequence");
  const [sequenceLength, sequenceStart] = readDERLength(value, offset);
  offset = sequenceStart;
  if (offset + sequenceLength !== value.length || value[offset++] !== 0x02) {
    throw new Error("invalid signature sequence");
  }
  const [rLength, rStart] = readDERLength(value, offset);
  offset = rStart;
  const rEnd = offset + rLength;
  if (rEnd > value.length) throw new Error("invalid signature integer");
  const r = normalizeInteger(value.subarray(offset, rEnd));
  offset = rEnd;
  if (value[offset++] !== 0x02) throw new Error("invalid signature sequence");
  const [sLength, sStart] = readDERLength(value, offset);
  offset = sStart;
  const sEnd = offset + sLength;
  if (sEnd !== value.length) throw new Error("invalid signature integer");
  const s = normalizeInteger(value.subarray(offset, sEnd));
  const signature = new Uint8Array(64);
  signature.set(r, 0);
  signature.set(s, 32);
  return signature;
}

function bearerToken(request: Request): string | null {
  const authorization = request.headers.get("authorization") ?? "";
  const match = /^Bearer ([^\s]+)$/.exec(authorization);
  if (match?.[1]) return match[1];

  // Already-paired clients on the former Vercel endpoint include the same
  // signed credential in the query while using the compatibility endpoint.
  return new URL(request.url).searchParams.get("auth");
}

export async function authenticate(
  request: Request,
  allowedServerPublicKeys: string,
  now: number = Math.floor(Date.now() / 1000),
): Promise<RelayIdentity | null> {
  try {
    const url = new URL(request.url);
    const room = url.searchParams.get("room") ?? "";
    const role = url.searchParams.get("role") as RelayRole | null;
    const channel = url.searchParams.get("channel") ?? "";
    const serverPublicKey = url.searchParams.get("server") ?? "";
    const token = bearerToken(request);
    const allowedKeys = new Set(
      allowedServerPublicKeys
        .split(",")
        .map((value) => value.trim())
        .filter(Boolean),
    );

    if (
      !BASE64URL_32.test(room) ||
      (role !== "host" && role !== "device") ||
      !CHANNEL.test(channel) ||
      (role === "host" && channel !== "host") ||
      !BASE64URL_PUBLIC_KEY.test(serverPublicKey) ||
      !token ||
      !allowedKeys.has(serverPublicKey)
    ) {
      return null;
    }

    const pieces = token.split(".");
    if (pieces.length !== 2) return null;
    const [payloadEncoded, signatureEncoded] = pieces;
    if (!payloadEncoded || !signatureEncoded) return null;
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      await publicKeyFromRaw(serverPublicKey),
      arrayBuffer(p1363Signature(signatureEncoded)),
      arrayBuffer(new TextEncoder().encode(payloadEncoded)),
    );
    if (!valid) return null;

    const claims = JSON.parse(
      new TextDecoder().decode(decodeBase64URL(payloadEncoded)),
    ) as RelayAccessClaims;
    if (
      claims.version !== 1 ||
      claims.room !== room ||
      claims.role !== role ||
      !Number.isSafeInteger(claims.expiresAt) ||
      claims.expiresAt <= now ||
      (role === "device" && claims.clientID && claims.clientID !== channel)
    ) {
      return null;
    }

    return { room, role, channel };
  } catch {
    return null;
  }
}
