---
name: source-attributed-relay
description: Use whenever relaying or returning another model or agent's response to the user, especially when the response must otherwise remain verbatim.
---

# Source-Attributed Relay

Make the delegated speaker visible in the user-facing answer. Put a source label
such as `Claude Fable 5.1:` outside the relayed body; never require the user to
infer the speaker from conversational context.

When the body must be verbatim, preserve it exactly. The source label is an
external wrapper, not a rewrite or polish. Do not append a Codex verdict,
summary, or agreement unless the user separately asks for one.

Attribute only the model or agent that authored the response. If the exact
speaker is unavailable, use a truthful generic label such as `Delegated
response:` rather than inventing a name.
