import { spawn } from 'node:child_process';

// CIM queries the actual controller hosting the owned local Studio Job. This is
// not a claim about remote machines or an invented hardware tier.
export async function hardware(lifecycle) {
  let child, exited, lines = '', errors = '';
  const row = lifecycle.attempt('hardware-probe', 'capacity-cim', async () => {
    if (!child) return { released: true, evidence: { notStarted: true } };
    if (child.exitCode === null && child.signalCode === null) child.kill();
    const exit = await exited;
    return { released: true, evidence: exit };
  });
  let notify, reject;
  // 30s: two owned runs (boot phases) hit OPERATION_TIMEOUT at 15s while ten
  // Studio processes were still spawning; the probe itself completes in
  // seconds once PowerShell can start, so the ceiling only absorbs boot load.
  const result = await lifecycle.observe({ phase: 'capacity-hardware', timeoutMs: 30000,
    subscribe: (resolve, fail) => { notify = resolve; reject = fail; return () => { notify = () => {}; reject = () => {}; }; },
    action: () => {
      const script = "$ErrorActionPreference='Stop';$cpu=Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors;$os=Get-CimInstance Win32_OperatingSystem|Select-Object Caption,Version,BuildNumber,TotalVisibleMemorySize;$gpu=Get-CimInstance Win32_VideoController|Select-Object Name,DriverVersion,AdapterRAM;@{cpu=@($cpu);os=$os;gpu=@($gpu)}|ConvertTo-Json -Depth 5 -Compress";
      child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
      exited = new Promise(resolve => child.once('close', (code, signal) => {
        resolve({ code, signal });
        // PowerShell writes progress records to stderr (CLIXML) even on success;
        // only the exit code and the parsed result decide the outcome.
        if (code === 0) { try { notify(JSON.parse(lines)); } catch { reject(new Error('CIM_INVALID_RESULT')); } }
        else reject(new Error('CIM_FAILED'));
      }));
      child.once('error', () => reject(new Error('CIM_SPAWN_FAILED')));
      child.stdout.on('data', chunk => { lines += chunk; });
      child.stderr.on('data', chunk => { errors += chunk; });
      child.once('spawn', () => { if (!lifecycle.closing) lifecycle.acquire(row, { pid: child.pid }); });
    } });
  if (!result.observed?.cpu?.length || !result.observed?.os?.Version) throw new Error('CIM_IDENTITY_INCOMPLETE');
  return { scope: 'owned-local-job-host', provider: 'Windows-CIM', ...result.observed };
}
