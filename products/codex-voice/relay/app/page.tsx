import { SiteShell, cardStyle, mutedStyle } from "./site-shell";

export default function Home() {
  return (
    <SiteShell eyebrow="INDEPENDENT WATCH CLIENT" title="Voice mode, from your wrist">
      <p style={{ ...mutedStyle, fontSize: 18, lineHeight: 1.6, margin: "0 auto 28px", maxWidth: 600 }}>
        Pedro Voice Agent securely connects Apple Watch to the coding agent on your Mac. It is an
        independent product designed and built by Pedro Villanueva.
      </p>
      <section style={cardStyle}>
        <div style={{ alignItems: "center", display: "flex", gap: 12 }}>
          <span
            aria-hidden="true"
            style={{ background: "#34c759", borderRadius: 8, boxShadow: "0 0 0 5px #e3f5e8", height: 10, width: 10 }}
          />
          <div>
            <h2 style={{ fontSize: 18, margin: 0 }}>Encrypted relay online</h2>
            <p style={{ ...mutedStyle, lineHeight: 1.55, margin: "5px 0 0" }}>
              The relay routes encrypted packets and cannot read the audio, requests, or responses
              inside them.
            </p>
          </div>
        </div>
      </section>
    </SiteShell>
  );
}
