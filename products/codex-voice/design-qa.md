# Pedro Voice Agent Watch design QA

## Visual authority

- Claude Design product: resolve from private operator configuration.
- Page: `Codex Voice Watch UI - Headerless Connection v4.dc.html`, option 1a, used for layout and interaction hierarchy only
- Source workspace: selected by the operator and kept outside Git.
- Public visual source: original Pedro Voice Agent icon and pulse documented in `ICON-SOURCES.md`.

## Rendered evidence

- Target: Apple Watch Series 11 (42 mm) simulator
- Viewport: 187 x 223 points, captured at 374 x 446 pixels
- Required app states: live, connecting, recovery, ended, and approval
- App Review remediation audit: the pre-change and current live builds were captured on the same isolated simulator and combined into one side-by-side comparison input. The circular focal point, vertical position, mute/end controls, sizing, and spacing remain aligned; only the third-party-like animated orb was replaced by the original relay pulse.
- Required complication host: Solar Dial Digital, Relay in Bottom Left
- Required audio probes: a real provider round trip plus DEBUG Watch-simulator playback through `.dataPlayedBack`

## Iteration history

1. Removed the repeated product lockup from the top chrome.
2. Replaced text-only restart actions with a native 44-point `arrow.clockwise` control.
3. Removed the third-party voice-orb frames and replaced them with one original relay pulse.
4. Reserved native progress UI for connection and kept the ordinary live loop unlabeled.
5. Added exact-face and microphone-probe acceptance gates so generic previews and source assertions cannot be reported as visual or end-to-end acceptance.

## Result

### App UI: passed

- The installed Watch app was captured in live, connecting, recovery, and approval states after a clean Debug build.
- The recovery and approval copy now refers only to Pedro Voice Agent or "your agent"; no third-party product name is presented as the app's public identity.
- The normal loop and exceptional states have no repeated product header.
- Connection uses native progress UI; recovery uses the 44-point icon-only restart control.
- The old 18-frame, 6-fps custom animation loop is absent.

### Complication: passed

- The paired iPhone Watch app shows Solar Dial with Digital selected and Relay in Bottom Left.
- Adding that configured face to the Watch rendered the native relay waveform in the actual bottom-left slot.
- A full Watch Simulator shutdown and cold boot preserved the face and rendered mark.
- WidgetKit accepted the timeline with one entry and emitted no `WidgetArchiver.ArchivingError`.
- Tapping the waveform after the cold boot launched Pedro Voice Agent.
- The regression suite verifies that the complication uses the native `waveform` symbol rather than a bundled third-party bitmap.

### Watch audio: candidate verified; physical acceptance pending

- The synthetic integration test passed PCM generation, automatic turn detection, wire encoding, WAV construction, and OpenRouter request construction.
- A spoken fixture completed the real bridge and OpenRouter path: 180,908 bytes of 24 kHz mono PCM produced 122,400 bytes of returned PCM audio.
- The returned provider audio then ran through the production `AVAudioConverter` and `AVAudioPlayerNode` path on the watchOS 26.5 simulator. All 61,200 source frames became 122,400 route frames, the pending queue drained to zero, and the completion callback reported `.dataPlayedBack`.
- A separate capture-before-playback probe activated a granted 48 kHz record session with one advertised input, but a fresh `AVAudioEngine` exposed a 0 Hz/0-channel hardware input and a 0 Hz/two-channel tap format. Capture therefore failed precisely at `input_format` before `first_buffer`.
- That capture result is a simulator input limitation, not a passing microphone test. Sentry and the local diagnostic stream now preserve the exact stage, native error domain/code, engine state, input format, provider progress, and playback completion without logging PCM, transcripts, credentials, or pairing material.
- Final voice acceptance requires one complete capture-to-playback turn on the physical Watch after TestFlight installation.
