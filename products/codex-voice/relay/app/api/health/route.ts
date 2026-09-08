export const dynamic = "force-dynamic";

export function GET() {
  return Response.json(
    {
      ok: true,
      edgeRelayConfigured: Boolean(process.env.CODEX_VOICE_EDGE_RELAY_URL),
      relayProtocol: 1,
      transport: "cloudflare-durable-object-hibernation",
    },
    {
      headers: {
        "Cache-Control": "no-store",
      },
    },
  );
}
