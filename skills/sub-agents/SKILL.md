---
name: sub-agents
description: Route persistent configured employees independently of app/model sources. Claude/Fable, Near, Spark, and Gemini require explicit invocation on each turn and return source-attributed output; mentions never invoke them. Grok is the sole app continuity exception for an explicitly established X/Twitter research lane. Run actual requested runtimes with live role instructions and never impersonate them.
---

# Sub-agents

Codex is the current main assistant, with no pinned model version and no implicit
role or seniority. A configured role identifies an employee and its
responsibilities. Claude/Fable, Near, Spark, Gemini, and Grok identify app/model
sources. An explicitly requested source chooses the runtime for a bounded run;
it does not turn that app into an employee.

Gemini and Grok use their installed native cloud-backed CLIs through the same
named-participant helper. The current defaults are `gemini-3.5-flash` and
`grok-4.6`. A local CLI does not mean local model weights. Native authentication,
model entitlement, quota, billing, and trust remain separate from this plugin.

## Separate employee ownership from app invocation

Only an explicitly addressed, configured employee may become the persistent
owner of a one-to-one thread. Resolve employees against the live role registry
below. Once selected, that employee can inherit unnamed follow-ups, reactions,
corrections, “continue,” and “you” within the same conversation. If no employee
is selected, the current main assistant remains the host and answers unaddressed
turns.

Claude/Fable, Near, Spark, and Gemini are apps or model sources, not employees.
Invoke one only when the current turn explicitly asks, addresses, uses, or
consults it. Re-resolve that intent on every turn. A product discussion, quoted
name, comparison, file content, or incidental mention does not invoke an app.
After returning an app result, an unnamed follow-up goes to the current host or
employee; it does not automatically call the app again. Return app results with
compact source attribution.

Grok is the sole app exception because it is the configured X/Twitter API lane.
An explicit Grok or X-research request may establish Grok continuity for related
unnamed follow-ups in that thread. Mere discussion of Grok as a product still
does not invoke it. Do not extend this exception to any other app or model.

The current host has no group chat. Multiple explicitly requested sources may
run independently, but return attributed results rather than simulated chat
participants. Internal consultation and Near's hidden Fable–Astra collaboration
also do not create participants.

Read conversational intent, not a keyword switch. Never infer an unrequested
employee role from task difficulty. A source can use a shared role contract for
one explicitly requested run when its runtime can honor it; that does not make
the app the employee or thread owner.

| Request | Actual routing |
| --- | --- |
| “Help me understand this error.” | Current host answers; no implicit role. |
| “Fable, review this.” | One actual Fable run, attributed as Claude; no ownership transfer. |
| “Spark, as Software engineer, fix this.” | One actual Spark run with the live matching role contract. |
| “Undergrad. Explain this.” | Configured Undergrad employee handles it and may own later unnamed follow-ups. |
| “Continue” after Fable answered | Current host or employee answers; do not invoke Fable. |
| “Ask Claude and Gemini to assess this.” | Run both explicitly and return separately attributed sources. |
| “We were discussing Claude Desktop.” | Current host answers about the product; no Claude relay. |
| “Use Near to check my context.” | One explicit Near invocation; later unnamed messages do not stay with Near. |
| “Use Grok to search X for this topic.” | Grok/X route; related unnamed follow-ups may retain Grok continuity. |
| “What is the difference between Spark and an Intern?” | Codex explains; no dispatch. |
| “Engineer, look at this” with multiple matching roles | Clarify role before dispatching that portion. |

## Resolve the live role configuration

Use the current host's effective agent registry and role configuration as the
authority. In Codex, custom registrations normally live in `[agents.<role>]` in
`$CODEX_HOME/config.toml` (default `~/.codex/config.toml`), with `config_file`
paths resolved relative to the file declaring them. Inspect any active profile,
project, or runtime overrides before treating that user file as effective state.

The bundled read-only helper reads one registry file without dumping unrelated
configuration. It requires Python 3.11+:

```bash
python3 "<plugin-root>/skills/sub-agents/scripts/read-roles.py"
python3 "<plugin-root>/skills/sub-agents/scripts/read-roles.py" --role domain_specialist
```

Use `--config <registry-file>` when the declaring file is elsewhere. This helper
does not merge configuration layers or launch agents. If Python is unavailable,
read the relevant TOML directly; do not install a runtime just for this lookup.
Keep private configuration out of public artifacts and pass only the selected
role's necessary instructions to its agent.

Match exact registered keys, their human-readable names, and clear domain wording
supported by their descriptions. For example, if `domain_specialist` explicitly
covers software, “Software engineer” means that role with domain software. The
same applies to product or design when supported by the live description. This
is contextual matching, not a new aliases field or a permanent role table.
An exact registered name takes precedence over a broader domain match. Ask one
concise clarification when multiple registrations remain plausible. If no role
matches, report that it is not configured; do not invent, create, or silently
substitute a role.

Read the selected role's complete configuration before dispatch. Preserve its
model selection (including inheritance) when no app/model source is explicitly
requested. An explicit per-turn source request selects its runtime independently
and overrides only the role model for that run; the employee remains the owner.
Preserve the role's exact reasoning effort, instructions,
delegation restrictions, and other applicable execution constraints. Do not
hard-code a model/effort ladder or infer role identity from those settings. Do
not edit the registry, role files, or concurrency settings to fulfill a routing
request.

## Dispatch explicitly requested app/model sources

Codex without a role stays in the current assistant; never pin a Codex version or
spawn a duplicate merely because the user mentions the Codex product. Codex with
an explicitly addressed employee role uses the configured agent route below.
When the current assistant is explicitly requested with a role, use the current
main-assistant model even if the role file pins another model; do not use a
native selector that would silently restore that role model. Choose a generic
child with the current model and the resolved role contract instead. For Spark and Claude/Fable, use their actual
runtime helpers when the native collaboration surface cannot select that model.
This explicit named-participant route is a bounded exception to the generic
no-shell-worker fallback below, and does not create a separate sidebar task.
Do not modify the rescue companion host guard or pretend a generic child is Spark.

Resolve the selected role once using `read-roles.py --role <exact-key>` and save
its complete JSON to a private temporary file outside Git (`--role-contract`).
That same contract is consumed by both runtimes. Delete it after completion.
The resolver does not merge profiles or project layers; inspect applicable
runtime overrides before using it and do not claim it represents uninspected
layers. Do not edit the shared registry to adapt a participant.

For Spark:

```bash
node "<codex-plugin-root>/scripts/named-participant.mjs" \
  --participant Spark --role-contract "<private-contract.json>" \
  --cwd "<owned-workspace>" --prompt-file "<bounded-task.txt>"
```

Omit `--role-contract` for a request without a role. Alternatively use `--role
<exact-key> [--config <registry>]` to resolve the same live source in the helper.
The helper runs an ephemeral public Codex CLI task, verifies Spark from runtime
startup metadata, and returns JSON with model, role, exact effort, and answer.
It applies the role's runtime configuration through CLI controls, retains role
instructions, and preserves delegation constraints. It neither resumes a random
thread nor requires a new app task. A later turn must explicitly invoke Spark
again; include the previous bounded result and necessary context when it does.
Use the CLI's current environment permissions and any stricter task boundaries;
never add sandbox bypasses or broaden access to make a role run.

For Claude/Fable, read the installed `claude:claude` skill and invoke its
`ask_fable.py` helper with the same `--role-contract <private-contract.json>`.
When the selected role permits delegation, resolve only its allowed roles from
the same registry and pass each through `--delegate-role-contract <file>` so
native delegates receive their real instructions and supported effort. Do not
invent a Claude-specific role ladder. The Claude helper pins Fable and reports
unsupported runtime constraints instead of silently discarding them.

For Gemini or Grok:

```bash
node "<codex-plugin-root>/scripts/named-participant.mjs" \
  --participant Gemini --cwd "<owned-workspace>" --prompt-file "<bounded-task.txt>"
node "<codex-plugin-root>/scripts/named-participant.mjs" \
  --participant Grok --cwd "<owned-workspace>" --prompt-file "<bounded-task.txt>"
```

These are bounded subprocesses, not sidebar tasks. Gemini requires explicit
per-turn invocation. Grok may also continue a related unnamed turn only after an
explicit Grok/X request established the X/Twitter lane. Install Gemini CLI from
`@google/gemini-cli` and Grok Build from the official `https://x.ai/cli/install.sh`
only when setup is authorized. Commands are `gemini` and `grok`; optional exact
executable overrides are `CODEX_GEMINI_BINARY` and `CODEX_GROK_BINARY`. Invalid
overrides fail without selecting another runtime. Authenticate with the native
CLI first. This helper does not start login, purchase access, enable billing, or
create credentials. An `auth_required` result is not a model contribution.

Gemini accepts an explicit concrete `--model gemini-...` override. Its startup
model can differ from the model used: the helper also verifies final per-model
usage and rejects any fallback or mixed-model run. The default `gemini-3.5-flash`
was exercised through Gemini CLI 0.59.0; do not infer a newer API model is used
merely because the CLI accepts its name. If the caller has independently verified
the task owns and trusts the workspace, `--trust-workspace` passes Gemini's
session-scoped `--skip-trust`. Otherwise preserve the native trust prompt. Never
use that flag to bypass an unknown or untrusted repository's boundary.

The initial cloud adapters intentionally support a limited role contract:

- Both accept the selected role's instructions and model identity override.
  Individual `agents.enabled=false` is supported; coordinating/delegating roles
  and other runtime settings fail before launch. Both receive no-delegation
  instructions. Grok also uses native `--no-subagents`; Gemini enforcement is
  instructional, not a claim that tools are disabled.
- Gemini's native CLI has no effort flag. This adapter declines every explicit
  role effort or `--effort`, including a configured Undergrad's medium effort.
  It can run as the Gemini participant without an effort-bound role. Do not
  remove a selected role's effort or claim prompt prose applies it.
- Grok 4.6 supports exact `low`, `medium`, `high`, and `xhigh` through the native
  `--reasoning-effort` flag. The result distinguishes this requested native flag
  from unreported provider-default effort; it does not claim server-side effort
  readback. Model identity must appear in native assistant-message metadata.
- Grok's `dontAsk` mode refuses tools requiring new approval and preserves
  existing native permission rules. Gemini uses its existing native approval
  settings. Neither adapter enables YOLO or bypasses a sandbox. These are not
  translations of Codex sandbox/approval contracts: roles specifying those
  settings are rejected rather than silently weakened.

The Grok 4.6 reply and an individual medium-effort role were verified through
Grok Build 1.0.25 with native OAuth. X Search is not a verified capability of
this adapter: a live probe returned a server search result error `unavailable`
and produced no X post. A successful model response does not prove search
availability. Inspect returned `toolErrors`; do not call failed tool work
complete or substitute invented search results. Provider/account capabilities
may differ, so verify the requested tool with real output before claiming it.

Native sessions and credentials remain in each provider's own store. Private
prompt artifacts created by the wrapper are removed after completion or failure.
Report actual response, usage/model verification, and any authentication or
unsupported-role blocker separately. A successful install or mock test alone
does not prove that a provider can answer on the user's account.

Exact role effort must be supported by the selected source. For example,
Spark supports low, medium, high, and xhigh; a role requiring max must be declined
by Spark. Never cap it to xhigh, replace the model, or claim prose sets its
runtime effort. Explain that source's incompatible role and continue other
independent requested contributions. This is a capability failure, not a request
to rewrite the shared role or choose another model automatically.

Include task scope, domain, authorization, ownership, and completion criteria in
each bounded prompt. Preserve no-delegation instructions even if a runtime's
tools remain exposed, and accurately distinguish behavioral enforcement from
native tool restrictions. A coordinating role may delegate only as configured.
For consultation requested by the employee owner or current host, relay each real
result into that bounded context. The employee or host returns the single
user-facing answer and accurately attributes consulted evidence without
presenting a second chat participant.

## Dispatch the actual agent

Prefer the host's native registered-role selector when available. Inspect the
exposed tool schema; do not invent an `agent_type` argument when it is absent.
If the host exposes generic collaboration spawning instead, create an actual
child with the resolved role's instructions and supported execution settings.
That adaptation is valid only when it can preserve the role's relevant contract.
Distinguish runtime controls from behavioral instructions. Model, reasoning
effort, sandbox, and approval boundaries require supported runtime controls;
prose cannot replace them. On a generic surface without an `agents.enabled`
control, carry `agents.enabled = false` as an explicit instruction to work
individually and never spawn, contact, or delegate to other agents or threads.
Preserve any narrower allowed-delegation rules the same way. This is instruction
enforcement, not tool-level disabling; never claim the tools were disabled. If
the user or configuration requires tool-level enforcement, or another required
runtime setting cannot be represented, report the exact limitation rather than
spawning a default worker and calling it the requested role.

For the collaboration API, set `reasoning_effort` to the configured value when
present. A role with no explicit model inherits the current model: omit `model`.
For an explicit configured model without a per-turn source override, use that model only when the host supports it.
When passing an override, use `fork_turns: "none"` or a supported bounded history
fork; a full-history fork cannot carry those overrides. Include the selected
role's instructions, assigned domain, bounded task, necessary context, existing
authorization, owned files/surfaces, and completion criteria in the handoff. Do
not pretend a prompt alone changes the runtime's reasoning effort.

Reconcile current owners before spawning. Reuse the exact role agent for the
same workstream: `send_message` steers a running agent and `followup_task` resumes
an idle one. Track requested role, registered key, domain, effective settings,
agent identity, assignment, and verified state. A changed role or domain needs
an appropriate owner rather than silently relabeling the existing agent.

Run independent requested roles concurrently when capacity permits. Serialize
dependencies or conflicting writes and give each worker exclusive ownership.
If capacity is full, keep the role assignment queued. Do not replace it with a
separate task, fork, shell worker, or parent impersonation. Separate app tasks
and forks require the user's explicit request for that mechanism.

The role configuration also governs whether a child may delegate. A role that
must work individually must not spawn further agents, including for review or
testing. A coordinating role may delegate only as its configuration permits.
Explicit recipient selection takes precedence over generic plugin work-routing
defaults, including the preference for sub-agents in realtime orchestration and
plugin implementation. This skill does not authorize unsolicited role selection
for unaddressed requests or grant additional access, writes, or external actions.

## Return the employee or host answer

The configured employee owner or current host returns the only conversational
answer. In a one-to-one employee thread, do not add a redundant employee/model
label. App/model results from Claude/Fable, Near, Spark, or Gemini require compact
source labels and never become a second persistent speaker. Multiple explicitly
requested app sources receive distinct attribution. Grok may answer within an
established X/Twitter lane under its sole continuity exception, while still
attributing the X posts or search evidence it used. A role label is execution
metadata and should appear only when material. Preserve every direct question in
the final response; dispatch and progress updates are not answers. Report running
or completed state only from current evidence. If a source or employee role
cannot run, state that limitation rather than substituting another runtime.

During active realtime voice, use
[realtime-orchestration](../realtime-orchestration/SKILL.md) for queue and status
handling while preserving the employee owner selected here. For any internal
consultation, use only a runtime route that actually honors the resolved shared
role; never present an unapplied persona as that configured agent.
