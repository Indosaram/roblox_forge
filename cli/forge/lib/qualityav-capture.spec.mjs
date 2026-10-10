// Adjacent specs for the capture hook. Authored, deliberately unrun in this
// environment: no helper binary, no provider, no listening catalog and no live
// capture is available, so these only exercise the wrapper's own contract with
// an injected fake helper and injected filesystem/hash functions. Nothing here
// can assert audiovisual quality; capture results stay inconclusive for
// auditory judgment.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';

import {
  openCapture,
  buildCaptureRequest,
  captureArgv,
  parseEvent,
  buildSourceReceipt,
  resolveHelper,
  canonicalJson,
  sha256Hex,
  NATIVE_HELPER_RELATIVE_PATH,
  CAPTURE_MODES,
} from './qualityav-capture.mjs';

const window = { hwnd: '0x0000000000012345' };
const processAdmission = { pid: 4242, identity: 'pid:4242:created:133700000000000000' };
const clients = [{ actorId: 'e/actor', studioId: 'e/studio', pid: 4242, identity: processAdmission.identity }];
const sources = { 'e/av': 'a'.repeat(64) };

function fakeLifecycle() {
  const rows = [];
  return {
    rows,
    attempt(kind, id, dispose) {
      const row = { kind, id, dispose, acquired: null };
      rows.push(row);
      return row;
    },
    acquire(row, identity) {
      row.acquired = identity;
    },
  };
}

function fakeChild() {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.written = [];
  // Mirrors the helper protocol: stop answers with a finalized event and quit
  // ends the process, so no test ever waits on wall-clock time.
  child.stdin = {
    write(chunk) {
      child.written.push(String(chunk));
      if (String(chunk).startsWith('stop')) child.emitLine(JSON.stringify(finalizedEvent()));
      if (String(chunk).startsWith('quit')) child.emit('close', 0, null);
      return true;
    },
  };
  child.killed = false;
  child.kill = signal => {
    child.killed = true;
    child.emit('close', signal === 'SIGKILL' ? null : 0, signal ?? null);
    return true;
  };
  child.pid = 9001;
  child.emitLine = line => child.stdout.write(line + '\n');
  return child;
}

function makeOptions(extra = {}) {
  const lifecycle = fakeLifecycle();
  const children = [];
  const timers = new Set();
  const base = {
    sources,
    process: processAdmission,
    clients,
    ownershipToken: 'cap-token-1',
    artifactDirectory: 'C:/artifacts/cap-token-1',
    window,
    lifecycle,
    helperPath: 'C:/root/cli/forge/native/qualityav-capture/build/qualityav-capture.exe',
    spawnProcess: () => {
      const child = fakeChild();
      children.push(child);
      queueMicrotask(() => child.emitLine(JSON.stringify(startedEvent())));
      return child;
    },
    makeDirectory: async () => undefined,
    writeBytes: async () => undefined,
    readBytes: async () => Buffer.alloc(64),
    schedule: fn => { timers.add(fn); return fn; },
    unschedule: id => timers.delete(id),
    pathExists: () => false,
    startTimeoutMs: 5000,
    finalizeTimeoutMs: 5000,
  };
  const options = { ...base, ...extra };
  options.children = children;
  options.lifecycle = lifecycle;
  options.timers = timers;
  return options;
}

function startedEvent(overrides = {}) {
  return {
    type: 'started',
    requestId: 'cap-token-1',
    ack: 'start',
    recorder: 'pid:9001:created:133700000000000001',
    hostStartMs: 1000,
    clock: { qpcFrequency: 10000000, qpcStart: 5555, firstVideoPts100ns: 0, lastVideoPts100ns: 100000 },
    source: {
      recorderId: 'pid:9001:created:133700000000000001',
      hwnd: '0x0000000000012345',
      windowOwner: { identity: processAdmission.identity, pid: processAdmission.pid, image: 'C:/Studio.exe' },
      activationKind: 'process-loopback',
      audioEndpoint: 'process-loopback:VAD\\Process_Loopback:target=4242:mode=include-tree',
      endpointId: '',
      targetPid: 4242,
      targetProcessIdentity: processAdmission.identity,
      videoSource: 'windows-graphics-capture:hwnd=0x0000000000012345:size=1280x720',
      processTree: [processAdmission.identity, 'pid:500:created:133700000000000002'],
      endpointSessions: [],
    },
    ...overrides,
  };
}

function finalizedEvent(overrides = {}) {
  return {
    type: 'finalized',
    requestId: 'cap-token-1',
    ack: 'final',
    recorder: 'pid:9001:created:133700000000000001',
    original: { path: 'C:/artifacts/cap-token-1/original.mp4', byteLength: 64 },
    tracks: { video: 0, audio: 1 },
    pts: { video: { first100ns: 0, last100ns: 100000, samples: 3 }, audio: { first100ns: 0, last100ns: 96000, samples: 3 } },
    clock: { qpcFrequency: 10000000, qpcStart: 5555 },
    source: startedEvent().source,
    native: { audioPackets: 3 },
    ...overrides,
  };
}

const rejects = (promise, code) => assert.rejects(promise, error => error.message.includes(code));

test('request file carries only machine-validated capture fields', () => {
  const request = buildCaptureRequest({
    mode: 'owned-process-loopback',
    ownershipToken: 'cap-token-1',
    artifactDirectory: 'C:/artifacts/cap-token-1',
    process: processAdmission,
    window,
    fps: 30,
    maxFrames: 900,
    ownedProcessIdentities: [processAdmission.identity],
  });
  const fields = Object.fromEntries(request.text.trim().split('\n').map(line => line.split(/=(.*)/s).slice(0, 2)));
  assert.equal(fields.schemaVersion, '1');
  assert.equal(fields.mode, 'owned-process-loopback');
  assert.equal(fields.hwnd, '0x0000000000012345');
  assert.equal(fields.targetPid, '4242');
  assert.equal(fields.ownershipToken, 'cap-token-1');
  assert.equal(fields.owned, processAdmission.identity);
  assert.equal(request.outputPath, 'C:/artifacts/cap-token-1/original.mp4');
  assert.equal(request.path, 'C:/artifacts/cap-token-1/capture.request.txt');
  assert.ok(request.text.endsWith('\n'));
});

test('invalid requests fail closed before any helper exists', () => {
  const valid = {
    mode: 'owned-process-loopback',
    ownershipToken: 'cap-token-1',
    artifactDirectory: 'C:/artifacts/x',
    process: processAdmission,
    window,
  };
  assert.throws(() => buildCaptureRequest({ ...valid, mode: 'screen-scrape' }), /CAPTURE_MODE_INVALID/);
  assert.throws(() => buildCaptureRequest({ ...valid, window: { hwnd: '0x1' } }), /CAPTURE_WINDOW_REQUIRED/);
  assert.throws(() => buildCaptureRequest({ ...valid, artifactDirectory: 'relative/dir' }), /CAPTURE_ARTIFACT_DIRECTORY_INVALID/);
  assert.throws(() => buildCaptureRequest({ ...valid, process: { pid: 7, identity: 'pid:8:created:9' } }), /CAPTURE_PROCESS_IDENTITY_MISMATCH/);
  assert.throws(() => buildCaptureRequest({ ...valid, ownershipToken: '' }), /CAPTURE_OWNERSHIP_TOKEN_REQUIRED/);
  assert.throws(() => buildCaptureRequest({ ...valid, ownershipToken: 'id\nmode=other' }), /CAPTURE_OWNERSHIP_TOKEN_REQUIRED/);
  assert.throws(() => buildCaptureRequest({ ...valid, artifactDirectory: 'C:/x\rother' }), /CAPTURE_ARTIFACT_DIRECTORY_INVALID/);
});

test('existing artifacts refuse allocation and request overwrite', async () => {
  const options = makeOptions({ pathExists: () => true });
  await rejects(openCapture(options).start(), 'CAPTURE_ARTIFACT_EXISTS');
  assert.equal(options.children.length, 0);
});

test('synchronously buffered startup and stop events keep no timeout handles', async () => {
  const options = makeOptions({ spawnProcess: () => {
    const child = fakeChild();
    options.children.push(child);
    child.emitLine(JSON.stringify(startedEvent()));
    return child;
  } });
  const handle = openCapture(options);
  await handle.start();
  await handle.close();
  assert.equal(options.timers.size, 0);
});

test('unobserved exit remains an unresolved resource under cancellation', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  await handle.start(); await handle.finalize();
  options.children[0].stdin.write = () => true;
  options.children[0].kill = () => true;
  const controller = new AbortController(); controller.abort();
  await rejects(handle.close(controller.signal), 'CAPTURE_CLEANUP_UNRESOLVED');
  assert.equal(options.timers.size, 0);
});

test('argument vector never uses a shell', () => {
  const argv = captureArgv('C:/root/helper.exe', 'C:/artifacts/req.txt');
  assert.deepEqual(argv, ['--request', 'C:/artifacts/req.txt']);
  assert.throws(() => captureArgv('helper.exe', 'C:/artifacts/req.txt'), /CAPTURE_HELPER_INVALID/);
  assert.throws(() => captureArgv('C:/root/helper.exe', 'req.txt'), /CAPTURE_REQUEST_PATH_INVALID/);
});

test('events parse strictly and malformed lines are refused', () => {
  assert.equal(parseEvent(''), null);
  assert.equal(parseEvent('   '), null);
  assert.deepEqual(parseEvent('{"type":"started"}'), { type: 'started' });
  assert.throws(() => parseEvent('{"nope":1}'), /CAPTURE_EVENT_MALFORMED/);
  assert.throws(() => parseEvent('not-json'), /CAPTURE_EVENT_MALFORMED/);
});

test('lifecycle attempt is registered synchronously before any native start', () => {
  const options = makeOptions();
  const handle = openCapture(options);
  assert.equal(options.lifecycle.rows.length, 1);
  const row = options.lifecycle.rows[0];
  assert.equal(row.kind, 'capture');
  assert.equal(row.id, 'cap-token-1');
  assert.equal(handle.registeredBeforeStart, true);
  assert.equal(options.children.length, 0, 'no helper process may exist at registration');
});

test('start acknowledges only from a native started event carrying full identity', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  const started = await handle.start();
  assert.equal(started.acknowledged, true);
  assert.equal(started.recorder, 'pid:9001:created:133700000000000001');
  assert.deepEqual(started.clockAnchor, { qpcFrequency: 10000000, qpcStart: 5555, helperStartedAtMs: 1000 });
  assert.equal(started.sourceIdentity.targetPid, 4242);
  assert.equal(options.children.length, 1);
  assert.deepEqual(options.children[0].written, []);
  assert.equal(options.lifecycle.rows[0].acquired.pid, 9001);
  assert.equal(options.lifecycle.rows[0].acquired.ownershipToken, 'cap-token-1');
  assert.equal(handle.phase, 'running');
});

test('helper-reported window that differs from the admitted window is rejected', async () => {
  const options = makeOptions({
    spawnProcess: () => {
      const child = fakeChild();
      options.children.push(child);
      queueMicrotask(() => child.emitLine(JSON.stringify(startedEvent({
        source: { ...startedEvent().source, hwnd: '0x0000000000099999' },
      }))));
      return child;
    },
  });
  const handle = openCapture(options);
  await rejects(handle.start(), 'CAPTURE_SOURCE_MISMATCH:hwnd');
  assert.equal(options.children[0].killed, true);
});

test('native error events reject start instead of waiting out the timeout', async () => {
  const options = makeOptions({
    spawnProcess: () => {
      const child = fakeChild();
      options.children.push(child);
      queueMicrotask(() => child.emitLine(JSON.stringify({ type: 'error', code: 'VIDEO_PREPARE_FAILED' })));
      return child;
    },
  });
  const handle = openCapture(options);
  await rejects(handle.start(), 'CAPTURE_NATIVE_ERROR:VIDEO_PREPARE_FAILED');
});

// A prepare failure is only actionable when it names the native operation and HRESULT that failed;
// a bare code cannot separate an unsupported call from a refused format.
test('a native prepare failure carries the exact failing operation and HRESULT', async () => {
  const options = makeOptions({
    spawnProcess: () => {
      const child = fakeChild();
      options.children.push(child);
      queueMicrotask(() => child.emitLine(JSON.stringify({
        type: 'error', code: 'AUDIO_PREPARE_FAILED', operation: 'initialize', detail: '0x8000000E',
      })));
      return child;
    },
  });
  const handle = openCapture(options);
  await rejects(handle.start(), 'CAPTURE_NATIVE_ERROR:AUDIO_PREPARE_FAILED:initialize:0x8000000E');
});

// The two activation causes must stay distinguishable: a handler that could not be made agile and an
// activation the audio service refused are different defects, and each is reported without retrying.
test('each process-loopback activation failure names its own operation and never retries', async () => {
  for (const operation of ['create-agile-handler', 'activate-audio-interface']) {
    let spawns = 0;
    const options = makeOptions({
      spawnProcess: () => {
        spawns += 1;
        const child = fakeChild();
        options.children.push(child);
        queueMicrotask(() => child.emitLine(JSON.stringify({
          type: 'error', code: 'AUDIO_PREPARE_FAILED', operation, detail: '0x8000000E',
        })));
        return child;
      },
    });
    const handle = openCapture(options);
    await rejects(handle.start(), `CAPTURE_NATIVE_ERROR:AUDIO_PREPARE_FAILED:${operation}:0x8000000E`);
    assert.equal(spawns, 1, 'a failed activation must not spawn a second helper');
  }
});

// The mux names the exact negotiation step that failed and the formats offered, so a media-type
// refusal is attributable instead of a bare HRESULT.
test('a mux open failure carries the failing step and the offered formats', async () => {
  const options = makeOptions({
    spawnProcess: () => {
      const child = fakeChild();
      options.children.push(child);
      queueMicrotask(() => child.emitLine(JSON.stringify({
        type: 'error', code: 'MUX_OPEN_FAILED', operation: 'set-video-target',
        detail: 'set-video-target:0xC00D36B4:video=1602x1152@30/1:audio=44100Hz/2ch/16bit/align4',
      })));
      return child;
    },
  });
  const handle = openCapture(options);
  await rejects(handle.start(), 'CAPTURE_NATIVE_ERROR:MUX_OPEN_FAILED:set-video-target:set-video-target:0xC00D36B4:video=1602x1152@30/1:audio=44100Hz/2ch/16bit/align4');
});

// A stop that never completes must name the finalization stage the helper last entered. Without it a
// killed helper leaves the hang unattributed, which is exactly what the last live run produced.
test('a stop that never completes names the finalization stage the helper entered', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  const started = await handle.start();
  assert.equal(started.acknowledged, true);
  // The helper accepts the stop, publishes the stage it is entering, and then never finalizes.
  const child = options.children[0];
  child.stdin.write = chunk => {
    child.written.push(String(chunk));
    if (String(chunk).startsWith('stop')) {
      child.emitLine(JSON.stringify({ type: 'finalizing', requestId: 'cap-token-1', stage: 'audio-stop' }));
    }
    return true;
  };
  const pending = handle.finalize('driver-stop');
  for (const timer of [...options.timers]) timer();
  await assert.rejects(pending, error => /CAPTURE_EVENT_TIMEOUT:finalized:last-stage=audio-stop/.test(error.message));
  // The stage stays observable on the handle, so a reconciled run can report it too.
  assert.equal(handle.events().filter(event => event.type === 'finalizing').at(-1).stage, 'audio-stop');
});

// A finalize-time failure must surface the precise native operation and HRESULT. Reporting it as a mux
// failure with a bogus S_OK detail named the wrong operation and hid the real one.
test('a finalize failure surfaces the precise native operation and HRESULT', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  await handle.start();
  const child = options.children[0];
  child.stdin.write = chunk => {
    child.written.push(String(chunk));
    if (String(chunk).startsWith('stop')) {
      child.emitLine(JSON.stringify({
        type: 'error', code: 'VIDEO_CAPTURE_FAILED', operation: 'video-stop', hresult: '0x00000000',
        nativeFailure: 'frame-surface-bridge-failed:0x80004002',
        detail: 'frame-surface-bridge-failed:0x80004002:0x00000000',
      }));
    }
    return true;
  };
  await rejects(handle.finalize('driver-stop'),
    'CAPTURE_NATIVE_ERROR:VIDEO_CAPTURE_FAILED:video-stop:frame-surface-bridge-failed:0x80004002');
});

// An early abort must be attributable from what the helper itself wrote. The exit code alone cannot say
// why, and inferring a cause from the number is what this test forbids.
test('an early helper exit retains the exit code and the helper events it did write', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  await handle.start();
  const child = options.children[0];
  // The helper writes its own progress and then exits without ever emitting an error event.
  child.stdin.write = chunk => { child.written.push(String(chunk)); return true; };
  child.emitLine(JSON.stringify({ type: 'progress', phase: 'prepare-video' }));
  child.emitLine(JSON.stringify({ type: 'status', phase: 'starting' }));
  child.emit('close', 5, null);

  const failure = await handle.finalize('driver-stop').catch(error => error);
  assert.match(String(failure.message), /CAPTURE_EXIT_UNEXPECTED:5/);
  // The retained events travel with the failure, so the cause is read rather than inferred.
  assert.match(String(failure.message), /prepare-video/);

  const evidence = handle.nativeEvidence();
  assert.equal(evidence.exitCode, 5);
  assert.equal(evidence.stdoutTail.some(event => event.phase === 'prepare-video'), true);
  assert.equal(evidence.stdoutTail.some(event => event.phase === 'starting'), true);
});

// The retained tail is bounded, so a helper that writes without limit cannot grow the evidence.
test('the retained helper event tail is bounded', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  await handle.start();
  const child = options.children[0];
  child.stdin.write = chunk => { child.written.push(String(chunk)); return true; };
  for (let index = 0; index < 100; index++) child.emitLine(JSON.stringify({ type: 'progress', index }));
  child.emit('close', 5, null);
  await handle.finalize('driver-stop').catch(() => {});
  const evidence = handle.nativeEvidence();
  assert.ok(evidence.stdoutTail.length <= 32, 'tail bounded to 32 events');
  // The newest events are the ones kept.
  assert.equal(evidence.stdoutTail.at(-1).index, 99);
});

// A helper that writes an error event before aborting keeps that event, so the failing operation survives
// even when the exit code is one the protocol does not define.
test('an error event written before an early exit is retained as the native cause', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  await handle.start();
  const child = options.children[0];
  child.stdin.write = chunk => { child.written.push(String(chunk)); return true; };
  child.emitLine(JSON.stringify({ type: 'error', code: 'VIDEO_PREPARE_FAILED', operation: 'capture-item-create', detail: '0x80004005' }));
  child.emit('close', 5, null);
  await handle.finalize('driver-stop').catch(() => {});
  const evidence = handle.nativeEvidence();
  assert.equal(evidence.lastNativeError.code, 'VIDEO_PREPARE_FAILED');
  assert.equal(evidence.lastNativeError.operation, 'capture-item-create');
  assert.equal(evidence.exitCode, 5);
});

// Bounding must never corrupt the retained evidence. Slicing the serialized text could cut a string
// mid-escape and leave a payload that no longer parses, turning a readable native error into noise.
test('a bounded helper tail stays valid JSON and the structured error survives intact', async () => {
  const longDetail = 'x'.repeat(4000) + '"\\';
  const options = makeOptions();
  const handle = openCapture(options);
  await handle.start();
  const child = options.children[0];
  child.stdin.write = chunk => { child.written.push(String(chunk)); return true; };
  child.emitLine(JSON.stringify({ type: 'progress', note: longDetail }));
  child.emitLine(JSON.stringify({ type: 'status', note: longDetail }));
  child.emit('close', 5, null);
  const failure = await handle.finalize('driver-stop').catch(error => error);
  const message = String(failure.message);
  const prefix = 'CAPTURE_EXIT_UNEXPECTED:5:';
  assert.equal(message.startsWith(prefix), true);
  const parts = message.slice(prefix.length).split('|');
  // Every retained event is still parseable JSON: bounding happens per field, never on serialized text.
  const parsed = parts.map(part => JSON.parse(part));
  assert.equal(parsed.every(event => typeof event.type === 'string'), true);
  // The two long-note events survive bounded, and the start event in the same tail is untouched.
  const notes = parsed.filter(event => event.note !== undefined);
  assert.equal(notes.length, 2);
  for (const event of notes) assert.equal(event.note.length, 512);

  // The structured error is taken from the parsed original before any text bounding.
  const second = makeOptions();
  const errorHandle = openCapture(second);
  await errorHandle.start();
  const errorChild = second.children[0];
  errorChild.stdin.write = chunk => { errorChild.written.push(String(chunk)); return true; };
  errorChild.emitLine(JSON.stringify({ type: 'error', code: 'VIDEO_PREPARE_FAILED', operation: 'capture-item-create', detail: longDetail }));
  errorChild.emit('close', 5, null);
  await errorHandle.finalize('driver-stop').catch(() => {});
  const evidence = errorHandle.nativeEvidence();
  assert.equal(evidence.lastNativeError.code, 'VIDEO_PREPARE_FAILED');
  assert.equal(evidence.lastNativeError.operation, 'capture-item-create');
  assert.equal(evidence.lastNativeError.detail.length, 512);
});

// stderr is where a CRT/WinRT abort writes its reason. It is retained (bounded) and travels with an
// early-exit failure, so a hard death after the last stdout event is attributable instead of silent.
test('an early exit retains the helper stderr that explains it', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  await handle.start();
  const child = options.children[0];
  child.stdin.write = chunk => { child.written.push(String(chunk)); return true; };
  child.emitLine(JSON.stringify({ type: 'accepted', pid: 9001 }));
  child.stderr.write('capture-stop-unresolved:video-stop\n');
  child.emit('close', 3, null);

  const failure = await handle.finalize('driver-stop').catch(error => error);
  assert.match(String(failure.message), /CAPTURE_EXIT_UNEXPECTED:3/);
  assert.match(String(failure.message), /capture-stop-unresolved:video-stop/);
  const evidence = handle.nativeEvidence();
  assert.equal(evidence.stderrTail, 'capture-stop-unresolved:video-stop\n');
  assert.equal(evidence.stdoutTail.some(event => event.type === 'accepted'), true);
});

// The retained stderr is bounded so a helper that floods stderr cannot grow the evidence.
test('the retained stderr tail is bounded', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  await handle.start();
  const child = options.children[0];
  child.stdin.write = chunk => { child.written.push(String(chunk)); return true; };
  child.stderr.write('y'.repeat(10000));
  child.emit('close', 5, null);
  await handle.finalize('driver-stop').catch(() => {});
  assert.ok(handle.nativeEvidence().stderrTail.length <= 4096, 'stderr bounded to maxStderrBytes');
});

test('a native failure without a code still reports unknown', async () => {
  const options = makeOptions({
    spawnProcess: () => {
      const child = fakeChild();
      options.children.push(child);
      queueMicrotask(() => child.emitLine(JSON.stringify({ type: 'error' })));
      return child;
    },
  });
  const handle = openCapture(options);
  await rejects(handle.start(), 'CAPTURE_NATIVE_ERROR:unknown');
});

test('start cannot run twice and finalize cannot precede an acknowledged start', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  await rejects(handle.finalize('early'), 'CAPTURE_START_UNACKNOWLEDGED');
  await handle.start();
  await rejects(handle.start(), 'CAPTURE_ALREADY_STARTED');
});

test('finalize returns byte-identity hashes, track mapping and pts from the helper', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  await handle.start();
  const result = await handle.finalize('scenario-end');
  assert.equal(result.originalPath, 'C:/artifacts/cap-token-1/original.mp4');
  assert.equal(result.byteLength, 64);
  assert.equal(result.sha256, sha256Hex(Buffer.alloc(64)));
  assert.deepEqual(result.tracks, { video: 0, audio: 1 });
  assert.equal(result.pts.audio.samples, 3);
  assert.equal(result.sourceIdentity.recorderId, 'pid:9001:created:133700000000000001');
  assert.equal(result.nativeReport.audioPackets, 3);
  assert.deepEqual(options.children[0].written, ['stop\n']);
  assert.equal(handle.phase, 'finalized');
});

test('finalize refuses a helper that changes its clock anchor mid-session', async () => {
  const options = makeOptions({
    spawnProcess: () => {
      const child = fakeChild();
      options.children.push(child);
      queueMicrotask(() => child.emitLine(JSON.stringify(startedEvent())));
      child.stdin.write = () => {
        child.emitLine(JSON.stringify(finalizedEvent({ clock: { qpcFrequency: 10000000, qpcStart: 7777 } })));
        return true;
      };
      return child;
    },
  });
  const handle = openCapture(options);
  await handle.start();
  await rejects(handle.finalize('end'), 'CAPTURE_CLOCK_ANCHOR_CHANGED');
});

test('finalize refuses an original whose measured length disagrees with the helper', async () => {
  const options = makeOptions({ readBytes: async () => Buffer.alloc(16) });
  const handle = openCapture(options);
  await handle.start();
  await rejects(handle.finalize('end'), 'CAPTURE_ORIGINAL_LENGTH_MISMATCH');
});

test('reconcile trusts only a sidecar carrying the same ownership token', async () => {
  const recorded = {
    schemaVersion: 1,
    ownershipToken: 'cap-token-1',
    phase: 'finalized',
    original: { path: 'C:/artifacts/cap-token-1/original.mp4', byteLength: 64 },
    tracks: { video: 0, audio: 1 },
  };
  const options = makeOptions({ readBytes: async () => Buffer.from(JSON.stringify(recorded)) });
  const handle = openCapture(options);
  const state = await handle.reconcile();
  assert.equal(state.phase, 'finalized');
  assert.equal(state.ownershipToken, 'cap-token-1');
  assert.deepEqual(state.tracks, { video: 0, audio: 1 });

  const stale = makeOptions({ readBytes: async () => Buffer.from(JSON.stringify({ ...recorded, ownershipToken: 'other' })) });
  await rejects(openCapture(stale).reconcile(), 'CAPTURE_STATE_TOKEN_MISMATCH');
});

test('source receipt is refused while session isolation remains unproven', async () => {
  const isolated = startedEvent({
    source: {
      ...startedEvent().source,
      activationKind: 'endpoint-loopback',
      endpointId: '{0.0.0.00000000}.{9f9c77a0-1111-4b2a-9d5d-6f0d2a1b2c3d}',
      processTree: [],
      endpointSessions: [
        { identity: processAdmission.identity, identityObserved: true, active: true, systemSounds: false },
      ],
    },
  });
  const options = makeOptions({
    mode: 'isolated-owned-session-loopback',
    spawnProcess: () => {
      const child = fakeChild();
      options.children.push(child);
      queueMicrotask(() => child.emitLine(JSON.stringify(isolated)));
      child.stdin.write = chunk => {
        child.written.push(String(chunk));
        if (String(chunk).startsWith('stop')) {
          child.emitLine(JSON.stringify(finalizedEvent({ source: isolated.source })));
        }
        if (String(chunk).startsWith('quit')) child.emit('close', 0, null);
        return true;
      };
      return child;
    },
  });
  const handle = openCapture(options);
  await handle.start();
  const finalized = await handle.finalize('end');
  const expected = {
    sessionId: 'e/session',
    actorId: 'e/actor',
    studioId: 'e/studio',
    buildIdentity: 'e/build',
    runSha256: 'b'.repeat(64),
    clock: { offsetSeconds: 0.01, rate: 1, uncertaintySeconds: 0.004, driftSeconds: 0.000004, anchors: [{}, {}] },
  };
  const policy = { maxGapSeconds: 0.015 };
  assert.throws(
    () => buildSourceReceipt({ handle, finalized, expected, policy, isolation: { verified: false, unrelatedAudioExcluded: false, producers: [] } }),
    /CAPTURE_ISOLATION_UNPROVEN/,
  );
  assert.throws(() => buildSourceReceipt({ handle, finalized, expected, policy }), /CAPTURE_ISOLATION_UNPROVEN/);
});

test('source receipt binds native identity, acknowledgements and clock anchors', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  await handle.start();
  const finalized = await handle.finalize('end');
  const expected = {
    sessionId: 'e/session',
    actorId: 'e/actor',
    studioId: 'e/studio',
    buildIdentity: 'e/build',
    runSha256: 'b'.repeat(64),
    processIdentity: processAdmission.identity,
    clock: { offsetSeconds: 0.01, rate: 1, uncertaintySeconds: 0.004, driftSeconds: 0.000004, anchors: [{}, {}] },
  };
  const policy = { maxGapSeconds: 0.015 };
  const receipt = buildSourceReceipt({ handle, finalized, expected, policy });
  assert.equal(receipt.acquisition, 'owned-process-loopback');
  assert.equal(receipt.recorderId, 'pid:9001:created:133700000000000001');
  assert.equal(receipt.processIdentity, processAdmission.identity);
  assert.equal(receipt.startAcknowledgement, 'start');
  assert.equal(receipt.finalizeAcknowledgement, 'final');
  assert.equal(receipt.original.sha256, sha256Hex(Buffer.alloc(64)));
  assert.equal(receipt.policyDigest, sha256Hex(Buffer.from(canonicalJson(policy), 'utf8')));
  assert.equal(receipt.acquisitionDigest, sha256Hex(Buffer.from(canonicalJson(finalized.sourceIdentity), 'utf8')));
  assert.equal(receipt.finalized, true);
  assert.equal('listeningReport' in receipt, false);
  assert.equal('listeningCapability' in receipt, false);
  assert.equal(receipt.clock.anchors.length, 2);
});

test('close stops a running helper and reports what actually happened', async () => {
  const options = makeOptions();
  const handle = openCapture(options);
  await handle.start();
  const closed = await handle.close();
  assert.equal(closed.phase, 'stopped');
  assert.equal(closed.failure, null);
  assert.equal(options.children[0].written.includes('stop\n'), true);
});

test('helper path resolution prefers an existing build over the canonical path', () => {
  assert.equal(typeof resolveHelper('C:/root'), 'string');
  assert.equal(NATIVE_HELPER_RELATIVE_PATH, 'cli/forge/native/qualityav-capture/build/qualityav-capture.exe');
  assert.deepEqual([...CAPTURE_MODES], ['owned-process-loopback', 'isolated-owned-session-loopback']);
});
