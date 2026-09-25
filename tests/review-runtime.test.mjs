import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const codexModule = fileURLToPath(new URL("../scripts/lib/codex.mjs", import.meta.url));

test("adversarial review turn remains read-only and returns structured output", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-review-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const binary = path.join(root, "fake-codex");
  const log = path.join(root, "requests.jsonl");
  fs.writeFileSync(binary, `#!${process.execPath}
const fs = require('node:fs');
const readline = require('node:readline');
if (process.argv.includes('--version')) { console.log('codex-cli 99.0.0'); process.exit(0); }
if (process.argv.includes('--help')) { console.log('app-server'); process.exit(0); }
const send = message => console.log(JSON.stringify(message));
readline.createInterface({input:process.stdin}).on('line', line => {
  const message = JSON.parse(line);
  fs.appendFileSync(process.env.TEST_REQUEST_LOG, line+'\\n');
  const {id, method, params} = message;
  if (id == null) return;
  let result = {};
  if (method === 'thread/start') result = {thread:{id:'fixture-thread'}};
  if (method === 'turn/start') result = {turn:{id:'fixture-turn',status:'inProgress'}};
  send({id,result});
  if (method === 'turn/start') {
    send({method:'item/completed',params:{threadId:params.threadId,turnId:'fixture-turn',item:{type:'agentMessage',phase:'final_answer',text:'{"summary":"Clean"}'}}});
    send({method:'turn/completed',params:{threadId:params.threadId,turn:{id:'fixture-turn',status:'completed'}}});
  }
});
`, { mode: 0o755 });

  const script = `import { runAppServerTurn } from ${JSON.stringify(codexModule)};
const result = await runAppServerTurn(${JSON.stringify(root)}, { prompt: "Review fixture", outputSchema: { type: "object" } });
console.log(JSON.stringify({ status: result.status, finalMessage: result.finalMessage }));`;
  const run = spawnSync(process.execPath, ["--input-type=module", "-e", script], {
    cwd: root,
    env: {
      ...process.env,
      CODEX_COMPANION_BINARY: binary,
      CODEX_COMPANION_APP_SERVER_ENDPOINT: `unix:${root}/absent.sock`,
      TEST_REQUEST_LOG: log
    },
    encoding: "utf8",
    timeout: 15000
  });
  assert.equal(run.status, 0, run.stderr);
  assert.deepEqual(JSON.parse(run.stdout), { status: 0, finalMessage: '{"summary":"Clean"}' });

  const requests = fs.readFileSync(log, "utf8").trim().split("\n").map(JSON.parse);
  const start = requests.find((request) => request.method === "thread/start").params;
  assert.equal(start.ephemeral, true);
  assert.equal(start.sandbox, "read-only");
  assert.equal(start.approvalPolicy, "never");
  const turn = requests.find((request) => request.method === "turn/start").params;
  assert.equal(turn.input[0].text, "Review fixture");
  assert.deepEqual(turn.outputSchema, { type: "object" });
});
