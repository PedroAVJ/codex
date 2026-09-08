# Codex Prompt Anti-Patterns

Avoid these when prompting Codex or GPT-5.5.

## Treating GPT-5.5 as a drop-in replacement

Bad:

```text
Use the old prompt unchanged, just change the model to gpt-5.5.
```

Better:

```markdown
Start from the smallest prompt that preserves the product contract.
Define the outcome, success criteria, constraints, output shape, and stop rules.
Then tune reasoning effort, verbosity, and tool behavior against representative examples.
```

## Process-heavy prompt stacks

Bad:

```text
First inspect A, then inspect B, then enumerate every possible cause, then search all files, then explain every step, then decide what to do.
```

Better:

```markdown
# Goal
Resolve the failing behavior.

# Success criteria
- Root cause is identified from repository evidence.
- The smallest safe fix is applied when possible.
- Relevant validation is run or the validation gap is explained.
```

## Unnecessary absolutes for judgment calls

Bad:

```text
Always search every related file. Never ask questions. Only stop when every possible edge case is explored.
```

Better:

```markdown
Use tools when repository facts are needed.
Ask only when missing information materially changes correctness or creates meaningful risk.
Stop once the core request is answered or completed with useful evidence.
```

## Raising reasoning effort before fixing the task contract

Bad:

```text
Set reasoning to xhigh and think much harder.
```

Better:

```markdown
Clarify:
- the outcome
- success criteria
- evidence rules
- allowed side effects
- output shape
- stop rules

Start from `reasoning.effort=medium`; raise effort only when evals show measurable gains.
```

## Missing stop rules

Bad:

```text
Research this thoroughly.
```

Better:

```markdown
# Retrieval budget
Use the minimum evidence sufficient to answer correctly.
Search again only when a required fact, source, ID, date, owner, or artifact is missing, or when the answer would otherwise contain an important unsupported claim.
Stop once the recommendation is adequately supported.
```

## Prompt-level schemas that should be API schemas

Bad:

```text
Always output JSON with these twenty fields, nested exactly like this...
```

Better:

```markdown
Use Structured Outputs API for strict schema validation.
In the prompt, describe the user-visible result and any missing-data behavior.
```

## Including the current date by habit

Bad:

```text
The current date is [today]. Use it in all answers.
```

Better:

```markdown
Do not include the date unless the workflow needs a business-effective date, user-local timezone, or non-UTC reference.
```

## Over-searching for style rather than evidence

Bad:

```text
Keep searching until you can make the answer sound more complete.
```

Better:

```markdown
Search again only when the core answer lacks required evidence.
Do not search again merely to improve phrasing, add nonessential examples, or support wording that can be made more generic.
```

## Missing tool-boundary design

Bad:

```text
Use tools when needed.
```

Better:

```markdown
Put tool-specific rules in tool descriptions:
- what the tool does
- when to use it
- required inputs
- side effects
- retry safety
- common errors

Use prompt-level tool policy only for cross-tool behavior.
Prefer OpenAI-hosted tools (web search, file search, code interpreter, image generation, computer use) where they fit. Use custom function tools for internal systems and business-specific side effects.
```

## Losing Responses state

Bad:

```text
Replay prior assistant messages as plain text.
```

Better:

```markdown
Use `previous_response_id` when possible.
If manually replaying assistant output items, preserve each original `phase` value unchanged.
Use `commentary` for intermediate updates and `final_answer` for completed answers.
```

## Unsupported certainty

Bad:

```text
Tell me exactly why production failed.
```

Better:

```markdown
# Grounding
Base claims on inspected logs, deployment records, repository context, or tool outputs.
Label inferences as inferences.
If evidence is insufficient, state what remains unknown and the smallest next check.
```
