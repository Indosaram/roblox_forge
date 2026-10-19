import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

// The PowerShell supervisor retains the actual Process object. It never uses
// process-name termination, a reused PID, credentials, or GUI automation.
export const supervisor = String.raw`
$ErrorActionPreference='Stop'
$request=[Console]::ReadLine() | ConvertFrom-Json
$owned=$null
$tree=$null
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public sealed class ForgeProcessTree : IDisposable {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct STARTUPINFO {
    public int cb; public string reserved, desktop, title;
    public int x,y,xSize,ySize,xChars,yChars,fill,flags;
    public short show,reserved2; public IntPtr reservedPtr,input,output,error;
  }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr process,thread; public uint pid,tid; }
  [StructLayout(LayoutKind.Sequential)] struct BASIC_LIMIT {
    public long processTime,jobTime; public uint flags; public UIntPtr min,max;
    public uint active; public UIntPtr affinity; public uint priority,scheduling;
  }
  [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong a,b,c,d,e,f; }
  [StructLayout(LayoutKind.Sequential)] struct EXTENDED_LIMIT { public BASIC_LIMIT basic; public IO_COUNTERS io; public UIntPtr processMemory,jobMemory,peakProcess,peakJob; }
  [StructLayout(LayoutKind.Sequential)] struct PORT_ASSOCIATION { public IntPtr key,port; }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref STARTUPINFO start,out PROCESS_INFORMATION info);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr security,string name);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,IntPtr value,uint size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint timeout);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr CreateIoCompletionPort(IntPtr file,IntPtr existing,IntPtr key,uint threads);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetQueuedCompletionStatus(IntPtr port,out uint message,out IntPtr key,out IntPtr value,uint timeout);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateDesktop(string name,IntPtr device,IntPtr mode,uint flags,uint access,IntPtr security);
  [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
  [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint threadId);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr handle,int index,System.Text.StringBuilder info,int length,out int needed);
  IntPtr job,port,process,desktop; bool assigned; public uint Pid { get; private set; }
  public string JobName { get; private set; }
  public string DesktopName { get; private set; }
  void Set<T>(int kind,T value) { int size=Marshal.SizeOf(typeof(T)); IntPtr p=Marshal.AllocHGlobal(size); try { Marshal.StructureToPtr(value,p,false); if(!SetInformationJobObject(job,kind,p,(uint)size)) throw new Exception("JOB_CONFIGURATION_FAILED"); } finally { Marshal.FreeHGlobal(p); } }
  // The interactive launch keeps the caller's own desktop, so the registration helper needs its
  // name: the editor is only reachable by enumerating the desktop it actually runs on.
  static string CurrentDesktopName() {
    var buffer=new System.Text.StringBuilder(256); int needed;
    if(!GetUserObjectInformation(GetThreadDesktop(GetCurrentThreadId()),2,buffer,buffer.Capacity*2,out needed)) throw new Exception("CURRENT_DESKTOP_UNAVAILABLE");
    var name=buffer.ToString(); if(name.Length==0) throw new Exception("CURRENT_DESKTOP_UNAVAILABLE"); return name;
  }
  public ForgeProcessTree(string executable,string artifact,string desktopMode) {
    try {
      JobName="Local\\ForgeQA-"+Guid.NewGuid().ToString("N");
      job=CreateJobObject(IntPtr.Zero,JobName); if(job==IntPtr.Zero || Marshal.GetLastWin32Error()==183) throw new Exception("JOB_CREATE_FAILED");
      var limit=new EXTENDED_LIMIT(); limit.basic.flags=0x2000; Set(9,limit);
      port=CreateIoCompletionPort(new IntPtr(-1),IntPtr.Zero,IntPtr.Zero,1); if(port==IntPtr.Zero) throw new Exception("JOB_PORT_FAILED");
      Set(7,new PORT_ASSOCIATION{key=new IntPtr(1),port=port});
      string desktopName=null;
      // Isolated is the default: a private non-input desktop. "interactive" keeps the
      // job ownership, identity and cleanup proof but lets the editor inherit the
      // caller's own desktop, the only mode in which this Studio build registered its
      // MCP server (measured: isolated launch -> EDITOR_NOT_REGISTERED_AT_PROCESS_ADMISSION
      // while the same artifact on an interactive desktop registered immediately).
      if(desktopMode!="interactive") {
        desktopName="ForgeQA-"+Guid.NewGuid().ToString("N");
        desktop=CreateDesktop(desktopName,IntPtr.Zero,IntPtr.Zero,0,0x10000000,IntPtr.Zero);
        if(desktop==IntPtr.Zero) throw new Exception("BACKGROUND_DESKTOP_UNAVAILABLE");
      } else {
        // Name the caller's own desktop instead of leaving the scope empty, so the registration
        // helper opens exactly the desktop this editor runs on.
        desktopName=CurrentDesktopName();
      }
      DesktopName=desktopName;
      // Never SwitchDesktop: an isolated launch keeps its windows on the private desktop.
      var start=new STARTUPINFO(); start.cb=Marshal.SizeOf(typeof(STARTUPINFO)); start.flags=1; start.show=0; start.desktop=desktopName;
      PROCESS_INFORMATION info;
      if(!CreateProcess(executable,new StringBuilder("\""+executable+"\" \""+artifact+"\""),IntPtr.Zero,IntPtr.Zero,false,0x08000004,IntPtr.Zero,null,ref start,out info)) throw new Exception("PROCESS_CREATE_FAILED");
      process=info.process; Pid=info.pid;
      try {
        if(!AssignProcessToJobObject(job,process)) throw new Exception("JOB_ASSIGN_FAILED");
        assigned=true;
        if(ResumeThread(info.thread)==UInt32.MaxValue) throw new Exception("PROCESS_RESUME_FAILED");
      } finally { CloseHandle(info.thread); }
    } catch { Dispose(); throw; }
  }
  public void Stop(uint timeout) {
    if(!assigned) return;
    if(!TerminateJobObject(job,1)) throw new Exception("JOB_STOP_FAILED");
    var clock=System.Diagnostics.Stopwatch.StartNew();
    while(clock.ElapsedMilliseconds<timeout) {
      uint message; IntPtr key,value;
      if(!GetQueuedCompletionStatus(port,out message,out key,out value,(uint)(timeout-clock.ElapsedMilliseconds))) throw new Exception("JOB_EXIT_EVENT_TIMEOUT");
      if(message==4) { assigned=false; return; } // JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO
    }
    throw new Exception("JOB_EXIT_EVENT_TIMEOUT");
  }
  public void Dispose() {
    // KILL_ON_JOB_CLOSE reaps only members, even if the supervisor is lost.
    if(process!=IntPtr.Zero && !assigned) { TerminateProcess(process,1); WaitForSingleObject(process,30000); }
    if(job!=IntPtr.Zero) { CloseHandle(job); job=IntPtr.Zero; }
    if(process!=IntPtr.Zero) { CloseHandle(process); process=IntPtr.Zero; }
    if(port!=IntPtr.Zero) { CloseHandle(port); port=IntPtr.Zero; }
    if(desktop!=IntPtr.Zero) { CloseDesktop(desktop); desktop=IntPtr.Zero; }
  }
}
'@
try {
  $artifact=(Resolve-Path -LiteralPath $request.artifact).Path
  $exe=(Resolve-Path -LiteralPath $request.executable).Path
  if($artifact.Contains('"')){throw 'INVALID_ARTIFACT_PATH'}
  $baseline=@(Get-CimInstance Win32_Process -Filter "Name='RobloxStudioBeta.exe'" | Select-Object -ExpandProperty ProcessId)
  # Suspended creation, job assignment and completion-port subscription all
  # precede ResumeThread: no child can escape between launch and ownership.
  $tree=[ForgeProcessTree]::new($exe,$artifact,[string]$request.desktop)
  $owned=[Diagnostics.Process]::GetProcessById($tree.Pid)
  if($baseline -contains $owned.Id){throw 'BASELINE_PROCESS_REFUSED'}
  $actual=Get-CimInstance Win32_Process -Filter ('ProcessId='+$owned.Id)
  if(-not $actual -or -not $actual.CommandLine.Contains($artifact)){throw 'PROCESS_IDENTITY_UNAVAILABLE'}
  $identity=@{pid=$owned.Id;creationTime=$owned.StartTime.ToUniversalTime().ToString('o');captureIdentity=('pid:'+$owned.Id+':created:'+$owned.StartTime.ToUniversalTime().ToFileTimeUtc());commandLine=$actual.CommandLine;artifact=$artifact;baseline=$baseline;treeOwnership='windows-job-no-breakaway';jobName=$tree.JobName;desktopName=$tree.DesktopName}
  [Console]::WriteLine((@{event='acquired';identity=$identity}|ConvertTo-Json -Depth 5 -Compress))
  # EOF is cancellation too: a lost parent cannot abandon its owned editor.
  $null=[Console]::ReadLine()
} catch {
  [Console]::WriteLine('{"event":"failed","code":"OWNED_PROCESS_FAILED"}')
} finally {
  if($tree){
    try {
      $tree.Stop(30000)
      [Console]::WriteLine((@{event='released';pid=$tree.Pid;treeExited=$true;eventProof='JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO'}|ConvertTo-Json -Compress))
    } finally {$tree.Dispose();if($owned){$owned.Dispose()}}
  } else {[Console]::WriteLine('{"event":"released","notStarted":true}')}
}
`;

export async function launchOwnedEditor(config, lifecycle, spawnProcess = spawn) {
  if (typeof config.executable !== 'string' || typeof config.artifact !== 'string' || !config.executable || !config.artifact) throw new Error('OWNED_PROCESS_CONFIG_REQUIRED');
  let child, lines, released, closed, resolveRelease;
  const row = lifecycle.attempt('editor-process', 'owned-editor', async (_, signal) => {
    if (!child) return { released: true, evidence: { notStarted: true } };
    const abort = () => { child.kill(); releaseRejected(new Error('SUPERVISOR_CLEANUP_TIMEOUT')); };
    signal.addEventListener('abort', abort, { once: true });
    try {
      child.stdin.end();
      const proof = await released;
      const exit = await closed;
      if (!proof.notStarted && (proof.treeExited !== true || proof.eventProof !== 'JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO')) throw new Error('OWNED_TREE_EXIT_UNPROVEN');
      if (exit.code !== 0) throw new Error('SUPERVISOR_EXIT_FAILED');
      return { released: true, evidence: proof };
    } finally {
      signal.removeEventListener('abort', abort);
      lines?.close();
      if (child.exitCode === null && child.signalCode === null) child.kill();
    }
  }, { cleanupTimeoutMs: 40000 });
  let acquired, releaseRejected;
  const result = await lifecycle.observe({
    phase: 'editor-launch',
    subscribe: (notify, reject) => {
      acquired = { notify, reject };
      return () => { acquired = null; };
    },
    action: () => {
      child = spawnProcess('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(supervisor, 'utf16le').toString('base64')], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
      released = new Promise((resolve, reject) => { resolveRelease = resolve; releaseRejected = reject; });
      released.catch(() => {});
      closed = new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal })));
      child.once('error', () => { acquired?.reject(new Error('SUPERVISOR_FAILED')); releaseRejected(new Error('SUPERVISOR_FAILED')); });
      child.once('close', () => { acquired?.reject(new Error('SUPERVISOR_CLOSED_BEFORE_ADMISSION')); releaseRejected(new Error('SUPERVISOR_CLOSED_WITHOUT_RELEASE')); });
      child.stderr.resume();
      lines = createInterface({ input: child.stdout });
      lines.on('line', line => {
        try {
          const message = JSON.parse(line);
          if (message.event === 'acquired') {
            if (!lifecycle.closing) lifecycle.acquire(row, message.identity);
            acquired?.notify(message.identity);
          } else if (message.event === 'released') resolveRelease(message);
          else if (message.event === 'failed') acquired?.reject(new Error('OWNED_PROCESS_FAILED'));
        } catch { acquired?.reject(new Error('INVALID_SUPERVISOR_RECEIPT')); }
      });
      child.stdin.write(JSON.stringify(config) + '\n');
      return { supervisor: child.pid };
    },
  });
  const identity = { ...result.observed, desktopMode: config.desktop };
  const controller = {
    identity,
    // Durable crash authority belongs to StudioSession.crashAtBarrier, which
    // reads the held ticket from the actual owned runtime, not callbacks/JSON.
    close: () => lifecycle.release(row),
  };
  return { ...identity, controller };
}
