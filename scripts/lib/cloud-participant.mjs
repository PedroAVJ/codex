import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Concrete defaults, never automatic routing aliases. Every successful answer must
// independently verify its model from the native response metadata below.
export const CLOUD_MODELS = Object.freeze({ Gemini: 'gemini-3.5-flash', Grok: 'grok-4.6' });
const GROK_EFFORTS = new Set(['low', 'medium', 'high', 'xhigh']);

export function buildCloudRequest({ participant, contract = null, prompt, cwd, effort, model, trustWorkspace = false }) {
  const name = Object.keys(CLOUD_MODELS).find(value => value.toLowerCase() === String(participant).toLowerCase());
  if (!name) throw new Error('Cloud helper requires explicit Gemini or Grok participant.');
  if (!prompt?.trim()) throw new Error('A bounded task prompt is required.');
  const config = contract?.role.config ?? {};
  const supported = new Set(['model', 'developer_instructions', 'model_reasoning_effort', 'agents']);
  const unsupported = Object.keys(config).filter(key => !supported.has(key));
  if (unsupported.length) throw new Error(`${name} adapter cannot preserve role settings: ${unsupported.join(', ')}. No model was launched.`);
  if (config.developer_instructions !== undefined && typeof config.developer_instructions !== 'string') throw new Error('Role developer_instructions must be a string.');
  if (config.agents !== undefined && (!config.agents || config.agents.enabled !== false || Object.keys(config.agents).some(key => key !== 'enabled'))) {
    throw new Error(`${name} adapter supports only individual roles with agents.enabled=false; delegated role contracts are not implemented.`);
  }
  if (effort && config.model_reasoning_effort && effort !== config.model_reasoning_effort) throw new Error('Explicit effort conflicts with the selected role; preserve its configured effort.');
  const effectiveEffort = effort ?? config.model_reasoning_effort ?? null;
  if (name === 'Gemini' && effectiveEffort) throw new Error(`Gemini CLI adapter cannot set exact reasoning effort ${effectiveEffort}; its CLI has no effort flag. No model was launched. Use Gemini without an effort-bound role, not a downgraded role.`);
  if (name === 'Grok' && effectiveEffort && !GROK_EFFORTS.has(effectiveEffort)) throw new Error(`Grok cannot represent configured reasoning effort ${effectiveEffort}; supported: low, medium, high, xhigh. No model was launched.`);
  const selectedModel = model ?? CLOUD_MODELS[name];
  if (name === 'Gemini' ? !/^gemini-[a-zA-Z0-9.-]+$/.test(selectedModel) : selectedModel !== CLOUD_MODELS.Grok) {
    throw new Error(`${name} requires a concrete supported native model ID; automatic aliases and custom providers are not accepted.`);
  }
  const rules = [config.developer_instructions,
    `You are the actual ${name} participant for this bounded task. Answer the assigned task directly; never impersonate another participant.`,
    'Work individually. Never spawn, contact, or delegate to other agents or threads. Do not create a sidebar task. Follow the task authorization and existing tool permissions.',
  ].filter(Boolean).join('\n\n');
  return {
    participant: name, model: selectedModel, role: contract?.role.key ?? null,
    configuredModel: config.model ?? null, effort: effectiveEffort,
    cwd: path.resolve(cwd), prompt: `${rules}\n\nTask:\n${prompt}`,
    command: process.env[name === 'Gemini' ? 'CODEX_GEMINI_BINARY' : 'CODEX_GROK_BINARY'] || name.toLowerCase(),
    args: name === 'Gemini'
      ? ['--model', selectedModel, '--output-format', 'stream-json', ...(trustWorkspace ? ['--skip-trust'] : []), '-p', 'Follow the bounded task provided on stdin.']
      : ['--cwd', path.resolve(cwd), '--model', selectedModel, '--output-format', 'streaming-messages-json', '--no-subagents', '--permission-mode', 'dontAsk', ...(effectiveEffort ? ['--reasoning-effort', effectiveEffort] : [])],
  };
}

export function parseGeminiResult(events, expectedModel) {
  const init = events.find(event => event.type === 'init');
  const result = events.findLast(event => event.type === 'result');
  if (init?.model !== expectedModel) throw new Error('Gemini startup model does not match the requested model.');
  if (result?.status !== 'success' || events.some(event => event.type === 'error' && event.severity !== 'warning')) throw new Error('Gemini returned an incomplete or failed result.');
  const usedModels = Object.keys(result.stats?.models ?? {});
  if (usedModels.length !== 1 || usedModels[0] !== expectedModel) throw new Error(`Gemini actual model could not be verified: requested ${expectedModel}, usage reports ${usedModels.join(', ') || 'no model'}. Refusing to label a fallback as the requested model.`);
  const answer = events.filter(event => event.type === 'message' && event.role === 'assistant').map(event => event.content ?? '').join('').trim();
  if (!answer) throw new Error('Gemini returned no answer.');
  return { model: usedModels[0], answer, usage: result.stats, modelVerification: 'native-usage-metadata' };
}

export function parseGrokResult(events, expectedModel) {
  const messages = events.filter(event => event.type === 'assistant' && event.message);
  const result = events.findLast(event => event.type === 'result');
  if (!result || result.is_error || (result.subtype && result.subtype !== 'success')) throw new Error('Grok returned an incomplete or failed result.');
  const usedModels = [...new Set(messages.map(event => event.message.model).filter(Boolean))];
  if (usedModels.length !== 1 || usedModels[0] !== expectedModel) throw new Error(`Grok actual model could not be verified from native message metadata; requested ${expectedModel}.`);
  const billedModels = Object.keys(result.modelUsage ?? {});
  if (billedModels.length && (billedModels.length !== 1 || billedModels[0] !== expectedModel)) throw new Error('Grok final model usage does not match the requested model.');
  const toolErrors = events.flatMap(event => event.message?.content ?? []).filter(part => part.is_error || part.content?.type?.endsWith('_tool_result_error')).map(part => ({ type: part.type, toolUseId: part.tool_use_id ?? null, errorCode: part.content?.error_code ?? 'tool_execution_failed' }));
  const lastMessage = messages.at(-1)?.message;
  const answer = (typeof result.result === 'string' ? result.result : lastMessage?.content?.filter(part => part.type === 'text').map(part => part.text).join('') ?? '').trim();
  if (!answer) throw new Error('Grok returned no answer.');
  return { model: usedModels[0], answer, usage: result.usage ?? null, toolErrors, modelVerification: 'native-message-metadata' };
}

export async function runCloudParticipant(request, { timeoutSeconds = 600, artifactRoot } = {}) {
  // Do not start a new sign-in or invalidate a pending device-code challenge.
  if (request.participant === 'Grok' && !process.env.XAI_API_KEY && !process.env.GROK_DEPLOYMENT_KEY && !fs.existsSync(path.join(os.homedir(), '.grok', 'auth.json'))) {
    const error = new Error('Grok CLI is installed but authentication is required. Complete the existing grok login challenge; this adapter never starts or restarts sign-in.');
    error.code = 'auth_required';
    throw error;
  }
  fs.mkdirSync(artifactRoot, { recursive: true, mode: 0o700 });
  const dir = fs.mkdtempSync(path.join(artifactRoot, `${request.participant.toLowerCase()}-`));
  try {
    const args = [...request.args];
    if (request.participant === 'Grok') {
      const promptFile = path.join(dir, 'prompt.txt');
      fs.writeFileSync(promptFile, request.prompt, { mode: 0o600 });
      args.push('--prompt-file', promptFile);
    }
    const result = await new Promise((resolve, reject) => {
      const child = spawn(request.command, args, { cwd: request.cwd, detached: process.platform !== 'win32', stdio: ['pipe', 'pipe', 'pipe'] });
      let stdout = '', stderr = '', failure = null;
      const kill = (signal = 'SIGTERM') => { try { if (process.platform !== 'win32') process.kill(-child.pid, signal); else child.kill(signal); } catch {} };
      const interrupt = () => { failure = 'Task interrupted.'; kill(); };
      process.once('SIGINT', interrupt); process.once('SIGTERM', interrupt);
      const timer = setTimeout(() => { failure = 'Task timed out and was terminated.'; kill('SIGKILL'); }, timeoutSeconds * 1000);
      child.stdout.on('data', chunk => { stdout += chunk; if (stdout.length > 8 * 1024 * 1024) { failure = 'Native output exceeded the bounded capture limit.'; kill('SIGKILL'); } });
      child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-8000); });
      child.stdin.on('error', () => {});
      child.stdin.end(request.participant === 'Gemini' ? request.prompt : undefined);
      const cleanup = () => { clearTimeout(timer); process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt); };
      child.on('error', error => { cleanup(); reject(new Error(`${request.participant} CLI unavailable: ${error.code ?? 'spawn failed'}. No alternate model was launched.`)); });
      child.on('close', code => { cleanup(); resolve({ code, stdout, stderr, failure }); });
    });
    if (result.failure) throw new Error(`${request.participant}: ${result.failure}`);
    if (result.code !== 0) throw new Error(`${request.participant} runtime failed (${result.code}): ${result.stderr.trim()}`);
    let events;
    try { events = result.stdout.split(/\r?\n/).filter(line => line.trim()).map(line => JSON.parse(line)); }
    catch { throw new Error(`${request.participant} did not return valid native JSON events.`); }
    const verified = request.participant === 'Gemini' ? parseGeminiResult(events, request.model) : parseGrokResult(events, request.model);
    return { participant: request.participant, requestedModel: request.model, role: request.role, configuredModel: request.configuredModel,
      effort: request.effort, effortVerification: request.effort ? 'native-cli-flag' : 'provider-default-unreported',
      delegation: request.participant === 'Grok' ? 'native-no-subagents-and-instructions' : 'instructions-only', ...verified };
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
