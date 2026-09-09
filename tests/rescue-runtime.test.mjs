import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { resolveTaskWorkspace } from '../scripts/lib/workspace.mjs';

const helper = fileURLToPath(new URL('../scripts/codex-companion.mjs', import.meta.url));
const lifecycleHook = fileURLToPath(new URL('../scripts/session-lifecycle-hook.mjs', import.meta.url));

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rescue-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const binary = path.join(root, 'fake-codex');
  const log = path.join(root, 'requests.jsonl');
  fs.writeFileSync(binary, `#!${process.execPath}
const fs = require('node:fs');
const readline = require('node:readline');
if (process.argv.includes('--version')) { console.log('codex-cli 99.0.0'); process.exit(0); }
if (process.argv.includes('--help')) { console.log('app-server'); process.exit(0); }
const send = (message) => console.log(JSON.stringify(message));
readline.createInterface({input:process.stdin}).on('line', (line) => {
 const message = JSON.parse(line);
 fs.appendFileSync(process.env.TEST_REQUEST_LOG, line+'\\n');
 const {id, method, params} = message;
 if (id == null) return;
 const archived = process.env.TEST_REQUEST_LOG+'.archived';
 if (method === 'thread/resume') {
   if (process.env.TEST_RESUME_ERROR === 'unrelated') {
     send({id,error:{code:-32000,message:'fixture unrelated resume failure'}}); return;
   }
   if (fs.existsSync(archived)) {
     send({id,error:{code:-32000,message:'session fixture-thread is archived. Run codex unarchive fixture-thread to unarchive it first.'}}); return;
   }
   if (process.env.TEST_RESUME_ERROR === 'after-unarchive') {
     send({id,error:{code:-32000,message:'fixture resume retry failed'}}); return;
   }
 }
 if (method === 'thread/unarchive') fs.rmSync(archived,{force:true});
 if (method === 'turn/start' && process.env.TEST_TURN_ERROR) {
   send({id,error:{code:-32000,message:'fixture turn rejected'}}); return;
 }
 if (method === 'thread/archive' && process.env.TEST_ARCHIVE_ERROR) {
   send({id,error:{code:-32000,message:'fixture archive rejected'}}); return;
 }
 if (method === 'thread/archive') fs.writeFileSync(archived,'archived');
 let result = {};
 if (method === 'thread/start' || method === 'thread/resume') result = {thread:{id:params.threadId || 'fixture-thread'}};
 if (method === 'turn/start') result = {turn:{id:'fixture-turn',status:'inProgress'}};
 send({id,result});
 if (method === 'turn/start') {
   send({method:'item/completed',params:{threadId:params.threadId,turnId:'fixture-turn',item:{type:'agentMessage',phase:'final_answer',text:'Fixture answer'}}});
   send({method:'turn/completed',params:{threadId:params.threadId,turn:{id:'fixture-turn',status:'completed'}}});
 }
});
`, { mode: 0o755 });
  const env = {
    ...process.env,
    CLAUDECODE: '1', // Hermetic forwarder test; all model RPCs go to the fixture.
    CLAUDE_PLUGIN_DATA: path.join(root, 'plugin-data'),
    CODEX_COMPANION_SESSION_ID: 'fixture-session',
    CODEX_COMPANION_BINARY: binary,
    CODEX_COMPANION_APP_SERVER_ENDPOINT: `unix:${root}/absent.sock`,
    TEST_REQUEST_LOG: log
  };
  return {
    root,
    env,
    end(cwd = root) {
      return spawnSync(process.execPath, [lifecycleHook, 'SessionEnd'], {
        cwd:root, env:{...env, CODEX_COMPANION_APP_SERVER_ENDPOINT:''},
        input:JSON.stringify({cwd,session_id:'fixture-session'}),
        encoding:'utf8', timeout:5000
      });
    },
    run(args, overrides = {}) {
      fs.writeFileSync(log, '');
      const result = spawnSync(process.execPath, [helper, 'task', ...args], {
        cwd: root, env: {...env, ...overrides}, encoding: 'utf8', timeout: 15000
      });
      const requests = fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
      return {...result, requests};
    }
  };
}

test('wait stays out of the prompt; writes inherit saved permissions and archive; resume retains the identity', (t) => {
  const f = fixture(t);
  const fresh = f.run(['--wait', '--write', 'Solve the fixture']);
  assert.equal(fresh.status, 0, fresh.stderr);
  assert.match(fresh.stdout, /Fixture answer/);
  const start = fresh.requests.find(r => r.method === 'thread/start').params;
  assert.equal(start.ephemeral, false);
  assert.equal('sandbox' in start, false);
  assert.equal('approvalPolicy' in start, false);
  assert.equal(fresh.requests.find(r => r.method === 'turn/start').params.input[0].text, 'Solve the fixture');
  assert.equal(fresh.requests.at(-1).method, 'thread/archive');

  const ended = f.end();
  assert.equal(ended.status, 0, ended.stderr);
  const resumed = f.run(['--wait', '--write', '--resume-last', 'Continue fixture']);
  assert.equal(resumed.status, 0, resumed.stderr);
  const resume = resumed.requests.find(r => r.method === 'thread/resume').params;
  assert.equal(resume.threadId, 'fixture-thread');
  assert.equal('sandbox' in resume, false);
  assert.equal('approvalPolicy' in resume, false);
  assert.equal(resumed.requests.at(-1).method, 'thread/archive');
  assert.deepEqual(resumed.requests.filter(r => ['thread/resume','thread/unarchive'].includes(r.method)).map(r => r.method), ['thread/resume','thread/unarchive','thread/resume']);
});

test('diagnosis remains read-only and a rejected turn still archives its helper thread', (t) => {
  const f = fixture(t);
  const result = f.run(['--wait', 'Diagnose fixture'], {TEST_TURN_ERROR: '1'});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /fixture turn rejected/);
  const start = result.requests.find(r => r.method === 'thread/start').params;
  assert.equal(start.sandbox, 'read-only');
  assert.equal(start.approvalPolicy, 'never');
  assert.equal(result.requests.at(-1).method, 'thread/archive');
  const ended = f.end();
  assert.equal(ended.status, 0, ended.stderr);
  const resumed = f.run(['--wait', '--resume-last', 'Continue failed fixture']);
  assert.equal(resumed.status, 0, resumed.stderr);
  assert.equal(resumed.requests.find(r => r.method === 'thread/resume').params.threadId, 'fixture-thread');
});

test('archive failure preserves the answer and reports cleanup failure', (t) => {
  const f = fixture(t);
  const result = f.run(['--wait', 'Answer fixture'], {TEST_ARCHIVE_ERROR: '1'});
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Fixture answer/);
  assert.match(result.stderr, /Could not archive helper thread.*fixture archive rejected/);
});

test('conflicting execution flags fail before invoking Codex', (t) => {
  const f = fixture(t);
  const result = f.run(['--wait', '--background', 'Answer fixture']);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Choose either --wait or --background/);
  assert.equal(result.requests.length, 0);
});

test('broad default directories get a stable per-session workspace; explicit and concrete cwd stay exact', (t) => {
  const homeDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rescue-home-'));
  t.after(() => fs.rmSync(homeDir, { recursive: true, force: true }));
  const options = {homeDir, env:{CLAUDE_PLUGIN_DATA:path.join(homeDir, 'data'), CODEX_COMPANION_SESSION_ID:'one'}};
  const broad = path.join(homeDir, 'Developer');
  fs.mkdirSync(broad);
  const isolated = resolveTaskWorkspace(broad, options);
  assert.notEqual(isolated, broad);
  assert.ok(fs.statSync(isolated).isDirectory());
  assert.equal(resolveTaskWorkspace(broad, options), isolated);
  assert.notEqual(resolveTaskWorkspace(broad, {...options,env:{...options.env,CODEX_COMPANION_SESSION_ID:'two'}}), isolated);
  assert.equal(resolveTaskWorkspace(broad, {...options, explicitCwd:true}), broad);
  const concrete = path.join(homeDir, 'Desktop', 'repository', 'nested-task');
  assert.equal(resolveTaskWorkspace(concrete, options), concrete);
});


test('session end removes only its transient jobs and keeps resumable task artifacts', (t) => {
  const f = fixture(t);
  assert.equal(f.run(['--wait', 'Answer fixture']).status, 0);
  const stateDir = path.join(f.root, 'plugin-data', 'state', fs.readdirSync(path.join(f.root, 'plugin-data', 'state'))[0]);
  const stateFile = path.join(stateDir, 'state.json');
  const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  const durable = state.jobs[0];
  const transientFile = path.join(stateDir, 'jobs', 'queued-fixture.json');
  const transientLog = path.join(stateDir, 'jobs', 'queued-fixture.log');
  fs.writeFileSync(transientFile, '{}');
  fs.writeFileSync(transientLog, 'transient');
  state.jobs.push({id:'queued-fixture',jobClass:'task',sessionId:'fixture-session',status:'queued',pid:null,logFile:transientLog});
  state.jobs.push({id:'other-session',jobClass:'task',sessionId:'other-session',status:'running',pid:null});
  fs.writeFileSync(stateFile, JSON.stringify(state));
  const ended = f.end();
  assert.equal(ended.status, 0, ended.stderr);
  const remaining = JSON.parse(fs.readFileSync(stateFile, 'utf8')).jobs;
  assert.ok(remaining.some(job => job.id === durable.id));
  assert.ok(remaining.some(job => job.id === 'other-session'));
  assert.ok(!remaining.some(job => job.id === 'queued-fixture'));
  assert.ok(fs.existsSync(path.join(stateDir, 'jobs', `${durable.id}.json`)));
  assert.equal(fs.existsSync(transientFile), false);
  assert.equal(fs.existsSync(transientLog), false);
});

test('session end also tears down the exact session isolated workspace broker', (t) => {
  const f = fixture(t);
  const broadCwd = os.homedir();
  const isolated = resolveTaskWorkspace(broadCwd, {env:f.env});
  const brokerModule = new URL('../scripts/lib/broker-lifecycle.mjs', import.meta.url).href;
  const seed = spawnSync(process.execPath, ['--input-type=module', '-e', `
    import {saveBrokerSession} from ${JSON.stringify(brokerModule)};
    saveBrokerSession(process.env.TEST_ISOLATED_CWD, {endpoint:'unix:'+process.env.TEST_ISOLATED_CWD+'/absent.sock',pid:null});
  `], {cwd:f.root,env:{...f.env,TEST_ISOLATED_CWD:isolated},encoding:'utf8'});
  assert.equal(seed.status, 0, seed.stderr);
  const stateRoot = path.join(f.root, 'plugin-data', 'state');
  const brokerFile = path.join(stateRoot, fs.readdirSync(stateRoot)[0], 'broker.json');
  assert.ok(fs.existsSync(brokerFile));
  const ended = f.end(broadCwd);
  assert.equal(ended.status, 0, ended.stderr);
  assert.equal(fs.existsSync(brokerFile), false);
});


test('a failed unarchived resume retry is archived again; unrelated resume errors are not retried', (t) => {
  const f = fixture(t);
  assert.equal(f.run(['--wait', 'Answer fixture']).status, 0);
  const failed = f.run(['--wait', '--resume-last', 'Continue fixture'], {TEST_RESUME_ERROR:'after-unarchive'});
  assert.equal(failed.status, 1);
  assert.match(failed.stderr, /fixture resume retry failed/);
  assert.deepEqual(failed.requests.filter(r => r.method.startsWith('thread/')).map(r => r.method), ['thread/resume','thread/unarchive','thread/resume','thread/archive']);
  const unrelated = f.run(['--wait', '--resume-last', 'Continue fixture'], {TEST_RESUME_ERROR:'unrelated'});
  assert.equal(unrelated.status, 1);
  assert.match(unrelated.stderr, /fixture unrelated resume failure/);
  assert.deepEqual(unrelated.requests.filter(r => r.method.startsWith('thread/')).map(r => r.method), ['thread/resume']);
});
