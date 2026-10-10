# Local audio QA capture

`capture-audio.ps1` uses the adjacent retained `ForgeQAAudio.cs` implementation.
It records the default Windows render endpoint's whole mix, not one process.
It never generates a test tone. Do not start a second recorder.

Use a fresh output prefix in an existing directory. Subscribe to the ready file
creation BEFORE launching the wrapper, or launch through the command monitor
with filter `^READY `. Commands under test may begin only after that signal.
The marker is atomically published after BOTH WASAPI Start calls succeed and
includes endpoint ID, UTC time, and the cancellation event name. Process launch
is not readiness. A capture error before READY means no action should be fired.

Example from the repository root, using a fresh evidence prefix:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File cli/forge/tools/capture-audio.ps1 -Out .omo/audio-qa-01.wav -ReadyPath .omo/audio-qa-01.ready -LogFile .omo/audio-qa-01.log -CancelEvent Local\ForgeAudioQA-01 -Ms 180000
```

The caller must choose a unique cancellation name as well as fresh paths. No
session ID or process ID is part of the contract. Run without a visible window
through the agent command monitor; `READY <absolute path>` is flushed to stdout.
The path watcher alternative watches `.omo/audio-qa-01.ready` with event create.

The end signal is `CAPTURE_COMPLETE` and exit 0. Require `STATUS=OK` in the log,
then inspect the actual recording. READY proves only engine capture started;
it does not prove a game sound loaded or was audible. A whole-system nonzero
waveform is not proof of an individual cue. Pair cue intervals with actual
confirmed gameplay result and owned Sound playback observations.

Cancellation from a separate PowerShell command, after READY:

```powershell
$cancel = [Threading.EventWaitHandle]::OpenExisting('Local\ForgeAudioQA-01')
try { [void]$cancel.Set() } finally { $cancel.Dispose() }
```

Cancellation wakes the audio wait without sleeps, stops both clients, releases
COM objects/mix-format memory/event handles, and exits nonzero with STATUS=FAIL.
Timeout or initialization failure also takes the cleanup path. The run is bounded
to ten minutes maximum; audio-event inactivity fails after two seconds. Retain
failed artifacts as failed evidence; never reuse their READY file. Force-killing
the process is a last resort and cannot produce a successful capture receipt.

No PowerShell/C# test harness neighbors exist in this tools directory. This
helper has not been compiled, executed, or used for recording as part of its
authoring; consolidated validation remains required. Historical prerequisite
receipts describe the earlier recorder, not verification of this revision.
