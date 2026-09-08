# Prompt Blocks

Use these blocks selectively when composing Codex or GPT-5.5 prompts.

Shift from large XML prompt stacks to lean outcome-first sections. GPT-5.5 works well when the prompt says what good looks like, names constraints, and lets the model choose the path. XML tags are still useful for host systems that parse blocks or for strict subcontracts, but the default here is short Markdown sections.

## Core Shape

### Role

Use when the integration context matters.

```markdown
Role: You are Codex running through the Codex Claude Code rescue plugin. Help resolve the user's request with the available repository context and tools.
```

### Goal

Use in every prompt.

```markdown
# Goal
[Describe the user-visible outcome, relevant repository or failure context, and expected end state.]
```

### Success Criteria

Use for any task with more than one possible interpretation.

```markdown
# Success criteria
- [Observable result that must be true before finalizing.]
- [Evidence or validation expected.]
- [What the final answer must make clear.]
```

### Constraints

Use to limit scope, evidence, side effects, or risk.

```markdown
# Constraints
- Keep changes scoped to the stated task.
- Preserve existing behavior outside the affected path.
- Ground factual claims in provided context or tool output.
- Ask only when missing information would materially change correctness, safety, or an external side effect.
```

### Output

Use when the final response shape matters.

```markdown
# Output
Return:
1. result
2. evidence or changed files
3. validation performed
4. remaining blockers or risks

Keep the answer concise.
```

### Stop Rules

Use for tool-heavy, research, debugging, or long-running tasks.

```markdown
# Stop rules
Continue until the core request can be answered or completed with useful evidence.
Stop and ask a narrow question only when missing information blocks correctness or creates meaningful risk.
Do not keep searching only to improve phrasing or gather nonessential support.
```

## Formatting and Style

### Concise Answer

Use when `text.verbosity=low` is desired or the user wants a tight handoff.

```markdown
# Output
Use concise prose. Put the conclusion first, then the evidence and caveats. Avoid long setup.
```

### Conversational Surface

Use when the output is customer-facing or should sound warmer than the default direct style.

```markdown
# Style
Be warm, clear, and practical. Give enough rationale for the user to trust the answer, then stop. Match the user's tone within professional bounds.
```

### Strict Artifact

Prefer Structured Outputs API for strict schemas. Use this only when the host cannot enforce the schema.

```xml
<output_contract>
Return only the requested artifact. Do not add prose or markdown fences unless requested.
If required schema information is missing, return a minimal error with the missing fields.
Before finalizing, check that the output matches the requested shape.
</output_contract>
```

## Grounding and Retrieval

### Grounding Rules

Use for review, diagnosis, research, or any factual answer that could drift.

```markdown
# Grounding
Base claims on provided context or tool outputs.
Label inferences as inferences.
If sources conflict, state the conflict and attribute each side.
If evidence is insufficient, narrow the answer or say what remains unsupported.
```

### Citation Rules

Use when external research, retrieved docs, or quotes matter.

```markdown
# Citations
Cite only sources inspected in this workflow.
Attach citations to the specific claims they support.
Do not fabricate citations, URLs, IDs, or quote spans.
Use the citation format required by the host application.
```

### Retrieval Budget

Use to avoid open-ended search loops.

```markdown
# Retrieval budget
Use the minimum evidence sufficient to answer correctly.
Search again only when a required fact, owner, date, ID, source, or artifact is missing; the user asked for exhaustive coverage; or the answer would otherwise contain an important unsupported claim.
Stop once the core request is answered with adequate support.
```

### Missing Context

Use when Codex might otherwise guess.

```xml
<missing_context_gating>
If required context is missing, do not guess.
Use the appropriate lookup tool when the context is retrievable.
Ask a minimal clarifying question only when the context is not retrievable or the next action would be risky.
If proceeding with an assumption, label it and choose a reversible action.
</missing_context_gating>
```

## Coding and Tool Use

### Validation

Use for implementation, debugging, or high-impact changes.

```markdown
# Validation
After making changes, run the most relevant available validation:
- targeted tests for changed behavior
- typecheck or lint when applicable
- a focused smoke test when full validation is too expensive

If validation cannot be run, explain why and describe the next best check.
```

### Action Safety

Use for write-capable or side-effecting work.

```xml
<action_safety>
Keep side effects scoped to the stated task.
Before irreversible or external actions, ask for permission.
After any write/update action, report what changed, where it changed, and what validation was performed.
</action_safety>
```

### Preamble

Use when the run is multi-step, tool-heavy, or long-running.

```markdown
# Preambles
Before tool calls for a multi-step task, send a short user-visible update that acknowledges the request and states the first step.
Keep updates to one or two sentences and reserve them for major phase changes, discoveries, or blockers.
```

### Phase Handling

Use when the host manually replays Responses assistant items.

```markdown
# Responses state
If assistant items are manually replayed, preserve each original `phase` value unchanged.
Use `phase: "commentary"` for intermediate updates and `phase: "final_answer"` for completed answers.
Do not add `phase` to user messages.
```

### Tool Guidance Placement

Use when designing or revising the integration around Codex.

```markdown
# Tool guidance
Put tool-specific rules in tool descriptions: what the tool does, when to use it, required inputs, side effects, retry safety, and common errors.
Use prompt-level tool policy only for rules that span multiple tools or change the agent's operating policy.
Prefer OpenAI-hosted tools (web search, file search, code interpreter, image generation, computer use) when they fit; reserve custom function tools for internal systems and business-specific side effects.
For large tool catalogs, consider tool search to defer tool definitions and load only the relevant subset.
```

## Long-Running Agents

### State Compaction

Use for rescue threads that may continue across many turns.

```markdown
# State compaction
When compacting state, preserve:
- completed actions
- active assumptions
- important IDs, paths, branches, issues, and tool outcomes
- unresolved blockers
- next concrete goal

Do not preserve stale process narration unless it changes the next action.
```

### Reasoning Effort

Use when the prompt controls model configuration.

```markdown
# Model configuration
Start with `reasoning.effort=medium` unless latency or cost favors `low`.
Use `high` or `xhigh` only when representative evals show a measurable quality gain.
Use `text.verbosity=low` when the desired answer is concise.
```
