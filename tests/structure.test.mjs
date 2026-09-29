import assert from "node:assert/strict";
import { access, readdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import test from "node:test";

const root = fileURLToPath(new URL("..", import.meta.url));
const expected = {
  "name": "codex",
  "version": "0.9.0",
  "url": "https://github.com/PedroAVJ/codex",
  "dependencies": []
};

async function json(...parts) {
  return JSON.parse(await readFile(join(root, ...parts), "utf8"));
}

test("the plugin is Claude-only and its metadata is synchronized", async () => {
  await assert.rejects(access(join(root, ".codex-plugin", "plugin.json")));
  const claude = await json(".claude-plugin", "plugin.json");
  assert.equal(claude.name, expected.name);
  assert.equal(claude.version, expected.version);
  assert.equal(claude.homepage, expected.url);
  assert.equal(claude.repository, expected.url);
  for (const dependency of expected.dependencies) {
    assert.ok((claude.dependencies ?? []).includes(dependency));
  }
  await access(join(root, "README.md"));
  await access(join(root, "AGENTS.md"));

  const pkg = await json("package.json");
  assert.equal(pkg.version, expected.version);
  assert.equal(pkg.homepage, expected.url + "#readme");
  assert.equal(pkg.repository.url, "git+" + expected.url + ".git");
});

test("image-generation is the only skill", async () => {
  const skills = (await readdir(join(root, "skills"), { withFileTypes: true }))
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name);
  assert.deepEqual(skills, ["image-generation"]);
  const skill = await readFile(join(root, "skills", "image-generation", "SKILL.md"), "utf8");
  assert.match(skill, /^---\nname: image-generation\n/);
  assert.match(skill, /codex exec/);
  assert.match(skill, /generated_images\/<thread_id>/);
  assert.match(skill, /image_gen\.py/);
});

test("only the review commands remain and none is model-invocable", async () => {
  const commands = (await readdir(join(root, "commands"))).sort();
  assert.deepEqual(commands, ["adversarial-review.md", "cancel.md", "result.md", "review.md", "status.md"]);
  for (const command of commands) {
    const text = await readFile(join(root, "commands", command), "utf8");
    assert.match(text, /^disable-model-invocation: true$/m, command);
  }
});
