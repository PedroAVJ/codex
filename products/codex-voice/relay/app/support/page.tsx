import { SiteShell, cardStyle, mutedStyle } from "../site-shell";

export default function Support() {
  return (
    <SiteShell eyebrow="SUPPORT" title="Set up your private voice link">
      <p style={{ ...mutedStyle, fontSize: 16, lineHeight: 1.6, margin: "0 auto 28px", maxWidth: 600 }}>
        Pedro Voice Agent pairs your iPhone and Apple Watch with the coding agent running on your own
        Mac. No shared demo account is required.
      </p>
      <article style={{ ...cardStyle, lineHeight: 1.65 }}>
        <h2 style={{ fontSize: 20, marginTop: 0 }}>Pair for the first time</h2>
        <ol style={{ paddingLeft: 22 }}>
          <li>Install and configure the Pedro Voice Agent companion on your Mac.</li>
          <li>Display the one-time pairing QR from the Mac setup flow.</li>
          <li>Open Pedro Voice Agent on iPhone and tap “Scan Mac QR.”</li>
          <li>Keep the paired Apple Watch nearby while the iPhone sends the secure identity.</li>
        </ol>

        <h2 style={{ fontSize: 20, marginTop: 26 }}>If Apple Watch is still pending</h2>
        <p>
          Open the iPhone app and tap “Send to Apple Watch” or “Send again.” Confirm that Bluetooth
          and Wi-Fi are enabled and that both devices are signed into the same Apple account.
        </p>

        <h2 style={{ fontSize: 20, marginTop: 26 }}>If a voice turn cannot connect</h2>
        <p>
          Confirm that the Pedro Voice Agent companion is running on the paired Mac and that the Mac
          has internet access. If needed, pair again using a fresh one-time QR.
        </p>

        <h2 style={{ fontSize: 20, marginTop: 26 }}>Contact</h2>
        <p style={{ marginBottom: 0 }}>
          For additional help, contact the developer through the public{" "}
          <a href="https://github.com/PedroAVJ" rel="noreferrer" target="_blank">
            PedroAVJ GitHub profile
          </a>
          .
        </p>
      </article>
    </SiteShell>
  );
}
