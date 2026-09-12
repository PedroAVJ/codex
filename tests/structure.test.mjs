import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import test from "node:test";

const root = fileURLToPath(new URL("..", import.meta.url));
const expected = {
  "name": "codex",
  "version": "0.8.31",
  "url": "https://github.com/PedroAVJ/codex",
  "dependencies": []
};

async function json(...parts) {
  return JSON.parse(await readFile(join(root, ...parts), "utf8"));
}

test("only employees own threads and app sources are per-turn", async () => {
  const skill = await readFile(join(root, "skills", "sub-agents", "SKILL.md"), "utf8");
  assert.match(skill, /Only an explicitly addressed, configured employee may become the persistent\s+owner/i);
  assert.match(skill, /Claude\/Fable, Near, Spark, and Gemini are apps or model sources, not employees/i);
  assert.match(skill, /Re-resolve that intent on every turn/i);
  assert.match(skill, /unnamed follow-up goes to the current host or\s+employee/i);
  assert.match(skill, /Return app results with\s+compact source attribution/i);
  assert.match(skill, /Grok is the sole app exception/i);
  assert.match(skill, /discussion of Grok as a product still\s+does not invoke it/i);
  assert.match(skill, /current host has no group chat/i);
  assert.match(skill, /configured employee owner or current host returns the only conversational\s+answer/i);
  assert.doesNotMatch(skill, /selected participant owns\s+every later turn/i);
});

test("standalone plugin metadata is synchronized", async () => {
  const codex = await json(".codex-plugin", "plugin.json");
  assert.equal(codex.name, expected.name);
  assert.equal(codex.version, expected.version);
  assert.equal(codex.homepage, expected.url);
  assert.equal(codex.repository, expected.url);
  await access(join(root, "README.md"));
  await access(join(root, "AGENTS.md"));
  await access(join(root, "skills", "codex-voice", "SKILL.md"));
  await access(join(root, "skills", "codex-memory", "SKILL.md"));
  await access(join(root, "skills", "sub-agents", "SKILL.md"));
  await access(join(root, "skills", "sub-agents", "scripts", "read-roles.py"));
  await access(join(root, "skills", "realtime-orchestration", "SKILL.md"));
  await access(join(root, "skills", "source-attributed-relay", "SKILL.md"));
  await access(join(root, "scripts", "codex-memory.mjs"));
  await access(join(root, "products", "codex-voice", "Package.swift"));
  await access(join(root, "products", "codex-voice", "scripts", "bridge-status.sh"));
  await access(join(root, ".github", "workflows", "codex-voice-ci.yml"));
  await assert.rejects(access(join(root, "products", "codex-voice", ".codex-plugin", "plugin.json")));
  await assert.rejects(access(join(root, "products", "codex-voice", ".claude-plugin", "plugin.json")));

  const voiceSkill = await readFile(join(root, "skills", "codex-voice", "SKILL.md"), "utf8");
  assert.match(voiceSkill, /products\/codex-voice\/scripts/);

  if (expected.codexOnly) {
    await assert.rejects(access(join(root, ".claude-plugin", "plugin.json")));
  } else {
    const claude = await json(".claude-plugin", "plugin.json");
    assert.equal(claude.name, codex.name);
    assert.equal(claude.version, codex.version);
    assert.equal(claude.homepage, expected.url);
    assert.equal(claude.repository, expected.url);
    for (const dependency of expected.dependencies) {
      assert.ok((claude.dependencies ?? []).includes(dependency));
    }
  }

  const pkg = await json("package.json");
  assert.equal(pkg.version, expected.version);
  assert.equal(pkg.homepage, expected.url + "#readme");
  assert.equal(pkg.repository.url, "git+" + expected.url + ".git");
});

test("realtime orchestration uses sub-agents for substantial work and gates separate tasks", async () => {
  const skill = await readFile(join(root, "skills", "realtime-orchestration", "SKILL.md"), "utf8");
  assert.match(skill, /substantial implementation/);
  assert.match(skill, /Sub-agents are not restricted to small questions/);
  assert.match(skill, /create_thread[\s\S]*fork_thread[\s\S]*only when the\s+user explicitly requests/);
  assert.match(skill, /spawn_agent/);
  assert.match(skill, /send_message/);
  assert.match(skill, /followup_task/);
  assert.match(skill, /list_agents/);
  assert.match(skill, /at most one active owner per\s+workstream/);
  assert.match(skill, /Do not create a duplicate/);
  assert.match(skill, /exact agent identity/);
  assert.match(skill, /current status is unavailable/);
  assert.match(skill, /does not authorize interrupting or migrating\s+in-flight work/);
  assert.match(skill, /Do not duplicate the owner's research/);
  assert.doesNotMatch(skill, /Substantial work:\*\* fork/);
});

test("realtime queue advances only when the user chooses", async () => {
  const skill = await readFile(join(root, "skills", "realtime-orchestration", "SKILL.md"), "utf8");
  assert.match(skill, /Stay on that topic until the user chooses/);
  assert.match(skill, /Never rotate automatically/);
  assert.match(skill, /Do not move it to the back/);
  assert.match(skill, /reconcile the queue and verified ready\s+results first/);
  assert.match(skill, /Answer every direct user question prominently in the final response/);
  assert.doesNotMatch(skill, /order\s+becomes B, C, A/);
});

test("explicit tasks retain verification, permission, and archival boundaries", async () => {
  const skill = await readFile(join(root, "skills", "realtime-orchestration", "SKILL.md"), "utf8");
  assert.match(skill, /Archive only when the user requests it/);
  assert.match(skill, /genuinely\s+completed/);
  assert.match(skill, /trustworthy result and relay it before archiving/);
  assert.match(skill, /set_thread_archived/);
  assert.match(skill, /blocked, needs attention/);
  assert.match(skill, /user review or further work/);
  assert.match(skill, /Never archive the coordinating parent thread/);
  assert.match(skill, /list_archived_threads/);
  assert.match(skill, /archived: false/);
  assert.match(skill, /wait_threads/);
  assert.match(skill, /active turn is not copied/);
  assert.match(skill, /exposed goal tools prove independent automatic continuation/);
});
