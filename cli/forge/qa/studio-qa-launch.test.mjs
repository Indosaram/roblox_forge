import { test, expect } from 'bun:test';
import {
  QA_TASK_PREFIX,
  assertOutputsFree,
  assertRunnerInput,
  isOwnedTask,
  isPathInsideRoot,
  normalizeWindowsPath,
  ownedTaskNames,
  launchOwnedRun,
  registerTaskScript,
  retireOwnedTasks,
  runPaths,
  windowsSchedulerDeps,
} from './studio-qa-launch.mjs';

const ROOT = 'C:/work/forge-release';
const BAT = `${ROOT}/.omo/evidence/x/run.bat`;
const scope = { root: ROOT, user: 'qa-owner' };
const owned = name => ({
  name, author: 'QA-HOST\\qa-owner', triggers: 0,
  commands: [`cmd.exe /c "${ROOT}/.omo/evidence/x/run.bat"`],
});

function recordingDeps(overrides = {}) {
  const calls = [];
  const deps = {
    taskQuery: async () => { calls.push('query'); return null; },
    taskCreate: async () => { calls.push('create'); return owned('ForgeQAOrder'); },
    taskRun: async () => { calls.push('run'); },
    waitForStart: async () => { calls.push('start'); },
    waitForTerminal: async () => { calls.push('terminal'); },
    taskDelete: async () => { calls.push('delete'); },
    // The runner batch exists; any other path (the run's outputs) does not.
    exists: p => p === BAT,
    ...overrides,
  };
  return { calls, deps };
}

// The runner is the task's INPUT and must already exist. Requiring it to be absent (as an earlier version
// did by folding it into the output list) makes every launch impossible.
test('the runner batch must exist and be inside the worktree, and is never treated as an output', async () => {
  expect(() => assertRunnerInput(BAT, ROOT, () => true)).not.toThrow();
  expect(() => assertRunnerInput(BAT, ROOT, () => false)).toThrow('QA_LAUNCH_BAT_MISSING');
  expect(() => assertRunnerInput('C:/elsewhere/run.bat', ROOT, () => true)).toThrow('QA_LAUNCH_BAT_OUTSIDE_ROOT');
  expect(() => assertRunnerInput('', ROOT, () => true)).toThrow('QA_LAUNCH_BAT_REQUIRED');

  // A real launch: the batch EXISTS and the outputs do not. This must succeed - the previous contract
  // made it impossible by demanding the batch be absent.
  const { calls, deps } = recordingDeps();
  const result = await launchOwnedRun(
    { taskName: 'ForgeQAOrder', root: ROOT, user: 'qa-owner', inputBat: BAT, outputPaths: [`${ROOT}/o.log`, `${ROOT}/o.meta`, `${ROOT}/o.json`] },
    deps,
  );
  expect(result.ok).toBe(true);
  expect(calls).toEqual(['query', 'create', 'run', 'start', 'terminal', 'delete']);
});

// Outputs must be free; a taken output is refused before any task exists.
test('a taken output path is refused before a task is created', async () => {
  const taken = `${ROOT}/o.json`;
  expect(() => assertOutputsFree([taken], p => p === taken)).toThrow('QA_LAUNCH_OUTPUT_EXISTS:' + taken);
  const { calls, deps } = recordingDeps({ exists: p => p === BAT || p === taken });
  const result = await launchOwnedRun(
    { taskName: 'ForgeQAOrder', root: ROOT, user: 'qa-owner', inputBat: BAT, outputPaths: [taken] },
    deps,
  );
  expect(result.ok).toBe(false);
  expect(result.failure).toContain('QA_LAUNCH_OUTPUT_EXISTS');
  // The batch is present, so the refusal is specifically about the taken OUTPUT path.
  expect(result.failure).not.toContain('QA_LAUNCH_BAT_MISSING');
  expect(calls).toEqual([]);
});

// The registered task must have NO triggers: that is what makes a re-fire structurally impossible. The
// assertion is on the real registration script the adapter runs, not on a fake stage order.
test('the real registration script creates a triggerless interactive demand task', () => {
  const script = registerTaskScript({ taskName: 'ForgeQAReal', batPath: BAT, user: 'qa-owner' });
  expect(script).not.toContain('New-ScheduledTaskTrigger');
  expect(script).not.toContain('-Trigger');
  expect(script).toContain('Register-ScheduledTask');
  expect(script).toContain("-LogonType Interactive");
  expect(script).toContain('-RunLevel Limited');
  expect(script).toContain("TRIGGERS: ");
  // The action points at the runner batch, quoted.
  expect(script).toContain('/c "' + BAT + '"');
  // A single quote in a path must not break out of the PowerShell literal.
  const quoted = registerTaskScript({ taskName: "ForgeQAO'brien", batPath: BAT, user: 'qa-owner' });
  expect(quoted).toContain("ForgeQAO''brien");
});

// A task that came back with triggers, or without the action inside the worktree, must be refused - the
// guard is what keeps the no-re-fire property from being silently lost.
test('a task with triggers is refused, and no disable is ever issued', async () => {
  const { calls, deps } = recordingDeps({
    taskCreate: async () => { calls.push('create'); return { ...owned('ForgeQAOrder'), triggers: 1 }; },
  });
  const result = await launchOwnedRun(
    { taskName: 'ForgeQAOrder', root: ROOT, user: 'qa-owner', inputBat: BAT, outputPaths: ['o'] },
    deps,
  );
  expect(result.ok).toBe(false);
  expect(result.failure).toContain('QA_LAUNCH_TASK_HAS_TRIGGERS');
  // Refused after create, so the task is still retired; and nothing disabled anything.
  expect(calls).toEqual(['query', 'create', 'delete']);
  expect(calls).not.toContain('disable');
});

// The real adapter must never issue a disable: `schtasks /change /disable` disables the whole task, and a
// disabled task refuses to start. Asserted on the actual command stream.
test('the real adapter never disables the task it is about to start', async () => {
  const calls = [];
  const run = async args => {
    const script = args[args.length - 1];
    calls.push(script);
    if (script.includes('AUTHOR:')) {
      return { code: 0, stdout: `AUTHOR: QA-HOST\\qa-owner\nACTION: cmd.exe /c "${BAT}"\nTRIGGERS: 0\nSTATE: Ready` };
    }
    return { code: 0, stdout: 'Running' };
  };
  const deps = windowsSchedulerDeps({ root: ROOT, run, sleep: async () => {}, now: () => 0 });
  const task = await deps.taskCreate({ taskName: 'ForgeQAReal', batPath: BAT, user: 'qa-owner' });
  expect(task.triggers).toBe(0);
  await deps.taskRun('ForgeQAReal');
  expect(calls.some(script => /-Trigger\b/.test(script))).toBe(false);
  expect(calls.some(script => /\/disable|Disable-ScheduledTask/.test(script))).toBe(false);
  expect(calls.some(script => script.includes('Start-ScheduledTask'))).toBe(true);
});

// A create that does not verify back with the action inside the worktree must fail closed.
test('a create that cannot be verified fails closed', async () => {
  const deps = windowsSchedulerDeps({ root: ROOT, run: async () => ({ code: 0, stdout: '' }), sleep: async () => {}, now: () => 0 });
  await expect(deps.taskCreate({ taskName: 'ForgeQAReal', batPath: BAT, user: 'qa-owner' })).rejects.toThrow('QA_LAUNCH_TASK_CREATE_UNVERIFIED');
});

test('a delete failure is reported rather than swallowed', async () => {
  const { deps } = recordingDeps({ taskDelete: async () => { throw new Error('access denied'); } });
  const result = await launchOwnedRun(
    { taskName: 'ForgeQAOrder', root: ROOT, user: 'qa-owner', inputBat: BAT, outputPaths: ['o'] },
    deps,
  );
  expect(result.ok).toBe(false);
  expect(result.deleteFailure).toBe('access denied');
  expect(result.stages).toContain('delete-failed');
});

test('a create failure never deletes a task', async () => {
  const { calls, deps } = recordingDeps({ taskCreate: async () => { calls.push('create'); throw new Error('QA_LAUNCH_TASK_CREATE_FAILED:1'); } });
  const result = await launchOwnedRun(
    { taskName: 'ForgeQAOrder', root: ROOT, user: 'qa-owner', inputBat: BAT, outputPaths: ['o'] },
    deps,
  );
  expect(result.ok).toBe(false);
  expect(calls).toEqual(['query', 'create']);
  expect(calls).not.toContain('delete');
});

// A run can finish faster than the first state sample, so `Running` may never be observed. That is a
// lifecycle non-observation, not a launch failure: the task is still retired and the launch reports the
// unobserved start rather than a false timeout.
test('a run that never shows Running is retired, not failed as a launch', async () => {
  const { calls, deps } = recordingDeps({ waitForStart: async () => { calls.push('start'); throw new Error('QA_LAUNCH_STATE_TIMEOUT:ForgeQAOrder:Queued'); } });
  const result = await launchOwnedRun(
    { taskName: 'ForgeQAOrder', root: ROOT, user: 'qa-owner', inputBat: BAT, outputPaths: ['o'] },
    deps,
  );
  expect(result.ok).toBe(true);
  expect(result.lifecycleOk).toBe(true);
  expect(result.stages).toContain('start-unobserved');
  expect(calls).toEqual(['query', 'create', 'run', 'start', 'terminal', 'delete']);
});

// The task reaching a terminal state only says the scheduler finished. When a receipt path is declared, the
// run's own completion receipt is the QA verdict: a receipt that says the run failed is not a good launch.
test('a receipt that reports a failed run is not a successful launch', async () => {
  const { deps } = recordingDeps({ readReceipt: async () => ({ ok: false, failure: 'scenario FAIL collect-raid:hud-visual' }) });
  const result = await launchOwnedRun(
    { taskName: 'ForgeQAOrder', root: ROOT, user: 'qa-owner', inputBat: BAT, outputPaths: ['o'], receiptPath: `${ROOT}/o.json` },
    deps,
  );
  expect(result.lifecycleOk).toBe(true);
  expect(result.qaOk).toBe(false);
  expect(result.ok).toBe(false);
  expect(result.failure).toContain('QA_RUN_FAILED');
  expect(result.stages).toContain('receipt');
});

// An absent receipt is a QA failure, not a lifecycle one, and it must never read as success.
test('a missing receipt is reported as a QA failure', async () => {
  const { deps } = recordingDeps({ readReceipt: async () => null });
  const result = await launchOwnedRun(
    { taskName: 'ForgeQAOrder', root: ROOT, user: 'qa-owner', inputBat: BAT, outputPaths: ['o'], receiptPath: `${ROOT}/o.json`, receiptTimeoutMs: 1 },
    deps,
  );
  expect(result.lifecycleOk).toBe(true);
  expect(result.qaOk).toBe(false);
  expect(result.ok).toBe(false);
  expect(result.failure).toContain('receipt-missing');
});

// A receipt whose run succeeded is a successful launch.
test('a receipt that reports a passing run is a successful launch', async () => {
  const { deps } = recordingDeps({ readReceipt: async () => ({ ok: true, outcome: { ok: true } }) });
  const result = await launchOwnedRun(
    { taskName: 'ForgeQAOrder', root: ROOT, user: 'qa-owner', inputBat: BAT, outputPaths: ['o'], receiptPath: `${ROOT}/o.json` },
    deps,
  );
  expect(result.ok).toBe(true);
  expect(result.qaOk).toBe(true);
});

test('a foreign task with the same name is refused and never deleted', async () => {
  const { calls, deps } = recordingDeps({
    taskQuery: async () => { calls.push('query'); return { name: 'ForgeQAOrder', author: 'OTHERDOMAIN\\someone', commands: ['cmd /c C:/elsewhere/run.bat'] }; },
  });
  const result = await launchOwnedRun(
    { taskName: 'ForgeQAOrder', root: ROOT, user: 'qa-owner', inputBat: BAT, outputPaths: ['o'] },
    deps,
  );
  expect(result.ok).toBe(false);
  expect(result.failure).toContain('QA_LAUNCH_TASK_NAME_FOREIGN');
  expect(calls).toEqual(['query']);
});

test('an owned leftover with the same name is retired first', async () => {
  let queried = false;
  const { calls, deps } = recordingDeps({
    taskQuery: async () => { calls.push('query'); if (!queried) { queried = true; return owned('ForgeQAOrder'); } return null; },
  });
  const result = await launchOwnedRun(
    { taskName: 'ForgeQAOrder', root: ROOT, user: 'qa-owner', inputBat: BAT, outputPaths: ['o'] },
    deps,
  );
  expect(result.ok).toBe(true);
  expect(calls.slice(0, 3)).toEqual(['query', 'delete', 'create']);
  expect(result.stages).toContain('retired-leftover');
});

test('ownership uses path boundaries, not a sibling prefix', () => {
  expect(isPathInsideRoot(`${ROOT}/.omo/x.bat`, ROOT)).toBe(true);
  expect(isPathInsideRoot(ROOT.replaceAll('/', '\\') + '\\.omo\\x.bat', ROOT)).toBe(true);
  expect(isPathInsideRoot(ROOT.toUpperCase() + '/x.bat', ROOT)).toBe(true);
  expect(isPathInsideRoot(`${ROOT}-evil/.omo/x.bat`, ROOT)).toBe(false);
  expect(isPathInsideRoot('C:/elsewhere/run.bat', ROOT)).toBe(false);
  expect(isPathInsideRoot('', ROOT)).toBe(false);
  expect(normalizeWindowsPath('cmd /c "C:\\Root\\X.BAT"')).toBe('c:/root/x.bat');

  expect(isOwnedTask(owned('ForgeQAThing'), scope)).toBe(true);
  expect(isOwnedTask({ ...owned('ForgeQAThing'), name: 'MyOwnBackup' }, scope)).toBe(false);
  expect(isOwnedTask({ ...owned('ForgeQAThing'), commands: [`cmd /c "${ROOT}-evil/run.bat"`] }, scope)).toBe(false);
  expect(isOwnedTask({ ...owned('ForgeQAThing'), commands: [] }, scope)).toBe(false);
  expect(isOwnedTask({ ...owned('ForgeQAThing'), author: 'OTHERDOMAIN\\someone' }, scope)).toBe(false);
  expect(isOwnedTask(null, scope)).toBe(false);
  expect(ownedTaskNames([owned('ForgeQAOne'), { name: 'UserTask', commands: [ROOT + '/x.bat'] }], scope)).toEqual(['ForgeQAOne']);
});

test('retirement deletes owned tasks and never touches a foreign one', async () => {
  const deleted = [];
  const result = await retireOwnedTasks(
    [owned('ForgeQAOne'), owned('ForgeQATwo'), { name: 'UserTask', author: 'qa-owner', commands: [ROOT + '/x.bat'] },
     { name: 'ForgeQAOutside', author: 'qa-owner', commands: ['cmd /c C:/elsewhere/run.bat'] }],
    scope,
    { taskDelete: async name => { deleted.push(name); } },
  );
  expect(deleted).toEqual(['ForgeQAOne', 'ForgeQATwo']);
  expect(result.skipped).toEqual(['UserTask', 'ForgeQAOutside']);
  const failing = await retireOwnedTasks([owned('ForgeQAThree')], scope, { taskDelete: async () => { throw new Error('access denied'); } });
  expect(failing.retired).toEqual([]);
  expect(failing.skipped[0]).toBe('ForgeQAThree:access denied');
});

test('run paths are unique per invocation and never collide', () => {
  const a = runPaths(ROOT, 'av11', '20261009T010000Z');
  const b = runPaths(ROOT, 'av11', '20261009T020000Z');
  expect(a.directory).not.toBe(b.directory);
  expect(a.receipt.endsWith('av11.json')).toBe(true);
  expect(a.receipt.startsWith(a.directory)).toBe(true);
  expect(a.batch.startsWith(a.directory)).toBe(true);
  expect(() => runPaths(ROOT, 'av11', 'not-a-stamp')).toThrow('QA_LAUNCH_STAMP_REQUIRED');
  expect(() => runPaths('', 'av11', '20261009T010000Z')).toThrow('QA_LAUNCH_ROOT_REQUIRED');
  expect(QA_TASK_PREFIX).toBe('ForgeQA');
});
