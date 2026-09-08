# Codex Voice product direction

Status: accepted direction, 2026-08-29. This records the intended experience and
device roles. It does not imply that every platform capability below is already
implemented or physically validated.

## Start from the experience

Things that require attention should find the user. The user should be able to
respond in seconds without reaching for a screen, and should need a screen only
when seeing the content materially improves the decision.

The agent, rather than the iPhone or any individual app, is the center of the
experience. Work can run on the Mac or another trusted execution environment;
the devices the user wears and carries are interaction surfaces.

## Device roles

| Surface | Primary role |
| --- | --- |
| AirPods | Spoken audio output and a deliberately small binary gesture vocabulary: nod up and down for yes or confirm, shake side to side for no or dismiss. |
| Apple Watch | The always-available, voice-first control surface. It receives attention requests, captures spoken input, starts and continues turns, and shows short status or choices when yes/no is insufficient. |
| iPhone | A retained but secondary screen for media, long reading, diffs, and other visual review. It is not the default place where useful agent work happens. |
| Mac or trusted host | The execution surface for Codex, files, tools, credentials, and work that should not run on a wearable. |

The current Codex Voice iPhone app remains a minimal pairing companion. This
direction does not, by itself, authorize turning it into another chat client.
Future visual review may deep-link to an existing surface or use a purpose-built
one; that remains an open product decision.

## Interaction routing

- Use spoken audio for alerts, concise progress, questions, and results.
- Use nod or shake only for a genuinely binary choice whose context is already
  clear.
- Use voice when the response is richer than yes/no.
- Use the Watch display for short status, a small set of choices, or a glanceable
  result.
- Use an iPhone or Mac screen for video, feeds, long text, diffs, and anything
  that benefits from visual inspection.
- Do not add extra AirPods gestures merely because raw motion makes them
  possible. Audio, speech, yes, and no are the intended vocabulary.

A gesture is an input method, not an approval-policy bypass. Consequential Codex
actions must still present enough context and satisfy the existing approval and
safety boundary.

## Current Apple platform boundary

- Apple's public `CMHeadphoneMotionManager` API is available on iOS 14 and
  watchOS 7 or later. It provides raw processed headphone motion, including
  attitude, rotation rate, gravity, and user acceleration.
- The current public Xcode 26.5 SDK does not expose the first-party Siri semantic
  event as a third-party `nod` or `shake` callback. Codex Voice would need to
  classify the raw motion stream itself.
- Apple's user-facing head gestures map an up-and-down nod to accepting or
  replying and a side-to-side shake to declining or dismissing. That first-party
  behavior establishes the interaction convention, not a reusable semantic API.
- Stem presses remain media and system controls, not part of this product
  direction. Codex Voice should not depend on owning Now Playing merely to turn
  them into agent controls.

References:

- [CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager)
- [Use controls and gestures with AirPods](https://support.apple.com/guide/airpods/use-controls-and-gestures-devb2c431317/web)

## Prototype gates

The following are hypotheses until they pass on the physical Watch and AirPods
combination:

- The Watch can receive a stable AirPods motion stream while Codex Voice is also
  capturing and playing conversational audio.
- A small classifier can distinguish intentional nods and shakes with acceptable
  latency and false-positive rates across walking, looking around, and ordinary
  conversation.
- The desired AirPods output and Watch voice-input behavior remains stable across
  connection changes, interruptions, and media playback. The physical microphone
  route while AirPods are connected is an implementation question, not a settled
  product role.
- Proactive spoken interruptions can be useful without becoming intrusive.
- A wake phrase can enter or resume Codex Voice within watchOS lifecycle,
  privacy, battery, and background-execution constraints. Until proven, opening
  the Watch app or another explicit system entry point remains the reliable
  activation path.

No build, simulator result, paired bridge, or API availability check substitutes
for this physical acceptance.

## Non-goals

- Replacing the iPhone as a screen for visual media.
- Building a general-purpose phone chat interface into the pairing companion.
- Treating every possible AirPods motion as a command.
- Depending on private Siri, ChatGPT Remote, or GPT Live interfaces.
- Shipping nod/shake interaction or a wake phrase before physical validation.
