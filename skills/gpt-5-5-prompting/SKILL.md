---
name: gpt-5-5-prompting
description: Internal guidance for composing Codex and GPT-5.5 prompts for coding, review, diagnosis, and research tasks inside the Codex Claude Code plugin
user-invocable: false
---

# GPT-5.5 Prompting

Use this skill when `codex:codex-rescue` needs to ask Codex or another GPT-5.5-based workflow for help. The skill's job is to help compose tighter, outcome-first prompts before forwarding work to Codex/GPT-5.5.

Prompt Codex like a capable agent with a clear destination. State the outcome, success criteria, evidence rules, allowed side effects, and final answer shape. Avoid step-by-step process instructions unless the exact path is product-critical. Treat GPT-5.5 as a new baseline — start from the smallest prompt that preserves the product contract, not a port of an older prompt stack.

Core rules:
- One clear task per Codex run. Split unrelated asks into separate runs.
- Tell Codex what success means and when to stop.
- Use decision rules for judgment calls. Reserve MUST, NEVER, ONLY, ALWAYS for true invariants.
- Let Codex choose the path. Specify a sequence only when the workflow, policy, or product contract requires it.
- Prefer Structured Outputs API for strict machine-validated schemas; keep prompt-level output description to what the user surface needs.
- `reasoning.effort` defaults to `medium`. Raise to `high` or `xhigh` only when representative evals show measurable gains.
- `text.verbosity` defaults to `medium`. Use `low` for tight handoffs; ask explicitly for warmth, rationale, or personality when the surface needs it.
- Don't include the current date in system instructions. GPT-5.5 knows it. Add it only for business-effective dates, user-local timezones, or non-UTC references.
- Order prompt content static-first, dynamic-last to keep prompt caching effective.
- Put tool-specific rules inside tool descriptions (what the tool does, when to use it, inputs, side effects, retry safety, common errors). Use prompt-level tool policy only for cross-tool behavior.
- Prefer OpenAI-hosted tools (web search, file search, code interpreter, image generation, computer use) when they fit. Reserve custom function tools for internal systems and business-specific side effects.

Default prompt shape:
- `Goal` — the user-visible outcome.
- `Success criteria` — what must be true before finalizing.
- `Constraints` — scope, evidence, side effects, safety, repository limits.
- `Output` — final answer shape, length, tone.
- `Stop rules` — when to continue, ask, fallback, or stop.

Add when needed:
- Coding/debugging: validation expectations, allowed side effects, missing-context behavior.
- Review/diagnosis: grounding rules, materiality threshold.
- Research/recommendations: source boundaries, retrieval budget, citation format.
- Tool-heavy or long-running work: a short preamble requirement and explicit stop rules.
- Write-capable tasks: side-effect limits.

Picking the entry point:
- Built-in `review` / `adversarial-review` for local git-change reviews — those carry the review contract already.
- `task` for diagnosis, planning, research, or implementation when you control the prompt directly.
- `task --resume-last` for follow-ups on the same Codex thread — send only the delta unless the direction changed.

Assembly:
1. Define the outcome, success criteria, and stop rules.
2. Add only constraints that change behavior.
3. Add validation, grounding, side-effect, or preamble rules only where the task needs them.
4. Strip stale legacy instructions, redundant schema prose, and unnecessary absolutes before sending.

Reusable blocks live in [references/prompt-blocks.md](references/prompt-blocks.md).
Concrete end-to-end templates live in [references/codex-prompt-recipes.md](references/codex-prompt-recipes.md).
Common failure modes to avoid live in [references/codex-prompt-antipatterns.md](references/codex-prompt-antipatterns.md).
