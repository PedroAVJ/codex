import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const SPARK_MODEL = 'gpt-5.3-codex-spark';
const EFFORTS = new Set(['low', 'medium', 'high', 'xhigh']);
const ROLE_READER = fileURLToPath(new URL('../../skills/sub-agents/scripts/read-roles.py', import.meta.url));

export function readRoleContract({ contract, role, config }) {
  if (contract && (role || config)) throw new Error('Use --role-contract or --role/--config, not both.');
  if (config && !role) throw new Error('--config requires --role.');
  if (!contract && !role) return null;
  let value;
  if (contract) {
    try { value = JSON.parse(fs.readFileSync(contract, 'utf8')); }
    catch { throw new Error('Cannot read selected role contract JSON.'); }
  } else {
    const result = spawnSync('python3', [ROLE_READER, '--role', role, ...(config ? ['--config', config] : [])], {
      encoding: 'utf8', timeout: 10000, maxBuffer: 2 * 1024 * 1024,
      env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' },
    });
    if (result.status !== 0) throw new Error('Cannot resolve selected role; inspect the registry with read-roles.py.');
    value = JSON.parse(result.stdout);
  }
  if (!value || typeof value.registry_file !== 'string' || value.merges_config_layers !== false ||
      !value.role || typeof value.role.key !== 'string' || !value.role.key ||
      !value.role.config || typeof value.role.config !== 'object' || Array.isArray(value.role.config)) {
    throw new Error('Expected a selected read-roles.py role contract.');
  }
  return value;
}

function toml(value) {
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'boolean' || (typeof value === 'number' && Number.isFinite(value))) return String(value);
  if (Array.isArray(value)) return `[${value.map(toml).join(', ')}]`;
  if (value && typeof value === 'object') return `{ ${Object.entries(value).map(([key, item]) => `${JSON.stringify(key)} = ${toml(item)}`).join(', ')} }`;
  throw new Error('Role contains a value that cannot be represented as TOML.');
}

export function buildSparkRequest({ participant, contract = null, prompt, cwd, effort }) {
  if (String(participant).toLowerCase() !== 'spark') throw new Error('This helper requires explicit --participant Spark. Codex stays in the current assistant; Claude/Fable uses its own runtime.');
  if (!prompt?.trim()) throw new Error('A bounded task prompt is required.');
  const config = { ...(contract?.role.config ?? {}) };
  if (effort && config.model_reasoning_effort && effort !== config.model_reasoning_effort) {
    throw new Error('Explicit effort conflicts with the selected role; preserve its configured effort.');
  }
  const effectiveEffort = effort ?? config.model_reasoning_effort ?? null;
  if (effectiveEffort && !EFFORTS.has(effectiveEffort)) {
    throw new Error(`Spark cannot represent configured reasoning effort ${effectiveEffort}; supported: low, medium, high, xhigh. No model was launched.`);
  }
  // Participant selection wins model identity only; preserve all other runtime controls.
  if (config.model_provider || config.model_providers) throw new Error('Named Spark cannot change model provider.');
  delete config.model;
  if (effectiveEffort) config.model_reasoning_effort = effectiveEffort;
  if (config.developer_instructions !== undefined && typeof config.developer_instructions !== 'string') throw new Error('Role developer_instructions must be a string.');
  if (config.agents !== undefined && (!config.agents || typeof config.agents !== 'object' || Array.isArray(config.agents))) throw new Error('Role agents must be a table.');
  const identity = 'You are the actual Spark participant selected for this bounded task. Answer the assigned task directly. A participant name selects its actual model independently of the role. Unnamed user turns address Codex, the main assistant. Do not impersonate or silently substitute another participant.';
  const delegation = config.agents?.enabled === false
    ? 'This role must work individually. Never spawn, contact, or delegate to other agents or threads.'
    : 'Follow the selected role delegation constraints. Never create a separate sidebar task unless the user explicitly requested that mechanism.';
  config.developer_instructions = [config.developer_instructions, identity, delegation].filter(Boolean).join('\n\n');
  const args = ['exec', '--ephemeral', '--skip-git-repo-check', '--color', 'never', '--strict-config', '--cd', path.resolve(cwd), '--model', SPARK_MODEL];
  const apply = (table, prefix = []) => {
    for (const [key, value] of Object.entries(table)) {
      if (!/^[A-Za-z0-9_-]+$/.test(key)) throw new Error('Role contains a config key unsupported by the CLI override syntax.');
      const keys = [...prefix, key];
      if (value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length) apply(value, keys);
      else args.push('-c', `${keys.join('.')}=${toml(value)}`);
    }
  };
  apply(config);
  return { args, prompt, participant: 'Spark', model: SPARK_MODEL, role: contract?.role.key ?? null, configuredModel: contract?.role.config.model ?? null, effort: effectiveEffort };
}

export function verifySparkMetadata(stderr) {
  const model = stderr.match(/^model:\s*(\S+)\s*$/m)?.[1];
  if (model !== SPARK_MODEL) throw new Error('Spark runtime model could not be verified from CLI startup metadata; refusing to label the response as Spark.');
  return model;
}
