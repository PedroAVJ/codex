---
name: source-attributed-relay
description: Use whenever relaying an app/model source response to the user, especially when the response must otherwise remain verbatim. Configured employee DMs use their natural voice without redundant attribution.
---

# Source-Attributed Relay

Make an app/model source visible in the user-facing answer. Put a source label
such as `Claude Fable 5.1:` outside the relayed body; never require the user to
infer which external runtime produced it. Apps are sources, not persistent
employees or thread participants.

When the body must be verbatim, preserve it exactly. The source label is an
external wrapper, not a rewrite or polish. Do not append a Codex verdict,
summary, or agreement unless the user separately asks for one.

Attribute only the app/model that authored the response. If the exact source is
unavailable, use a truthful generic label such as `Delegated response:` rather
than inventing a name. A configured employee speaking in their own one-to-one
thread does not need this wrapper; group contexts may use a compact employee name.
