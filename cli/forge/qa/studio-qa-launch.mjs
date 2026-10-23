// Owned-QA run launcher: the ONE place that may register, start and retire a Windows scheduled task for a
// QA run. `.omo/.../launch-scenario.ps1` delegates here, and `windowsSchedulerDeps()` below is the real
// implementation, so the sequencing the tests pin is the sequencing a launch performs.
//
// Why this exists: runs were launched with `schtasks /create ... /sc once /st 23:59` plus `/run`. `/run`
// started the task immediately, but the 23:59 time trigger stayed registered and the task was never
// deleted, so the scheduler re-fired every task and its batch overwrote receipts in place - 44 evidence
// files across 18 run directories (see INTEGRITY-LOSS-LEDGER.md).
//
// The fix is structural, not procedural: the task is registered with NO TRIGGERS AT ALL. A triggerless
// task cannot fire on its own, so no future re-fire is possible and there is nothing to disable. It is
// registered enabled (a disabled task refuses to start - SCHED_E_TASK_DISABLED, 0x80041326) and started
// on demand with `Start-ScheduledTask`.
//
// Two earlier attempts at this module were wrong and are not repeated here:
//   * Disabling the trigger right after create made `/run` fail: `schtasks /change /disable` disables the
//     WHOLE task, not just a trigger, so the run could never start.
//   * Requiring the runner .bat to be absent made every launch impossible: the batch is the task's INPUT
//     and must already exist. Only the run's OUTPUTS (log, meta, receipt) have to be free.
import { spawn } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

export const QA_TASK_PREFIX = 'ForgeQA';

const BACKSLASH = String.fromCharCode(92);
const demand = (condition, code) => { if (!condition) throw new Error(code); };

/**
 * Windows path normalization for comparison only: a leading `cmd /c` is stripped first, then surrounding
 * quotes, separators unified, runs collapsed, the trailing separator removed, and the result lowercased
 * because the Windows filesystem is case-insensitive. Order matters: stripping quotes before `cmd /c`
 * leaves the quotes attached to the path.
 */
export function normalizeWindowsPath(value) {
  let text = String(value ?? '').trim();
  if (!text) return '';
  text = text.replace(/^cmd(\.exe)?\s+\/c\s+/i, '');
  text = text.replace(/^"(.*)"$/, '$1');
  text = text.split(BACKSLASH).join('/');
  text = text.replace(/\/{2,}/g, '/');
  text = text.replace(/\/+$/, '');
  return text.toLowerCase();
}

/**
 * True only when `candidate` is the root itself or a descendant of it. A plain `startsWith` would accept
 * a sibling such as `.../forge-production-release-wave1-evil`, which is not inside the worktree.
 */
export function isPathInsideRoot(candidate, root) {
  const path = normalizeWindowsPath(candidate);
  const base = normalizeWindowsPath(root);
  if (!path || !base) return false;
  if (path === base) return true;
  return path.startsWith(base + '/');
}

/** The action path of a scheduled-task command, whether it is `cmd /c "..."` or a bare executable. */
export function actionPath(command) {
  return normalizeWindowsPath(command);
}

/**
 * Every path a run will WRITE must be absent before launch. A path that already exists means a previous
 * run or a re-fire produced it, and writing over it destroys evidence that cannot be recovered. This is
 * for outputs only: the runner batch is an input and must already exist.
 */
export function assertOutputsFree(paths, exists = existsSync) {
  demand(Array.isArray(paths) && paths.length > 0, 'QA_LAUNCH_PATHS_REQUIRED');
  for (const path of paths) {
    demand(typeof path === 'string' && path.length > 0, 'QA_LAUNCH_PATH_INVALID');
    if (exists(path)) throw new Error('QA_LAUNCH_OUTPUT_EXISTS:' + path);
  }
}

/** The runner batch is the task's input: it must already exist and must live inside this worktree. */
export function assertRunnerInput(batPath, root, exists = existsSync) {
  demand(typeof batPath === 'string' && batPath.length > 0, 'QA_LAUNCH_BAT_REQUIRED');
  if (!isPathInsideRoot(batPath, root)) throw new Error('QA_LAUNCH_BAT_OUTSIDE_ROOT:' + batPath);
  if (!exists(batPath)) throw new Error('QA_LAUNCH_BAT_MISSING:' + batPath);
}

/**
 * A task is owned only when its name carries the QA prefix, its author is this user, and every action
 * command resolves inside this worktree by boundary. Anything else - including any task the user created,
 * and any task whose action points at a sibling directory - is never touched.
 */
export function isOwnedTask(task, { root, user } = {}) {
  if (!task || typeof task.name !== 'string' || !task.name.startsWith(QA_TASK_PREFIX)) return false;
  if (user && task.author && !normalizeWindowsPath(task.author).includes(normalizeWindowsPath(user))) return false;
  const commands = Array.isArray(task.commands) ? task.commands : [];
  if (commands.length === 0) return false;
  return commands.every(command => isPathInsideRoot(actionPath(command), root));
}

export function ownedTaskNames(tasks, scope) {
  return (Array.isArray(tasks) ? tasks : []).filter(task => isOwnedTask(task, scope)).map(task => task.name);
}

/**
 * Runs one QA run under a triggerless demand task:
 *   runner exists -> outputs free -> create (enabled, no triggers) -> start -> terminal -> delete.
 * `waitForStart`/`waitForTerminal` are bounded waits injected by the caller, so the sequencing is driven
 * by observed state rather than by a fixed sleep.
 */
export async function launchOwnedRun(options, deps) {
  const { taskName, root, user, inputBat, outputPaths, receiptPath } = options ?? {};
  demand(typeof taskName === 'string' && taskName.startsWith(QA_TASK_PREFIX), 'QA_LAUNCH_TASK_NAME_REQUIRED');
  demand(typeof root === 'string' && root.length > 0, 'QA_LAUNCH_ROOT_REQUIRED');
  const { taskQuery, taskCreate, taskRun, taskDelete, waitForStart, waitForTerminal, exists, readReceipt } = deps ?? {};
  for (const [name, fn] of Object.entries({ taskQuery, taskCreate, taskRun, taskDelete, waitForStart, waitForTerminal })) {
    demand(typeof fn === 'function', 'QA_LAUNCH_DEP_REQUIRED:' + name);
  }
  // A declared receipt path makes the run's completion receipt the terminal contract: the task's
  // state can only say the scheduler finished, not that the QA run passed.
  const enforceReceipt = typeof receiptPath === 'string' && receiptPath.length > 0;
  if (enforceReceipt) demand(typeof readReceipt === 'function', 'QA_LAUNCH_DEP_REQUIRED:readReceipt');
  const fs = exists ?? existsSync;
  const wait = deps?.sleep ?? (ms => new Promise(resolve => setTimeout(resolve, ms)));

  let created = false;
  let deleteFailure = null;
  const stages = [];
  let failure = null;
  let receipt = null;
  try {
    // The runner is an input that must already exist; the outputs must not. Both are checked before any
    // task exists, so a refused launch never registers the task that could re-fire.
    assertRunnerInput(inputBat, root, fs);
    assertOutputsFree(outputPaths, fs);
    stages.push('prepared');

    // A task with this name may already exist. An owned leftover is retired; a foreign one is refused, so
    // this call can never force-overwrite (and later delete) a task it did not create.
    const existing = await taskQuery(taskName);
    if (existing) {
      if (!isOwnedTask(existing, { root, user })) throw new Error('QA_LAUNCH_TASK_NAME_FOREIGN:' + taskName);
      await taskDelete(taskName);
      stages.push('retired-leftover');
    }

    const createdTask = await taskCreate({ taskName, batPath: inputBat });
    // Only now does this call own the task, so only now may the delete below run.
    created = true;
    demand(isOwnedTask({ name: taskName, author: createdTask?.author, commands: createdTask?.commands }, { root, user }),
      'QA_LAUNCH_TASK_NOT_OWNED');
    demand(createdTask?.triggers === 0, 'QA_LAUNCH_TASK_HAS_TRIGGERS');
    stages.push('created');

    await taskRun(taskName);
    stages.push('run');

    // A run that finishes faster than the first state sample never shows `Running`. Observing the
    // start is therefore best-effort: a launch must not report a false timeout for a run that has
    // already completed. The terminal contract below is what decides.
    try { await waitForStart(); stages.push('started'); }
    catch (error) { stages.push('start-unobserved'); }

    await waitForTerminal();
    stages.push('terminal');

    if (enforceReceipt) {
      // The runner writes its receipt before it exits, but the terminal state can be observed a
      // moment earlier; poll the receipt under its own bounded deadline rather than assuming order.
      const deadline = Date.now() + (options?.receiptTimeoutMs ?? 15000);
      for (;;) {
        receipt = await readReceipt();
        if (receipt !== null && receipt !== undefined) break;
        if (Date.now() >= deadline) break;
        await wait(250);
      }
      stages.push(receipt == null ? 'receipt-missing' : 'receipt');
    }
  } catch (error) {
    failure = String(error?.message ?? error);
  } finally {
    // Retire the task whatever the outcome. `created` guards it, so a create failure cannot delete a task
    // this call never made, and a delete failure is reported rather than swallowed.
    if (created) {
      try { await taskDelete(taskName); stages.push('deleted'); }
      catch (error) { deleteFailure = String(error?.message ?? error); stages.push('delete-failed'); }
    }
  }
  const lifecycleOk = failure === null && deleteFailure === null;
  // The receipt is the QA verdict: a lifecycle-complete launch whose receipt is absent or not ok is a
  // failed QA run, reported separately from the launch itself.
  const qaOk = enforceReceipt ? (receipt != null && receipt.ok === true) : true;
  if (enforceReceipt && !qaOk && failure === null && deleteFailure === null) {
    failure = 'QA_RUN_FAILED:' + String(receipt?.failure ?? receipt?.blocker ?? (receipt == null ? 'receipt-missing:' + receiptPath : 'ok!=true'));
  }
  return { ok: lifecycleOk && qaOk, lifecycleOk, qaOk, taskName, stages, failure, deleteFailure, receipt };
}

/** Retires the completed owned tasks. Returns the names retired; foreign tasks are never included. */
export async function retireOwnedTasks(tasks, scope, deps) {
  const { taskDelete } = deps ?? {};
  demand(typeof taskDelete === 'function', 'QA_RETIRE_DEP_REQUIRED');
  const retired = [];
  const skipped = [];
  for (const task of Array.isArray(tasks) ? tasks : []) {
    if (!isOwnedTask(task, scope)) { skipped.push(task?.name); continue; }
    try { await taskDelete(task.name); retired.push(task.name); }
    catch (error) { skipped.push(task?.name + ':' + String(error?.message ?? error)); }
  }
  return { retired, skipped };
}

/** Builds the run's evidence paths so a caller cannot accidentally reuse another run's directory. */
export function runPaths(root, name, stamp) {
  demand(typeof root === 'string' && root.length > 0, 'QA_LAUNCH_ROOT_REQUIRED');
  demand(typeof name === 'string' && name.length > 0, 'QA_LAUNCH_NAME_REQUIRED');
  demand(typeof stamp === 'string' && /^[0-9]{8}T[0-9]{6}Z$/.test(stamp), 'QA_LAUNCH_STAMP_REQUIRED');
  // Separators are unified for a portable path, but the case is preserved: this is a real filesystem path.
  const base = String(root).split(BACKSLASH).join('/').replace(/\/+$/, '');
  const directory = `${base}/live-${name}-${stamp}`;
  return {
    directory,
    receipt: `${directory}/${name}.json`,
    log: `${directory}/${name}.log`,
    batch: `${directory}/run-${name}.bat`,
    meta: `${directory}/${name}.meta`,
  };
}

/** Reads a `Label: value` field from `schtasks /query /v` output without a fragile regex. */
function schedulerField(text, label) {
  const wanted = (label + ':').toLowerCase();
  for (const raw of String(text ?? '').split(/\r?\n/)) {
    const trimmed = raw.trim();
    if (trimmed.toLowerCase().startsWith(wanted)) return trimmed.slice(wanted.length).trim();
  }
  return '';
}

/**
 * Builds the PowerShell that registers a TRIGGERLESS task in the interactive session. `New-ScheduledTask`
 * is called with no `-Trigger`, which is the whole point: a task with no triggers can never fire on its
 * own, so no future re-fire and no disable step are needed. `-LogonType Interactive` is the equivalent of
 * `schtasks /it`. Exported so the exact script can be asserted in tests without touching the machine.
 */
export function registerTaskScript({ taskName, batPath, user }) {
  const quote = value => String(value).replaceAll("'", "''");
  return [
    "$ErrorActionPreference = 'Stop'",
    `$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c "${quote(batPath)}"'`,
    `$principal = New-ScheduledTaskPrincipal -UserId '${quote(user)}' -LogonType Interactive -RunLevel Limited`,
    `$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries`,
    // No -Trigger anywhere: a demand-only task.
    `Register-ScheduledTask -TaskName '${quote(taskName)}' -Action $action -Principal $principal -Settings $settings -Force | Out-Null`,
    `$task = Get-ScheduledTask -TaskName '${quote(taskName)}' -ErrorAction Stop`,
    `$count = @($task.Triggers | Where-Object { $_ -ne $null }).Count`,
    `Write-Output ('TRIGGERS: ' + $count)`,
    `Write-Output ('STATE: ' + $task.State)`,
  ].join('; ');
}

/**
 * The real Windows scheduler implementation. `run` is injectable so the exact command sequence can be
 * asserted without touching the machine, and the default shells out to the real executables.
 */
export function windowsSchedulerDeps({ root, run, exists = existsSync, sleep, now = () => Date.now() } = {}) {
  const exec = run ?? defaultRun;
  const wait = sleep ?? (ms => new Promise(resolve => setTimeout(resolve, ms)));
  const powershell = script => exec(['powershell', '-NoProfile', '-NonInteractive', '-Command', script]);

  const query = async taskName => {
    const result = await powershell(
      `$t = Get-ScheduledTask -TaskName '${taskName.replaceAll("'", "''")}' -ErrorAction SilentlyContinue; ` +
      `if (-not $t) { exit 1 }; ` +
      `Write-Output ('AUTHOR: ' + $t.Author); ` +
      `Write-Output ('ACTION: ' + ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" })); ` +
      `Write-Output ('TRIGGERS: ' + @($t.Triggers | Where-Object { $_ -ne $null }).Count); ` +
      `Write-Output ('STATE: ' + $t.State)`);
    if (result.code !== 0) return null;
    const commands = schedulerField(result.stdout, 'ACTION');
    if (!commands) return null;
    return {
      name: taskName,
      author: schedulerField(result.stdout, 'AUTHOR'),
      commands: [commands],
      triggers: Number(schedulerField(result.stdout, 'TRIGGERS') || '0'),
      state: schedulerField(result.stdout, 'STATE'),
    };
  };

  const state = async taskName => {
    const result = await powershell(
      `(Get-ScheduledTask -TaskName '${taskName.replaceAll("'", "''")}' -ErrorAction SilentlyContinue).State`);
    return result.stdout.trim();
  };

  const waitForState = async (taskName, wanted, timeoutMs) => {
    const deadline = now() + timeoutMs;
    for (;;) {
      const current = await state(taskName);
      if (wanted.includes(current)) return current;
      if (now() >= deadline) throw new Error('QA_LAUNCH_STATE_TIMEOUT:' + taskName + ':' + (current || 'unknown'));
      await wait(250);
    }
  };

  return {
    exists,
    async taskQuery(taskName) { return query(taskName); },
    async taskCreate({ taskName, batPath, user }) {
      const created = await powershell(registerTaskScript({ taskName, batPath, user }));
      if (created.code !== 0) {
        throw new Error('QA_LAUNCH_TASK_CREATE_FAILED:' + created.code + ':' + created.stdout.trim());
      }
      const task = await query(taskName);
      if (!task) throw new Error('QA_LAUNCH_TASK_CREATE_UNVERIFIED:' + taskName);
      return task;
    },
    async taskRun(taskName) {
      // Start-ScheduledTask is the demand start. The task is enabled, so this does not hit
      // SCHED_E_TASK_DISABLED the way a disabled task would.
      const result = await powershell(`Start-ScheduledTask -TaskName '${taskName.replaceAll("'", "''")}'`);
      if (result.code !== 0) throw new Error('QA_LAUNCH_TASK_RUN_FAILED:' + result.code + ':' + result.stdout.trim());
    },
    async taskDelete(taskName) {
      const result = await powershell(`Unregister-ScheduledTask -TaskName '${taskName.replaceAll("'", "''")}' -Confirm:$false`);
      if (result.code !== 0) throw new Error('QA_LAUNCH_TASK_DELETE_FAILED:' + result.code + ':' + result.stdout.trim());
    },
    async waitForStart(taskName, timeoutMs = 30000) { await waitForState(taskName, ['Running'], timeoutMs); },
    // Only an observed `Ready` is terminal. An empty sample is a failed or timed-out PowerShell query, not
    // a finished task; accepting it ended the wait mid-run and produced false `receipt-missing` verdicts.
    async waitForTerminal(taskName, timeoutMs = 900000) { await waitForState(taskName, ['Ready'], timeoutMs); },
  };
}

/**
 * Reads the completion receipt a run writes. The receipt is the QA verdict: `ok` is the run's own
 * outcome (the batch writes `ok=<true|false>`), and an absent or unparsable file is `null` so the
 * caller can tell "no receipt" from "receipt says failed".
 */
export function readRunReceipt(receiptPath, readFile = readFileSync) {
  if (typeof receiptPath !== 'string' || receiptPath.length === 0) return null;
  let text;
  try { text = readFile(receiptPath, 'utf8'); } catch { return null; }
  let parsed;
  try { parsed = JSON.parse(String(text)); } catch { return null; }
  if (parsed === null || typeof parsed !== 'object') return null;
  // Accept either a flat `{ ok }` receipt or the `qa run --evidence` document whose verdict is
  // `outcome.ok`; both are the same fact stated by the same run.
  const ok = parsed.ok === true || parsed.outcome?.ok === true;
  return { ...parsed, ok, failure: parsed.failure ?? parsed.blocker ?? parsed.outcome?.blockers?.[0] ?? null };
}

function defaultRun(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(args[0], args.slice(1), { windowsHide: true, shell: false });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk.toString('utf8'); });
    child.stderr.on('data', chunk => { stderr += chunk.toString('utf8'); });
    child.once('error', reject);
    child.once('close', code => resolve({ code: code ?? -1, stdout, stderr }));
  });
}

/**
 * CLI entry used by `.omo/.../launch-scenario.ps1`. `--bat` is an input that must exist inside the
 * worktree; `--log/--meta/--receipt` are outputs that must be free.
 */
async function main(argv) {
  const flag = name => {
    const index = argv.indexOf('--' + name);
    return index >= 0 && index + 1 < argv.length ? argv[index + 1] : null;
  };
  const taskName = flag('task');
  const batPath = flag('bat');
  const logPath = flag('log');
  const metaPath = flag('meta');
  const receiptPath = flag('receipt');
  const root = flag('root') ?? process.cwd();
  const user = flag('user') ?? process.env.USERNAME ?? '';
  for (const [name, value] of Object.entries({ task: taskName, bat: batPath, log: logPath, meta: metaPath, receipt: receiptPath })) {
    if (!value) { process.stderr.write('QA_LAUNCH_ARG_REQUIRED:--' + name + '\n'); return 2; }
  }

  const deps = windowsSchedulerDeps({ root });
  const result = await launchOwnedRun(
    { taskName, root, user, inputBat: batPath, outputPaths: [logPath, metaPath, receiptPath], receiptPath },
    {
      ...deps,
      taskCreate: options => deps.taskCreate({ ...options, user }),
      waitForStart: () => deps.waitForStart(taskName, Number(flag('start-timeout-ms') ?? 30000)),
      waitForTerminal: () => deps.waitForTerminal(taskName, Number(flag('terminal-timeout-ms') ?? 900000)),
      readReceipt: () => readRunReceipt(receiptPath),
    },
  );
  const record = [
    `cwd=${root}`, `cmd=${batPath}`, `task=${taskName}`,
    `start=${new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')}`,
    `stages=${result.stages.join(',')}`, `ok=${result.ok}`,
    `lifecycleOk=${result.lifecycleOk}`, `qaOk=${result.qaOk}`,
    `failure=${result.failure ?? 'none'}`, `deleteFailure=${result.deleteFailure ?? 'none'}`,
  ].join('\n') + '\n';
  // The meta file is one of the per-run outputs that must stay free, so it is written only once a task was
  // actually registered. A launch refused before that must leave the path untouched.
  if (result.stages.includes('created')) {
    try { writeFileSync(metaPath, record); } catch { /* best effort; the exit code is not */ }
  }
  process.stdout.write(record);
  if (!result.ok) {
    process.stderr.write('QA_LAUNCH_FAILED:' + (result.failure ?? '') + ':' + (result.deleteFailure ?? '') + '\n');
    return 1;
  }
  return 0;
}

if (import.meta.main) {
  main(process.argv.slice(2)).then(code => process.exit(code)).catch(error => {
    process.stderr.write('QA_LAUNCH_ERROR:' + String(error?.message ?? error) + '\n');
    process.exit(3);
  });
}
