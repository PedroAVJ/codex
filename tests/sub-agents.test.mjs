import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = fileURLToPath(new URL("..", import.meta.url));
const helper = join(root, "skills/sub-agents/scripts/read-roles.py");

async function fixture(t, registry, roleFiles = {}) {
  const dir = await mkdtemp(join(root, ".role-test-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await mkdir(join(dir, "roles"));
  await writeFile(join(dir, "config.toml"), registry);
  for (const [name, contents] of Object.entries(roleFiles)) {
    await writeFile(join(dir, "roles", name), contents);
  }
  return dir;
}

function run(args, env = {}) {
  return spawnSync("python3", [helper, ...args], {
    encoding: "utf8", timeout: 10_000, cwd: root,
    env: { ...process.env, ...env, PYTHONDONTWRITEBYTECODE: "1" },
  });
}

test("registry CLI lists roles without exposing unrelated or unselected private settings", async (t) => {
  const dir = await fixture(t, `
private_value = "must-not-leak"
[agents]
enabled = true
max_threads = 3
[agents.intern]
description = "Intern: a bounded helper"
config_file = "roles/helper.toml"
[agents.researcher]
description = "Researcher: native role"
`, { "helper.toml": 'developer_instructions = "private-role-instructions"' });
  const result = run(["--config", join(dir, "config.toml")]);
  assert.equal(result.status, 0, result.stderr);
  const data = JSON.parse(result.stdout);
  assert.deepEqual(data.roles.map((role) => role.key), ["intern", "researcher"]);
  assert.equal(data.roles[0].config_file, join(dir, "roles/helper.toml"));
  assert.equal(data.roles[1].config_file, null);
  assert.equal(data.merges_config_layers, false);
  assert.doesNotMatch(result.stdout, /must-not-leak|private-role-instructions/);
});

test("selected role reads current complete settings without inventing an inherited model", async (t) => {
  const dir = await fixture(t, `
[agents.domain_specialist]
description = "Domain specialist: software, product, design"
config_file = "roles/specialist.toml"
`, { "specialist.toml": `
model_reasoning_effort = "high"
developer_instructions = "Work individually."
[agents]
enabled = false
` });
  const args = ["--config", join(dir, "config.toml"), "--role", "domain_specialist"];
  const first = run(args);
  assert.equal(first.status, 0, first.stderr);
  const config = JSON.parse(first.stdout).role.config;
  assert.equal(Object.hasOwn(config, "model"), false);
  assert.equal(config.model_reasoning_effort, "high");
  assert.equal(config.agents.enabled, false);
  assert.equal(config.developer_instructions, "Work individually.");
  await writeFile(join(dir, "roles/specialist.toml"), `
model = "configured-model"
model_reasoning_effort = "medium"
developer_instructions = "Updated role."
sandbox_mode = "read-only"
[agents]
enabled = true
default_subagent_reasoning_effort = "low"
`);
  const next = run(args);
  assert.equal(next.status, 0, next.stderr);
  assert.deepEqual(JSON.parse(next.stdout).role.config, {
    model: "configured-model", model_reasoning_effort: "medium",
    developer_instructions: "Updated role.", sandbox_mode: "read-only",
    agents: { enabled: true, default_subagent_reasoning_effort: "low" },
  });
});

test("CODEX_HOME selects the registry and relative paths use its directory", async (t) => {
  const dir = await fixture(t, `
[agents.team_lead]
description = "Team lead"
config_file = "roles/lead.toml"
`, { "lead.toml": 'model_reasoning_effort = "xhigh"' });
  const before = await readFile(join(dir, "config.toml"), "utf8");
  const result = run(["--role", "team_lead"], { CODEX_HOME: dir });
  assert.equal(result.status, 0, result.stderr);
  const data = JSON.parse(result.stdout);
  assert.equal(data.registry_file, join(dir, "config.toml"));
  assert.equal(data.role.config_file, join(dir, "roles/lead.toml"));
  assert.equal(await readFile(join(dir, "config.toml"), "utf8"), before);
});

test("unknown roles and missing or invalid role files fail without substitutes", async (t) => {
  const dir = await fixture(t, `
[agents.intern]
description = "Intern"
config_file = "roles/missing.toml"
[agents.broken]
config_file = "roles/broken.toml"
`, { "broken.toml": 'private_value = "private unfinished string' });
  for (const role of ["undergrad", "Intern", "intern", "broken"]) {
    const result = run(["--config", join(dir, "config.toml"), "--role", role]);
    assert.equal(result.status, 1);
    assert.equal(result.stdout, "");
    assert.ok(JSON.parse(result.stderr).error);
    assert.doesNotMatch(result.stderr, /private unfinished string/);
  }
});

test("invalid registry TOML fails without echoing private input", async (t) => {
  const dir = await fixture(t, 'private_value = "private unfinished string');
  const result = run(["--config", join(dir, "config.toml")]);
  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  assert.deepEqual(JSON.parse(result.stderr), { error: "Invalid TOML configuration" });
});
