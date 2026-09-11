import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { buildCloudRequest, parseGeminiResult, parseGrokResult } from '../scripts/lib/cloud-participant.mjs';

const root = new URL('..', import.meta.url).pathname;
const cli = path.join(root, 'scripts/named-participant.mjs');
const role = config => ({ registry_file: '/fixture/config.toml', merges_config_layers: false, role: { key: 'reviewer', config } });
const geminiEvents = model => [
  { type: 'init', model },
  { type: 'message', role: 'assistant', content: 'Verified answer', delta: true },
  { type: 'result', status: 'success', stats: { models: { [model]: { output_tokens: 2 } } } },
];
const grokEvents = model => [
  { type: 'assistant', message: { model, content: [{ type: 'text', text: 'Verified answer' }] } },
  { type: 'result', subtype: 'success', is_error: false, result: 'Verified answer' },
];

test('cloud participants preserve exact supported roles and fail unsupported controls before launch', () => {
  const base = { cwd: root, prompt: 'Check this' };
  const request = buildCloudRequest({ ...base, participant: 'Grok', contract: role({ model: 'other', model_reasoning_effort: 'medium', developer_instructions: 'Read each claim.', agents: { enabled: false } }) });
  assert.equal(request.model, 'grok-4.6');
  assert.equal(request.configuredModel, 'other');
  assert.match(request.prompt, /Read each claim/);
  assert.ok(request.args.includes('--no-subagents'));
  assert.equal(request.args[request.args.indexOf('--reasoning-effort') + 1], 'medium');
  assert.ok(request.args.includes('dontAsk'));
  assert.ok(!request.args.includes('--always-approve'));
  for (const participant of ['Grok', 'Gemini']) {
    for (const config of [{ sandbox_mode: 'read-only' }, { approval_policy: 'never' }, { model_provider: 'custom' }, { agents: { enabled: true } }]) {
      assert.throws(() => buildCloudRequest({ ...base, participant, contract: role(config) }), /cannot preserve|individual roles/);
    }
  }
  assert.throws(() => buildCloudRequest({ ...base, participant: 'Gemini', contract: role({ model_reasoning_effort: 'medium' }) }), /cannot set exact reasoning effort/);
  assert.throws(() => buildCloudRequest({ ...base, participant: 'Grok', effort: 'max' }), /cannot represent/);
  assert.throws(() => buildCloudRequest({ ...base, participant: 'Grok', effort: 'low', contract: role({ model_reasoning_effort: 'high' }) }), /conflicts/);
  assert.throws(() => buildCloudRequest({ ...base, participant: 'Gemini', model: 'auto' }), /concrete/);
  assert.ok(!buildCloudRequest({ ...base, participant: 'Gemini' }).args.includes('--skip-trust'));
});

test('usage and native message metadata reject silent fallback, missing identity and failed responses', () => {
  const model = 'gemini-3.5-flash';
  assert.equal(parseGeminiResult(geminiEvents(model), model).answer, 'Verified answer');
  const fallback = geminiEvents(model);
  fallback[0].model = 'gemini-3.8-flash';
  assert.throws(() => parseGeminiResult(fallback, 'gemini-3.8-flash'), /usage reports gemini-3.5-flash/);
  assert.throws(() => parseGeminiResult(geminiEvents(model).slice(0, 2), model), /incomplete/);
  const noStats = geminiEvents(model); noStats.at(-1).stats = {};
  assert.throws(() => parseGeminiResult(noStats, model), /could not be verified/);
  assert.equal(parseGrokResult(grokEvents('grok-4.6'), 'grok-4.6').answer, 'Verified answer');
  assert.throws(() => parseGrokResult(grokEvents('wrong'), 'grok-4.6'), /could not be verified/);
  const failed = grokEvents('grok-4.6'); failed.at(-1).is_error = true;
  assert.throws(() => parseGrokResult(failed, 'grok-4.6'), /failed/);
  const mixed = grokEvents('grok-4.6'); mixed.at(-1).modelUsage = { other: {} };
  assert.throws(() => parseGrokResult(mixed, 'grok-4.6'), /final model usage/);
  const toolFailure = grokEvents('grok-4.6');
  toolFailure.unshift({ type: 'assistant', message: { model: 'grok-4.6', content: [{ type: 'web_search_tool_result', tool_use_id: 'test', content: { type: 'web_search_tool_result_error', error_code: 'unavailable' } }] } });
  assert.deepEqual(parseGrokResult(toolFailure, 'grok-4.6').toolErrors, [{ type: 'web_search_tool_result', toolUseId: 'test', errorCode: 'unavailable' }]);
});

test('public CLI returns attributed native answers, rejects fallback, and removes private prompt artifacts', t => {
  const artifactRoot = path.join(root, '.codex-artifacts');
  fs.mkdirSync(artifactRoot, { recursive: true });
  const dir = fs.mkdtempSync(path.join(artifactRoot, 'cloud-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const fake = path.join(dir, 'provider');
  fs.writeFileSync(fake, `#!/usr/bin/env node
const fs = require('fs');
const args = process.argv.slice(2);
fs.writeFileSync(process.env.CAPTURE, JSON.stringify(args));
if(process.env.HANG) { setInterval(()=>{},1000); } else {
  process.stdin.resume(); process.stdin.on('end',()=> {
    process.stdout.write(process.env.EVENTS);
  });
}
`);
  fs.chmodSync(fake, 0o700);
  for (const participant of ['Gemini', 'Grok']) {
    const model = participant === 'Gemini' ? 'gemini-3.5-flash' : 'grok-4.6';
    const events = participant === 'Gemini' ? geminiEvents(model) : grokEvents(model);
    const env = { ...process.env, CODEX_GEMINI_BINARY: fake, CODEX_GROK_BINARY: fake, XAI_API_KEY: 'fixture-not-a-real-key', CAPTURE: path.join(dir, 'args.json'), EVENTS: events.map(x => JSON.stringify(x)).join('\n') };
    const args = [cli, '--participant', participant, '--cwd', dir, 'Bounded task'];
    const result = spawnSync(process.execPath, args, { env, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    const value = JSON.parse(result.stdout);
    assert.equal(value.model, model);
    assert.equal(value.participant, participant);
    assert.equal(value.answer, 'Verified answer');
    assert.deepEqual(fs.readdirSync(path.join(dir, '.codex-artifacts/named-participants')), []);
    if (participant === 'Grok') {
      const called = JSON.parse(fs.readFileSync(env.CAPTURE));
      assert.ok(called.includes('--prompt-file'));
      assert.ok(!called.includes('Bounded task'));
    }
    const timedOut = spawnSync(process.execPath, [...args, '--timeout-seconds', '0.05'], { env: { ...env, HANG: '1' }, encoding: 'utf8', timeout: 2000 });
    assert.equal(timedOut.status, 1, timedOut.stderr);
    assert.match(timedOut.stderr, /timed out/);
    assert.deepEqual(fs.readdirSync(path.join(dir, '.codex-artifacts/named-participants')), []);
  }
});
