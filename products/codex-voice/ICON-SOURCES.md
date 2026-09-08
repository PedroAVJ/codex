# Icon sources

- `assets/pedro-voice-agent.png` is the original 1024 px source master for Pedro Voice Agent.
- The iPhone and Watch app icons are exact 1024 px copies of that master. The smaller iPhone `AppIcon-*` files and `RelayIcon.png` are deterministic downscaled variants.
- `RelayPulse.jpg` is a 512 px JPEG derivative of the same original artwork, circularly masked by SwiftUI for the Watch voice surface.
- The Watch complication uses Apple's native `waveform` SF Symbol; it has no bundled logo bitmap.
- The replaced Codex terminal-flower, OpenAI knot studies, ChatGPT voice-orb frames, and their generator are intentionally absent from the repository and shipped bundle.

## Generation record

The final source was created with the built-in ImageGen tool on 2026-08-28 and center-cropped for app-icon legibility. Final prompt:

> Simplify the central symbol so it remains unmistakable at 24 pixels. Keep the dark navy background and cobalt-cyan-violet palette. Remove circular arrows and outer radio-wave arcs. Keep exactly two bold endpoint discs connected by one compact voice waveform, with one subtle straight relay beam behind it. Make the mark large, flat, balanced, fully opaque, and original. No text, letters, watermark, OpenAI, ChatGPT, Codex, flower, blossom, knot, interlocking loops, terminal prompt, cloud, chatbot bubble, or swirling orb.
