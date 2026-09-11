---
name: realtime-orchestration
description: Coordinate questions and substantial work during GPT Live or realtime voice conversations, using direct answers, collaboration sub-agents first, and a user-controlled one-topic conversation queue. Separate tasks and forks require an explicit user request. Do not use for Codex Voice device setup or ordinary text-only tasks.
---

# Realtime Orchestration

Use this skill only in a Codex app thread with an active realtime voice session.
Keep the parent conversation as the user's control surface. Respect the user's
explicit routing and the host's available tools and permission boundaries.

When the user addresses named roles, apply
[sub-agents](../sub-agents/SKILL.md) first to resolve their actual configured
agents, including multiple roles or parent-plus-role assignments. The parent has
no implicit role. Explicit recipients and their delegation restrictions take
precedence over the generic work-routing preferences below.

## Use sub-agents first

- **Direct answer:** handle trivial questions, brief clarifications, tiny actions,
  and coordination in the parent when delegation overhead exceeds the work.
- **Delegated work:** use collaboration sub-agents for independent research,
  sustained investigations, substantial implementation, and other substantial
  deliverables. Sub-agents are not restricted to small questions. Give each one
  a concrete outcome, relevant context, evidence standard, permission boundary,
  owned files or external surfaces, and the result it must report. A question
  remains read-only unless the user authorized changes.
- **Separate task or fork:** use `create_thread` or `fork_thread` only when the
  user explicitly requests a separate task or fork. Size, duration, an idle
  worker, or a full concurrency limit does not authorize this substitution.

Use `spawn_agent` for a new delegated workstream, `send_message` to steer a
running agent, and `followup_task` to resume the same idle agent. Explicit plugin
implementation follows this normal work route and its source/release workflow;
do not create an unsolicited stewardship worker as a prerequisite.

When sub-agent capacity is unavailable, keep the work queued and explain that
boundary when relevant. Do not silently launch a thread or shell worker, change
concurrency settings, or take over the delegated investigation. Keep doing useful
coordination or independent in-scope work. Do not duplicate the owner's research
merely to fill time or answer a status question.

## Keep a verified conversation queue

Maintain stable entries in the user's priority order. Track each entry's latest
question or feedback, exact owner and mechanism, latest verified execution state,
last delivered finding, and whether a new answer is ready. Keep conversation
state separate from execution: an idle agent does not resolve a question, and an
open question does not prove an agent is running.

- Deliver one topic per answer. Stay on that topic until the user chooses to
  advance, reprioritize, resolve, or drop it. Never rotate automatically after
  an answer or feedback.
- Send feedback promptly to the existing owner and preserve it on the same
  queue entry. Do not move it to the back or deliver another topic unless the
  user asks to move on.
- When the user asks for the next item, reconcile the queue and verified ready
  results first. Deliver the next new ready answer in the user's priority order.
  Never guess the queue order, repeat an already-delivered result as new, or
  describe an unsupported hypothesis as a discovery.
- Worker completion or answer delivery does not remove a still-open topic.
  Remove it only when the user resolves or drops it. If no new answer is ready,
  say so briefly when asked; do not invent activity or restart exhausted research.
- Answer every direct user question prominently in the final response, including
  status and clarification questions. Commentary or dispatch is not an answer.
  Keep internal worker jargon and raw identifiers out unless they are needed.

For example, with A, B, C queued, feedback on A stays with A's owner and the
conversation stays on A. Only when the user says “next” should the coordinator
deliver B's new ready answer, or C's if B has none ready.

## Track ownership before dispatch

Keep a compact registry mapping each workstream to its exact agent identity,
short specific name, scope, and latest verified state. Names are labels, not
identity or status evidence. Track any explicitly requested separate tasks by
their exact thread IDs and mechanism, never interchangeably with agent IDs.

Before dispatch, reconcile the registry with `list_agents` and received results.
Reuse the relevant agent for continuations. Maintain at most one active owner per
workstream. Do not create a duplicate because an agent is idle, a status lookup
failed, or a task is not visible on iPhone Remote.

If a workstream already belongs to a separate task, verify that exact task with
`wait_threads` (`timeoutMs: 0`) or `read_thread` and continue coordinating its
existing work. The new default does not authorize interrupting or migrating
in-flight work. If the user requests a mechanism change, stop or retire the old
owner before dispatching a replacement and transfer its verified state.

Give each agent exclusive write ownership. Do not let concurrent agents edit
the same files or control the same browser profile. Repository isolation still
applies: each implementation agent owns its task-specific clone and cleanup.

## Coordinate through the parent

- Continue the conversation after dispatch so the user can discuss or
  reprioritize other work without waiting silently.
- Use `list_agents` for status, delivered agent messages/results for updates,
  and bounded `wait_agent` calls only when waiting is useful. Check detailed
  history only when necessary. Do not narrate unchanged polling.
- Relay meaningful progress, questions, blockers, and results with clear source
  attribution. Do not present your own speculation as the agent's answer, or a
  sent prompt as completed work.
- Claim that an owner is running or completed only when a current tool result
  or received completion supports it. If status cannot be verified, say its
  current status is unavailable. A promise, remembered narrative, spawn result,
  or missing sidebar item is not proof of ongoing work or completion.
- For multi-workstream status questions, reconcile every requested owner and
  verified state internally. Answer yes/no first when asked, then only the
  concise detail needed to explain it.
- Before reporting completion, verify the requested output or change exists and
  passed its applicable checks. Preserve the agent's report for follow-up.

## Explicitly requested separate tasks and forks

Use the app's supported lifecycle only after the user's explicit request:

1. Resolve the requested task/project/environment and avoid duplicates. For a
   fork, remember that the active turn is not copied. Send a cohesive follow-up
   prompt containing the current objective, scope, permissions, and ownership.
2. Record the returned exact identity and a specific title. Use `set_thread_title`
   when a rename is needed. A pending client identity is not a thread ID.
3. Verify status with `wait_threads` and bounded waits/cursors; use `read_thread`
   for details and `send_message_to_thread` for corrections. Creation or prompt
   delivery alone does not prove that work is running or completed.
4. Keep relaying through the parent. Do not require the user to open a child on
   iPhone Remote or promise separately navigable nested tasks there.

Archive only when the user requests it and the exact task has genuinely
completed: verify its trustworthy result and relay it before archiving with
`set_thread_archived`. Never archive merely because the task is idle or its
current turn ended, or while it is blocked, needs attention, or is awaiting
user review or further work. Never archive the coordinating parent thread as
worker cleanup. Restore an explicitly requested task with
`list_archived_threads` and `set_thread_archived` (`archived: false`) if needed.
Omit archived tasks from routine active-status summaries.

## Boundaries

Delegation carries context, not additional authority. Preserve scope, permissions,
credential boundaries, and destructive-action rules in every handoff. Do not infer
that exposed goal tools prove independent automatic continuation; report only
host behavior actually verified, and create goals only when explicitly requested.

This skill does not change concurrency settings or the Codex Voice iPhone and
Apple Watch companion. Use `codex-voice` for that product's device work.
