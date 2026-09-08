import type { CSSProperties, ReactNode } from "react";

export const mutedStyle: CSSProperties = { color: "#6b6964" };

export const cardStyle: CSSProperties = {
  background: "#ffffff",
  border: "1px solid rgba(20,20,19,0.10)",
  borderRadius: 16,
  boxSizing: "border-box",
  padding: 22,
  textAlign: "left",
};

function RelayMark() {
  const bar = (height: number, color: string): CSSProperties => ({
    background: color,
    borderRadius: 10,
    height,
    width: 8,
  });

  return (
    <div
      aria-label="Pedro Voice Agent"
      role="img"
      style={{
        alignItems: "center",
        background: "#020b2d",
        borderRadius: 18,
        display: "flex",
        gap: 5,
        height: 76,
        justifyContent: "center",
        width: 76,
      }}
    >
      <span style={bar(18, "#0067ff")} />
      <span style={bar(31, "#6857ff")} />
      <span style={bar(43, "#1c7dff")} />
      <span style={bar(32, "#00bce7")} />
      <span style={bar(18, "#00d4e6")} />
    </div>
  );
}

export function SiteShell({
  children,
  eyebrow,
  title,
}: {
  children: ReactNode;
  eyebrow: string;
  title: string;
}) {
  return (
    <main
      style={{
        boxSizing: "border-box",
        fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif",
        margin: "0 auto",
        maxWidth: 760,
        minHeight: "100vh",
        padding: "36px 22px 48px",
        textAlign: "center",
      }}
    >
      <nav
        aria-label="Pedro Voice Agent"
        style={{ alignItems: "center", display: "flex", justifyContent: "space-between", marginBottom: 62 }}
      >
        <a href="/" style={{ color: "#141413", fontSize: 15, fontWeight: 700, textDecoration: "none" }}>
          Pedro Voice Agent
        </a>
        <div style={{ display: "flex", gap: 18 }}>
          <a href="/support" style={{ color: "#6b6964", fontSize: 14, textDecoration: "none" }}>
            Support
          </a>
          <a href="/privacy" style={{ color: "#6b6964", fontSize: 14, textDecoration: "none" }}>
            Privacy
          </a>
        </div>
      </nav>
      <header style={{ margin: "0 auto 32px", maxWidth: 680 }}>
        <div style={{ display: "flex", justifyContent: "center", marginBottom: 24 }}>
          <RelayMark />
        </div>
        <p style={{ ...mutedStyle, fontSize: 11, fontWeight: 750, letterSpacing: 2, margin: "0 0 12px" }}>
          {eyebrow}
        </p>
        <h1 style={{ fontSize: "clamp(38px, 7vw, 58px)", letterSpacing: -2.2, lineHeight: 1.02, margin: 0 }}>
          {title}
        </h1>
      </header>
      {children}
      <footer style={{ ...mutedStyle, fontSize: 13, marginTop: 48 }}>
        © 2026 Pedro Villanueva
      </footer>
    </main>
  );
}
