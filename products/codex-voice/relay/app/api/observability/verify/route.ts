import { timingSafeEqual } from "node:crypto";
import * as Sentry from "@sentry/nextjs";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const noStoreHeaders = { "Cache-Control": "no-store" };

function isAuthorized(request: Request): boolean {
  const expected = process.env.CODEX_VOICE_SENTRY_VERIFICATION_TOKEN?.trim();
  const authorization = request.headers.get("authorization") ?? "";
  const match = /^Bearer ([^\s]+)$/.exec(authorization);
  if (!expected || !match?.[1]) return false;

  const expectedBytes = Buffer.from(expected, "utf8");
  const suppliedBytes = Buffer.from(match[1], "utf8");
  return (
    expectedBytes.length === suppliedBytes.length &&
    timingSafeEqual(expectedBytes, suppliedBytes)
  );
}

export async function POST(request: Request) {
  if (!isAuthorized(request)) {
    return Response.json(
      { ok: false },
      { status: 404, headers: noStoreHeaders },
    );
  }

  const evidence = await Sentry.startSpan(
    {
      name: "relay.telemetry.verification",
      op: "telemetry.verify",
      forceTransaction: true,
      attributes: {
        component: "relay",
        verification: true,
      },
    },
    async (span) => {
      Sentry.logger.info("Relay telemetry verification log", {
        component: "relay",
        code: "telemetry_verification",
        verification: true,
      });

      const controlledError = new Error(
        "Controlled relay Sentry verification event",
      );
      controlledError.name = "CodexVoice.RelayTelemetryVerification";
      const eventId = Sentry.captureException(controlledError, {
        tags: {
          component: "relay",
          verification: "true",
        },
      });
      const { traceId, spanId } = span.spanContext();
      return { eventId, traceId, spanId };
    },
  );

  const flushed = await Sentry.flush(5_000);
  return Response.json(
    { ok: flushed, ...evidence },
    {
      status: flushed ? 200 : 503,
      headers: noStoreHeaders,
    },
  );
}
