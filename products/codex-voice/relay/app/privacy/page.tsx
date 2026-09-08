import { SiteShell, cardStyle, mutedStyle } from "../site-shell";

const sectionStyle = { marginTop: 24 };

export default function Privacy() {
  return (
    <SiteShell eyebrow="PRIVACY POLICY" title="Private by architecture">
      <p style={{ ...mutedStyle, fontSize: 16, lineHeight: 1.6, margin: "0 auto 28px", maxWidth: 600 }}>
        Effective August 29, 2026. Pedro Voice Agent is built to keep credentials and conversation
        contents out of the relay service.
      </p>
      <article style={{ ...cardStyle, lineHeight: 1.65 }}>
        <h2 style={{ fontSize: 20, marginTop: 0 }}>What the app processes</h2>
        <p>
          The iPhone app uses the camera only when you choose to scan the one-time pairing QR shown
          by your Mac. The Apple Watch app captures audio only after you start a voice turn.
        </p>

        <h2 style={{ ...sectionStyle, fontSize: 20 }}>How voice data moves</h2>
        <p>
          Audio, requests, and responses are encrypted between your Apple devices and your paired
          Mac. The relay routes encrypted packets but does not hold the keys required to read their
          contents. Your paired Mac sends requests to the coding and model providers you configure;
          those providers process data under their own terms and privacy policies.
        </p>

        <h2 style={{ ...sectionStyle, fontSize: 20 }}>Credentials and pairing</h2>
        <p>
          Provider API credentials stay in the Mac Keychain. The QR contains short-lived pairing
          material, and the resulting encrypted pairing credential is stored on your iPhone and
          Apple Watch until you choose “Forget this Mac.”
        </p>

        <h2 style={{ ...sectionStyle, fontSize: 20 }}>Diagnostics</h2>
        <p>
          Limited technical diagnostics—such as app version, operation stage, error type, timing,
          and byte counts—may be sent to Sentry to diagnose reliability. Diagnostics are configured
          to exclude raw audio, prompts, responses, API keys, QR payloads, screenshots, and precise
          location data.
        </p>

        <h2 style={{ ...sectionStyle, fontSize: 20 }}>Retention and control</h2>
        <p>
          The relay keeps active connection state only as needed to route a session. You can remove
          locally stored pairing data at any time with “Forget this Mac.” Pedro Voice Agent does not
          sell personal information or use it for advertising.
        </p>

        <h2 style={{ ...sectionStyle, fontSize: 20 }}>Questions</h2>
        <p style={{ marginBottom: 0 }}>
          For privacy or support questions, visit the <a href="/support">support page</a>.
        </p>
      </article>
    </SiteShell>
  );
}
