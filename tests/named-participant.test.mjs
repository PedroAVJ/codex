import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { buildSparkRequest, readRoleContract, verifySparkMetadata } from '../scripts/lib/named-participant.mjs';
const cli = new URL('../scripts/named-participant.mjs', import.meta.url);
const contract = config => ({ registry_file: '/fixture/config.toml', merges_config_layers: false, role: { key: 'reviewer', config } });

test('Spark overrides role model only and applies runtime constraints and instructions', () => {
  const request = buildSparkRequest({ participant: 'Spark', cwd: '.', prompt: 'Check this', contract: contract({
    model: 'other-model', model_reasoning_effort: 'high', developer_instructions: 'Review each claim.',
    sandbox_mode: 'read-only', approval_policy: 'never', agents: { enabled: false },
  }) });
  assert.equal(request.model, 'gpt-5.3-codex-spark');
  assert.equal(request.configuredModel, 'other-model');
  assert.ok(request.args.includes('sandbox_mode="read-only"'));
  assert.ok(request.args.includes('approval_policy="never"'));
  assert.ok(request.args.includes('agents.enabled=false'));
  assert.ok(request.args.includes('model_reasoning_effort="high"'));
  assert.match(request.args.join('\n'), /Review each claim/);
  assert.match(request.args.join('\n'), /Never spawn, contact, or delegate/);
  assert.doesNotMatch(request.args.join('\n'), /other-model/);
});

test('explicit Spark, exact supported effort, valid contract and provider are required', () => {
  const base = { participant: 'Spark', cwd: '.', prompt: 'Bounded task' };
  for (const participant of [undefined, 'Codex', 'Claude', 'Fable']) assert.throws(() => buildSparkRequest({ ...base, participant }), /explicit/);
  for (const model_reasoning_effort of ['max', 'ultra', 'minimal', 'none']) assert.throws(() => buildSparkRequest({ ...base, contract: contract({ model_reasoning_effort }) }), /cannot represent/);
  assert.throws(() => buildSparkRequest({ ...base, contract: contract({ model_provider: 'custom' }) }), /provider/);
  assert.throws(() => buildSparkRequest({ ...base, effort: 'low', contract: contract({ model_reasoning_effort: 'high' }) }), /conflicts/);
  assert.throws(() => readRoleContract({ role: 'x', contract: '/tmp/x' }), /not both/);
  assert.throws(() => verifySparkMetadata('The answer says I am Spark'), /could not be verified/);
  assert.throws(() => verifySparkMetadata('model: other-model\n'), /could not be verified/);
  assert.equal(verifySparkMetadata('model: gpt-5.3-codex-spark\n'), 'gpt-5.3-codex-spark');
});

test('real entrypoint works from Codex host, consumes live resolver contract and verifies model metadata', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'spark-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const fake = path.join(dir, 'codex');
  fs.writeFileSync(fake, `#!/usr/bin/env node\nconst fs = require('fs');\nif(process.argv.includes('--version')) { console.log('codex-cli 1.0.0'); process.exit(0); }\nfs.writeFileSync(process.env.CAPTURE, JSON.stringify(process.argv.slice(2)));\nconsole.error('model: ' + (process.env.FAKE_MODEL || 'gpt-5.3-codex-spark'));console.error('reasoning effort: ' + (process.env.FAKE_EFFORT || 'medium'));\nfs.writeFileSync(process.argv[process.argv.indexOf('--output-last-message')+1], 'Bounded answer');\nprocess.stdin.resume();\n`);
  fs.chmodSync(fake, 0o700);
  fs.writeFileSync(path.join(dir, 'config.toml'), '[agents.reviewer]\ndescription="Reviewer"\nconfig_file="reviewer.toml"\n');
  fs.writeFileSync(path.join(dir, 'reviewer.toml'), 'model_reasoning_effort="medium"\ndeveloper_instructions="Check evidence."\n[agents]\nenabled=false\n');
  const env = { ...process.env, CLAUDECODE: '', CODEX_COMPANION_BINARY: fake, CAPTURE: path.join(dir, 'argv.json') };
  const args = [cli.pathname, '--participant', 'Spark', '--role', 'reviewer', '--config', path.join(dir, 'config.toml'), '--cwd', dir, 'Check evidence'];
  const result = spawnSync(process.execPath, args, { env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { participant: 'Spark', model: 'gpt-5.3-codex-spark', role: 'reviewer', configuredModel: null, effort: 'medium', answer: 'Bounded answer' });
  assert.ok(JSON.parse(fs.readFileSync(env.CAPTURE)).includes('--ephemeral'));
  const mismatch = spawnSync(process.execPath, args, { env: { ...env, FAKE_MODEL: 'wrong-model' }, encoding: 'utf8' });
  assert.equal(mismatch.status, 1);
  assert.equal(mismatch.stdout, '');
  assert.match(mismatch.stderr, /could not be verified/);
  const wrongEffort = spawnSync(process.execPath, args, { env: { ...env, FAKE_EFFORT: 'low' }, encoding: 'utf8' });
  assert.equal(wrongEffort.status, 1);
  assert.equal(wrongEffort.stdout, '');
  assert.match(wrongEffort.stderr, /reasoning effort could not be verified/);
  const noRole = spawnSync(process.execPath, [cli.pathname, '--participant', 'Spark', '--cwd', dir, 'Bounded task'], { env, encoding: 'utf8' });
  assert.equal(noRole.status, 0, noRole.stderr);
  assert.equal(JSON.parse(noRole.stdout).effort, 'medium');
});
