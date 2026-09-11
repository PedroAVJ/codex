#!/usr/bin/env node
// Explicit named Spark dispatch, separate from Claude's guarded rescue companion.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { resolveCodexBinary } from './lib/codex-binary.mjs';
import { buildSparkRequest, readRoleContract, verifySparkMetadata } from './lib/named-participant.mjs';
import { buildCloudRequest, runCloudParticipant } from './lib/cloud-participant.mjs';

async function main() {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: {
    participant: { type: 'string' }, 'role-contract': { type: 'string' }, role: { type: 'string' }, config: { type: 'string' },
    cwd: { type: 'string', default: process.cwd() }, effort: { type: 'string' }, model: { type: 'string' }, 'trust-workspace': { type: 'boolean' },
    'prompt-file': { type: 'string' }, 'timeout-seconds': { type: 'string', default: '600' }, help: { type: 'boolean' },
  } });
  if (values.help) {
    console.log('Usage: node scripts/named-participant.mjs --participant Spark|Gemini|Grok [--role-contract FILE | --role KEY [--config REGISTRY]] [--cwd DIR] [--effort LEVEL] [--model GEMINI_MODEL] [--trust-workspace] [--prompt-file FILE | PROMPT]\nReturns JSON with actual model, role, effort verification, and answer. Gemini uses native CLI default effort; incompatible role settings fail before launch. No implicit participant or persistent sidebar task.');
    return;
  }
  if (values['prompt-file'] && positionals.length) throw new Error('Use --prompt-file or a prompt, not both.');
  const prompt = values['prompt-file'] ? fs.readFileSync(values['prompt-file'], 'utf8') : positionals.join(' ');
  const contract = readRoleContract({ contract: values['role-contract'], role: values.role, config: values.config });
  const timeout = Number(values['timeout-seconds']);
  if (!Number.isFinite(timeout) || timeout <= 0 || timeout > 3600) throw new Error('Timeout must be between 0 and 3600 seconds.');
  if (['gemini', 'grok'].includes(values.participant?.toLowerCase())) {
    const request = buildCloudRequest({ participant: values.participant, contract, prompt, cwd: values.cwd, effort: values.effort, model: values.model, trustWorkspace: values['trust-workspace'] });
    console.log(JSON.stringify(await runCloudParticipant(request, { timeoutSeconds: timeout, artifactRoot: path.resolve(values.cwd, '.codex-artifacts', 'named-participants') })));
    return;
  }
  if (values.model || values['trust-workspace']) throw new Error('--model and --trust-workspace are cloud participant options; Spark preserves its existing runtime contract.');
  const request = buildSparkRequest({ participant: values.participant, contract, prompt, cwd: values.cwd, effort: values.effort });
  const binary = resolveCodexBinary({ cwd: values.cwd });
  if (!binary.available) throw new Error('Codex CLI unavailable; no alternate model was launched.');
  const artifactRoot = path.resolve(values.cwd, '.codex-artifacts', 'named-participants');
  fs.mkdirSync(artifactRoot, { recursive: true, mode: 0o700 });
  const dir = fs.mkdtempSync(path.join(artifactRoot, 'spark-'));
  const output = path.join(dir, 'answer.txt');
  try {
    const result = await new Promise((resolve, reject) => {
      const child = spawn(binary.command, [...request.args, '--output-last-message', output, '-'], {
        cwd: values.cwd, detached: process.platform !== 'win32', stdio: ['pipe', 'ignore', 'pipe'],
      });
      let stderr = '';
      let metadata = '';
      let timedOut = false;
      const kill = (signal = 'SIGTERM') => {
        try { if (process.platform !== 'win32') process.kill(-child.pid, signal); else child.kill(signal); } catch {}
      };
      const interrupt = () => kill('SIGTERM');
      process.once('SIGINT', interrupt);
      process.once('SIGTERM', interrupt);
      const timer = setTimeout(() => { timedOut = true; kill('SIGKILL'); }, timeout * 1000);
      child.stderr.on('data', chunk => { if (metadata.length < 16000) metadata += String(chunk).slice(0, 16000 - metadata.length); stderr = (stderr + chunk).slice(-16000); });
      child.stdin.on('error', () => {});
      child.stdin.end(request.prompt);
      const cleanup = () => { clearTimeout(timer); process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt); };
      child.on('error', error => { cleanup(); reject(error); });
      child.on('close', code => { cleanup(); resolve({ code, stderr, metadata, timedOut }); });
    });
    if (result.timedOut) throw new Error('Spark task timed out and was terminated.');
    if (result.code !== 0) throw new Error(`Spark runtime failed (${result.code}): ${result.stderr.trim()}`);
    const verifiedModel = verifySparkMetadata(result.metadata);
    const actualEffort = result.metadata.match(/^reasoning effort:\s*(\S+)\s*$/m)?.[1];
    if (!actualEffort || (request.effort && actualEffort !== request.effort)) throw new Error('Spark runtime reasoning effort could not be verified against the selected role.');
    const answer = fs.readFileSync(output, 'utf8').trim();
    if (!answer) throw new Error('Spark returned no final answer.');
    console.log(JSON.stringify({ participant: request.participant, model: verifiedModel, role: request.role, configuredModel: request.configuredModel, effort: actualEffort, answer }));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
main().catch(error => { console.error(JSON.stringify({ error: error.message, ...(error.code ? { code: error.code } : {}) })); process.exitCode = 1; });
