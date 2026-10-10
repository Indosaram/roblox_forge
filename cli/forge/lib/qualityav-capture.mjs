// Owned background capture hook around the native qualityav-capture helper.
//
// This module never performs capture itself and never invents authority: the
// native helper is the only source of process-creation identity, HWND
// association, QPC clocks and the original muxed container. Everything this
// module adds is either (a) validation of what the helper reported against the
// independently admitted session facts, or (b) byte-identity hashing of the
// finalized original. No listening result is ever produced here.
//
// Lifecycle contract: openCapture() registers the ownership token with the
// caller's StudioLifecycle BEFORE any native process is started, so an
// allocation attempt is always reconcilable even if its response is lost.
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { join, isAbsolute, resolve } from 'node:path';

export const NATIVE_HELPER_RELATIVE_PATH = 'cli/forge/native/qualityav-capture/build/qualityav-capture.exe';
export const CAPTURE_MODES = Object.freeze(['owned-process-loopback', 'isolated-owned-session-loopback']);

const demand = (condition, code) => { if (!condition) throw new Error(code); };
const text = value => typeof value === 'string' && value.trim().length > 0;
const hex64 = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const int = value => Number.isSafeInteger(value) && value >= 0;
// Every value that is serialized into the key=value request file must be free
// of line breaks and control bytes, otherwise a crafted value could inject an
// extra request field instead of being rejected.
const noInjection = (value, code) => {
  demand(typeof value === 'string' && value.length > 0, code);
  demand(!/[\r\n\x00-\x1f]/.test(value), code);
  return value;
};

export const sha256Hex = bytes => createHash('sha256').update(bytes).digest('hex');

// Stable JSON used for the acquisition digest; the same value is copied into
// the shared AV manifest by the integrating owner, never recomputed there.
export function canonicalJson(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(canonicalJson).join(',') + ']';
  return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonicalJson(value[key])).join(',') + '}';
}

// Build layout differs by generator (multi-config VS writes Release/, single
// config Ninja writes the binary directly), so the first existing candidate wins
// and the canonical path is the fallback when nothing has been built yet.
const HELPER_CANDIDATES = [
  NATIVE_HELPER_RELATIVE_PATH,
  'cli/forge/native/qualityav-capture/build/Release/qualityav-capture.exe',
  'build/task16-qualityav-native/Release/qualityav-capture.exe',
  'build/task16-qualityav-native/qualityav-capture.exe',
];
export function resolveHelper(root) {
  for (const relative of HELPER_CANDIDATES) {
    const candidate = join(root, relative);
    if (existsSync(candidate)) return candidate;
  }
  return join(root, NATIVE_HELPER_RELATIVE_PATH);
}

const IDENTITY = /^pid:(\d+):created:(\d+)$/;

// The request file is key=value text so the native side needs no JSON parser.
export function buildCaptureRequest(spec) {
  demand(spec && typeof spec === 'object', 'CAPTURE_REQUEST_REQUIRED');
  const mode = spec.mode;
  demand(CAPTURE_MODES.includes(mode), 'CAPTURE_MODE_INVALID');
  noInjection(spec.ownershipToken, 'CAPTURE_OWNERSHIP_TOKEN_REQUIRED');
  demand(text(spec.artifactDirectory) && isAbsolute(spec.artifactDirectory), 'CAPTURE_ARTIFACT_DIRECTORY_INVALID');
  noInjection(spec.artifactDirectory, 'CAPTURE_ARTIFACT_DIRECTORY_INVALID');
  demand(spec.process && int(spec.process.pid) && spec.process.pid > 0, 'CAPTURE_PROCESS_REQUIRED');
  demand(text(spec.process.identity) && IDENTITY.test(spec.process.identity), 'CAPTURE_PROCESS_IDENTITY_REQUIRED');
  const [, pidText, createdText] = spec.process.identity.match(IDENTITY);
  demand(Number(pidText) === spec.process.pid, 'CAPTURE_PROCESS_IDENTITY_MISMATCH');
  demand(spec.window && /^0x[0-9a-f]{16}$/i.test(String(spec.window.hwnd)), 'CAPTURE_WINDOW_REQUIRED');
  demand(mode !== 'owned-process-loopback' || int(spec.process.pid), 'CAPTURE_TARGET_PID_REQUIRED');

  const endpointId = mode === 'isolated-owned-session-loopback' ? String(spec.endpointId ?? '') : '';
  if (endpointId !== '') noInjection(endpointId, 'CAPTURE_ENDPOINT_ID_INVALID');
  // The request file is consumed by the native helper and asserted by tests as
  // forward-slashed, so normalize whatever separators join produced.
  const outputPath = join(spec.artifactDirectory, 'original.mp4').replaceAll('\\', '/');
  const statePath = join(spec.artifactDirectory, 'capture.state.json').replaceAll('\\', '/');
  const requestPath = join(spec.artifactDirectory, 'capture.request.txt').replaceAll('\\', '/');
  noInjection(outputPath, 'CAPTURE_ARTIFACT_DIRECTORY_INVALID');
  noInjection(statePath, 'CAPTURE_ARTIFACT_DIRECTORY_INVALID');
  noInjection(requestPath, 'CAPTURE_ARTIFACT_DIRECTORY_INVALID');

  const lines = [
    'schemaVersion=1',
    'requestId=' + spec.ownershipToken,
    'mode=' + mode,
    'outputPath=' + outputPath,
    'statePath=' + statePath,
    'hwnd=' + String(spec.window.hwnd),
    'targetPid=' + spec.process.pid,
    'includeTree=' + (spec.includeProcessTree === false ? 'false' : 'true'),
    'endpointId=' + endpointId,
    'fps=' + (int(spec.fps) && spec.fps > 0 && spec.fps <= 120 ? spec.fps : 30),
    'maxFrames=' + (int(spec.maxFrames) ? spec.maxFrames : 0),
    'maxDurationMs=' + (int(spec.maxDurationMs) ? spec.maxDurationMs : 0),
    'ownershipToken=' + spec.ownershipToken,
  ];
  for (const owner of spec.ownedProcessIdentities ?? []) {
    demand(text(owner) && IDENTITY.test(owner), 'CAPTURE_OWNED_PROCESS_IDENTITY_INVALID');
    lines.push('owned=' + owner);
  }
  return {
    text: lines.join('\n') + '\n',
    path: requestPath,
    outputPath,
    statePath,
  };
}

export function captureArgv(helperPath, requestPath) {
  demand(text(helperPath) && isAbsolute(helperPath), 'CAPTURE_HELPER_INVALID');
  demand(text(requestPath) && isAbsolute(requestPath), 'CAPTURE_REQUEST_PATH_INVALID');
  return ['--request', requestPath];
}

export function parseEvent(line) {
  const trimmed = String(line ?? '').trim();
  if (!trimmed) return null;
  let event;
  try { event = JSON.parse(trimmed); } catch { throw new Error('CAPTURE_EVENT_MALFORMED'); }
  demand(event && typeof event === 'object' && text(event.type), 'CAPTURE_EVENT_MALFORMED');
  return event;
}

// Validates the source identity the native helper reported against the facts
// that were admitted independently. A helper that reports anything else fails
// closed: the wrapper cannot substitute its own values for native evidence.
// The HWND owner the helper reports must be an identity that was admitted
// independently BEFORE capture started: an explicitly pinned actor client
// identity, a client identity from admission.clients, or the job-contained
// process identity. An ambient pid that was never admitted can never match.
function buildAdmittedOwners(options, admissionProcess, clients) {
  const owners = [];
  if (text(options.windowOwnerIdentity)) owners.push(options.windowOwnerIdentity);
  for (const client of clients) if (client && text(client.identity)) owners.push(client.identity);
  owners.push(admissionProcess.identity);
  return [...new Set(owners)];
}

function checkSourceIdentity(source, expected, mode) {
  demand(source && typeof source === 'object', 'CAPTURE_SOURCE_IDENTITY_MISSING');
  demand(text(source.recorderId) && IDENTITY.test(source.recorderId), 'CAPTURE_RECORDER_IDENTITY_MISSING');
  demand(text(source.hwnd) && source.hwnd.toLowerCase() === expected.window.hwnd.toLowerCase(), 'CAPTURE_SOURCE_MISMATCH:hwnd');
  demand(source.windowOwner && text(source.windowOwner.identity) && IDENTITY.test(source.windowOwner.identity),
    'CAPTURE_WINDOW_OWNER_MISSING');
  demand(source.windowOwner.identity === expected.process.identity,
    'CAPTURE_SOURCE_MISMATCH:windowOwner');
  demand(text(source.audioEndpoint), 'CAPTURE_AUDIO_ENDPOINT_MISSING');
  demand(Number.isInteger(source.targetPid) && source.targetPid === expected.process.pid,
    'CAPTURE_SOURCE_MISMATCH:targetPid');
  if (mode === 'owned-process-loopback') {
    demand(source.activationKind === 'process-loopback', 'CAPTURE_SOURCE_MISMATCH:activationKind');
    demand(Array.isArray(source.processTree) && source.processTree.includes(expected.process.identity),
      'CAPTURE_PROCESS_TREE_MISSING_TARGET');
  } else {
    demand(source.activationKind === 'endpoint-loopback' && text(source.endpointId), 'CAPTURE_SOURCE_MISMATCH:activationKind');
    demand(Array.isArray(source.endpointSessions), 'CAPTURE_ENDPOINT_SESSIONS_MISSING');
  }
  return true;
}

function sourceIdentityOf(event, spec) {
  const source = event.source;
  checkSourceIdentity(source, spec, spec.mode);
  return source;
}

/**
 * Registers ownership before anything is allocated and returns the driver hook.
 *
 * @param {object} options
 * @param {object} options.sources        scenario.audiovisualSources map this capture will back
 * @param {object} options.process        admission.process {pid, identity} (job-contained editor PID)
 * @param {Array}  options.clients        admission.clients [{actorId, studioId, pid?, identity?}]
 * @param {string} options.ownershipToken unique token for this capture attempt
 * @param {string} options.artifactDirectory absolute directory for original.mp4 + state sidecar
 * @param {object} options.lifecycle      StudioLifecycle: attempt() is called synchronously here
 * @returns {{start: Function, finalize: Function, reconcile: Function, close: Function}}
 */
// The helper is the only thing that can say why it aborted, so its own events are retained verbatim
// and bounded. A bare exit code cannot attribute an early abort, and inferring one from the code alone
// is exactly the mistake this prevents.
const NATIVE_TAIL_MAX = 32;
const NATIVE_EVENT_MAX = 512;

/**
 * Bounds one parsed helper event WITHOUT corrupting it. Every field is truncated independently and nested
 * values are re-serialized, so the result is always valid JSON. Slicing the serialized text instead could
 * cut a string mid-escape and leave a payload that no longer parses - which is how a truncated tail turns
 * a readable native error into noise.
 */
export function boundNativeEvent(event) {
  if (!event || typeof event !== 'object') return { type: 'unparsed', value: String(event ?? '').slice(0, NATIVE_EVENT_MAX) };
  const bounded = {};
  for (const [key, value] of Object.entries(event)) {
    if (typeof value === 'string') bounded[key] = value.slice(0, NATIVE_EVENT_MAX);
    else if (value !== null && typeof value === 'object') bounded[key] = JSON.stringify(value).slice(0, NATIVE_EVENT_MAX);
    else bounded[key] = value;
  }
  return bounded;
}

export function openCapture(options = {}) {
  const { sources, process: admissionProcess, clients, ownershipToken, artifactDirectory, lifecycle } = options;
  demand(sources && typeof sources === 'object' && Object.keys(sources).length > 0, 'CAPTURE_SOURCES_REQUIRED');
  demand(admissionProcess && int(admissionProcess.pid) && text(admissionProcess.identity), 'CAPTURE_PROCESS_REQUIRED');
  demand(Array.isArray(clients) && clients.length > 0, 'CAPTURE_CLIENTS_REQUIRED');
  demand(text(ownershipToken), 'CAPTURE_OWNERSHIP_TOKEN_REQUIRED');
  demand(lifecycle && typeof lifecycle.attempt === 'function', 'CAPTURE_LIFECYCLE_REQUIRED');
  demand(options.window && /^0x[0-9a-f]{16}$/i.test(String(options.window.hwnd)), 'CAPTURE_WINDOW_REQUIRED');
  const mode = options.mode ?? 'owned-process-loopback';
  demand(CAPTURE_MODES.includes(mode), 'CAPTURE_MODE_INVALID');

  const deps = {
    spawnProcess: options.spawnProcess ?? spawn,
    schedule: options.schedule ?? setTimeout,
    unschedule: options.unschedule ?? clearTimeout,
    readBytes: options.readBytes ?? readFile,
    writeBytes: options.writeBytes ?? writeFile,
    makeDirectory: options.makeDirectory ?? mkdir,
    sha256Bytes: options.sha256Bytes ?? sha256Hex,
    helperPath: options.helperPath ?? (options.root ? resolveHelper(options.root) : null),
    startTimeoutMs: options.startTimeoutMs ?? 30000,
    finalizeTimeoutMs: options.finalizeTimeoutMs ?? 120000,
    maxEventBytes: options.maxEventBytes ?? 4 * 1024 * 1024,
    maxStderrBytes: options.maxStderrBytes ?? 4096,
    pathExists: options.pathExists ?? (path => existsSync(path)),
  };
  demand(text(deps.helperPath) && isAbsolute(deps.helperPath), 'CAPTURE_HELPER_INVALID');

  const spec = {
    mode,
    ownershipToken,
    artifactDirectory,
    process: admissionProcess,
    window: options.window,
    endpointId: options.endpointId ?? '',
    includeProcessTree: options.includeProcessTree !== false,
    fps: options.fps,
    maxFrames: options.maxFrames,
    maxDurationMs: options.maxDurationMs,
    ownedProcessIdentities: options.ownedProcessIdentities ?? [],
    admittedWindowOwners: buildAdmittedOwners(options, admissionProcess, clients),
  };
  demand(spec.admittedWindowOwners.length > 0, 'CAPTURE_WINDOW_OWNER_NOT_ADMITTED');
  const request = buildCaptureRequest(spec);

  const state = {
    phase: 'registered',
    child: null,
    closed: false,
    exitCode: null,
    exitSignal: null,
    started: null,
    finalized: null,
    bytes: 0,
    failure: null,
    stderrTail: '',
    // Bounded helper stdout: every parsed event, plus any line that did not parse. Newest last.
    stdoutTail: [],
    lastNativeError: null,
    events: [],
    waiters: [],
    stdin: null,
    detach: null,
  };

  const closedPromise = new Promise(resolve => { state.resolveClosed = resolve; });
  const emit = event => {
    state.events.push(event);
    for (const waiter of [...state.waiters]) {
      if (waiter.type === event.type || waiter.type === '*') {
        state.waiters.splice(state.waiters.indexOf(waiter), 1);
        state.unschedule?.(waiter.timer);
        waiter.resolve(event);
      }
    }
  };
  const fail = code => {
    state.failure ??= code;
    for (const waiter of [...state.waiters]) {
      state.waiters.splice(state.waiters.indexOf(waiter), 1);
      state.unschedule?.(waiter.timer);
      waiter.reject(new Error(code));
    }
  };
  const waitFor = (type, timeoutMs) => new Promise((resolve, reject) => {
    if (state.failure) return reject(new Error(state.failure));
    const prior = state.events.find(event => event.type === type);
    if (prior) return resolve(prior);
    const waiter = { type, resolve, reject, timer: null };
    waiter.timer = deps.schedule(() => {
      const index = state.waiters.indexOf(waiter);
      if (index >= 0) state.waiters.splice(index, 1);
      reject(new Error('CAPTURE_EVENT_TIMEOUT:' + type));
    }, timeoutMs);
    state.waiters.push(waiter);
  });

  const awaitClose = async (milliseconds, signal) => {
    let timer, abort;
    try {
      return await Promise.race([closedPromise.then(() => true), new Promise(resolve => {
        timer = deps.schedule(() => resolve(false), milliseconds);
        abort = () => resolve(false);
        signal?.addEventListener('abort', abort, { once: true });
        if(signal?.aborted) abort();
      })]);
    } finally { deps.unschedule(timer); signal?.removeEventListener('abort', abort); }
  };

  // Registered BEFORE any native allocation so a lost start response still
  // leaves a reconcilable ownership row behind.
  const row = lifecycle.attempt('capture', ownershipToken, async (_row, signal) => {
    if(state.waiters.length) fail('CAPTURE_CLOSED');
    if (state.closed || !state.child) {
      return { released: true, evidence: { spawned: Boolean(state.child), exitCode: state.exitCode, signal: state.exitSignal, phase: state.phase } };
    }
    try { state.child.kill('SIGKILL'); } catch { /* already gone */ }
    const outcome = await awaitClose(10000, signal);
    if (!outcome || !state.closed) return { released: false, evidence: { spawned: true, phase: state.phase } };
    state.detach?.();
    return { released: true, evidence: { exitCode: state.exitCode, signal: state.exitSignal, phase: state.phase } };
  });
  state.unschedule = deps.unschedule;

  const handle = {
    ownershipToken,
    mode,
    request,
    registeredBeforeStart: true,

    async start() {
      demand(state.phase === 'registered', 'CAPTURE_ALREADY_STARTED');
      state.phase = 'starting';
      for(const path of [artifactDirectory,request.path,request.outputPath,request.statePath]) demand(!deps.pathExists(path), 'CAPTURE_ARTIFACT_EXISTS');
      await deps.makeDirectory(artifactDirectory, { recursive: false });
      await deps.writeBytes(request.path, Buffer.from(request.text, 'utf8'), { flag: 'wx' });
      const startedEvent = waitFor('started', deps.startTimeoutMs);
      startedEvent.catch(() => {});

      const child = deps.spawnProcess(deps.helperPath, captureArgv(deps.helperPath, request.path), {
        windowsHide: true,
        shell: false,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      state.child = child;
      state.stdin = child.stdin;
      if (child.pid) lifecycle.acquire(row, { pid: child.pid, helper: deps.helperPath, ownershipToken });

      let buffer = '';
      const recordNative = event => {
        // The structured copy is taken from the parsed original BEFORE any text bounding, so
        // lastNativeError always carries the real code/operation/detail of the failing operation.
        const bounded = boundNativeEvent(event);
        state.stdoutTail.push(bounded);
        if (state.stdoutTail.length > NATIVE_TAIL_MAX) state.stdoutTail.shift();
        if (event && event.type === 'error') state.lastNativeError = bounded;
      };
      const onChunk = chunk => {
        state.bytes += chunk.length;
        if (state.bytes > deps.maxEventBytes) { fail('CAPTURE_EVENT_OUTPUT_LIMIT'); try { child.kill('SIGKILL'); } catch {} return; }
        buffer += chunk.toString('utf8');
        const lines = buffer.split(/\r?\n/);
        buffer = lines.pop() ?? '';
        for (const line of lines) {
          if (!line.trim()) continue;
          let event = null;
          try { event = parseEvent(line); } catch (error) {
            recordNative({ type: 'unparsed', line: line.slice(0, NATIVE_EVENT_MAX) });
            fail(error.message);
            return;
          }
          if (!event) continue;
          recordNative(event);
          if (event.type === 'error') {
            // The helper names the exact failing native operation and its HRESULT; carrying both
            // keeps a prepare failure attributable instead of a bare code.
            const detail = [event.code, event.operation, event.detail].filter(text);
            fail('CAPTURE_NATIVE_ERROR:' + (detail.length ? detail.join(':') : 'unknown'));
            continue;
          }
          emit(event);
        }
      };
      child.stdout?.on('data', onChunk);
      // stderr is retained (bounded) rather than only counted: a CRT/WinRT abort writes its reason
      // there, and without it an early exit is attributable only from the exit code.
      const onStderr = chunk => {
        state.bytes += chunk.length;
        if(state.bytes > deps.maxEventBytes) { fail('CAPTURE_STDERR_LIMIT'); child.kill('SIGKILL'); return; }
        if (state.stderrTail.length < deps.maxStderrBytes) {
          state.stderrTail += chunk.toString('utf8').slice(0, deps.maxStderrBytes - state.stderrTail.length);
        }
      };
      child.stderr?.on('data', onStderr);
      const onError = () => { fail('CAPTURE_SPAWN_FAILED'); if(!child.pid) {state.closed=true;state.resolveClosed();} };
      child.once('error', onError);
      const onClose = (code, signalName) => {
        state.closed = true;
        state.exitCode = code;
        state.exitSignal = signalName;
        state.resolveClosed?.();
        if (state.phase !== 'finalized' && state.phase !== 'stopped') {
          // The exit code alone cannot attribute an early abort. The helper's own last events - including
          // the error event it did manage to write - are carried with it, so the cause is read rather
          // than inferred from the number. Each event is bounded per field, so the payload stays valid
          // JSON instead of being a sliced-off fragment.
          const tail = state.stdoutTail.slice(-4).map(event => JSON.stringify(event));
          const stderr = state.stderrTail.trim() ? ':' + state.stderrTail.trim().slice(0, 512) : '';
          fail('CAPTURE_EXIT_UNEXPECTED:' + code + (tail.length ? ':' + tail.join('|') : '') + stderr);
        }
      };
      child.once('close', onClose);
      state.detach = () => {child.stdout?.removeListener('data',onChunk);child.stderr?.removeListener('data',onStderr);child.removeListener('error',onError);child.removeListener('close',onClose);};

      try {
        const started = await startedEvent;
        const source = sourceIdentityOf(started, spec);
        demand(started.clock && Number.isFinite(started.clock.qpcFrequency) && started.clock.qpcFrequency > 0
          && Number.isFinite(started.clock.qpcStart), 'CAPTURE_CLOCK_ANCHOR_MISSING');
        demand(started.recorder && IDENTITY.test(started.recorder), 'CAPTURE_RECORDER_IDENTITY_MISSING');
        state.phase = 'running';
        state.started = {
          acknowledged: true,
          recorder: started.recorder,
          sourceIdentity: source,
          clockAnchor: {
            qpcFrequency: started.clock.qpcFrequency,
            qpcStart: started.clock.qpcStart,
            helperStartedAtMs: Number.isFinite(started.hostStartMs) ? started.hostStartMs : null,
          },
        };
        return state.started;
      } catch (error) {
        state.phase = 'failed';
        state.failure ??= error.message;
        try { child.kill('SIGKILL'); } catch { /* not started */ }
        throw error;
      }
    },

    // Driver must await start() before the first action and finalize() after
    // the last action of the session.
    async finalize(reason = 'driver-stop') {
      demand(state.phase === 'running' && state.started, 'CAPTURE_START_UNACKNOWLEDGED');
      demand(text(reason), 'CAPTURE_STOP_REASON_REQUIRED');
      state.phase = 'finalizing';
      const finalizedEvent = waitFor('finalized', deps.finalizeTimeoutMs);
      try { state.stdin?.write('stop\n'); } catch (error) { fail('CAPTURE_STOP_WRITE_FAILED:' + error.message); }
      let finalized;
      try {
        finalized = await finalizedEvent;
      } catch (error) {
        // Only a stop that never completed is attributed to a stage; a native error event already names
        // its own operation and HRESULT and must not have a stage appended to it.
        const stage = String(error?.message).startsWith('CAPTURE_EVENT_TIMEOUT')
          ? [...state.events].reverse().find(event => event.type === 'finalizing')?.stage
          : undefined;
        throw new Error(stage ? `${error.message}:last-stage=${stage}` : error.message);
      }

      const source = sourceIdentityOf(finalized, spec);
      demand(finalized.clock && finalized.clock.qpcStart === state.started.clockAnchor.qpcStart, 'CAPTURE_CLOCK_ANCHOR_CHANGED');
      const originalPath = finalized.original?.path;
      demand(text(originalPath) && isAbsolute(originalPath) && resolve(originalPath) === resolve(request.outputPath), 'CAPTURE_ORIGINAL_PATH_MISMATCH');
      const bytes = await deps.readBytes(originalPath);
      demand(bytes.length > 0 && bytes.length === Number(finalized.original.byteLength), 'CAPTURE_ORIGINAL_LENGTH_MISMATCH');
      const sha256 = deps.sha256Bytes(bytes);
      demand(finalized.tracks && int(finalized.tracks.video) && int(finalized.tracks.audio)
        && finalized.tracks.video !== finalized.tracks.audio, 'CAPTURE_TRACK_MAPPING_MISSING');

      state.phase = 'finalized';
      state.finalized = {
        originalPath,
        byteLength: bytes.length,
        sha256,
        tracks: { video: finalized.tracks.video, audio: finalized.tracks.audio },
        pts: finalized.pts ?? null,
        sourceIdentity: source,
        clockAnchor: state.started.clockAnchor,
        clock: finalized.clock,
        recorder: state.started.recorder,
        nativeReport: finalized.native ?? null,
      };
      return state.finalized;
    },

    // Reads the native-owned sidecar so an ambiguous stop (lost response,
    // helper exit) can still be reconciled from what the helper durably wrote.
    async reconcile() {
      const sidecar = await deps.readBytes(request.statePath);
      let recorded;
      try { recorded = JSON.parse(sidecar.toString('utf8')); } catch { throw new Error('CAPTURE_STATE_MALFORMED'); }
      demand(recorded && typeof recorded === 'object' && text(recorded.phase), 'CAPTURE_STATE_MALFORMED');
      demand(recorded.ownershipToken === ownershipToken, 'CAPTURE_STATE_TOKEN_MISMATCH');
      return { phase: recorded.phase, ownershipToken: recorded.ownershipToken, original: recorded.original ?? null, tracks: recorded.tracks ?? null, clock: recorded.clock ?? null, source: recorded.source ?? null, error: recorded.error ?? null };
    },

    async close(signal) {
      if (state.phase === 'running') {
        try { await handle.finalize('close'); } catch (error) { state.failure ??= error.message; }
      }
      if (state.child && !state.closed) {
        try { state.stdin?.write('quit\n'); } catch { /* already closed */ }
        const outcome = await awaitClose(5000,signal);
        if (!outcome) { try { state.child.kill('SIGKILL'); } catch { /* gone */ } await awaitClose(5000,signal); }
      }
      if(state.waiters.length) fail('CAPTURE_CLOSED');
      if(!state.closed && state.child)throw new Error('CAPTURE_CLEANUP_UNRESOLVED');
      state.detach?.();
      state.phase = state.phase === 'failed' ? 'failed' : (state.finalized ? 'stopped' : state.phase);
      return { phase: state.phase, exitCode: state.exitCode, signal: state.exitSignal, failure: state.failure, events: state.events.length };
    },

    get phase() { return state.phase; },
    get failure() { return state.failure; },
    // The retained native evidence for an early abort: the exit code and the helper's own bounded events.
    // `lastNativeError` is the structured parsed event, kept intact ahead of any text bounding.
    nativeEvidence: () => ({
      exitCode: state.exitCode,
      exitSignal: state.exitSignal,
      lastNativeError: state.lastNativeError ? { ...state.lastNativeError } : null,
      stdoutTail: state.stdoutTail.map(event => ({ ...event })),
      stderrTail: state.stderrTail,
    }),
    events: () => [...state.events],
  };
  return handle;
}

/**
 * Builds the sourceReceipt document consumed by the shared AV envelope. All
 * identity, clock, track and acknowledgement values come from the native
 * report; the caller only supplies the measured driver clock anchors and the
 * policy digest. Nothing here attests listening.
 */
export function buildSourceReceipt({ handle, finalized, expected, policy, isolation } = {}) {
  demand(finalized && finalized.sourceIdentity, 'CAPTURE_FINALIZED_REQUIRED');
  demand(expected && text(expected.sessionId) && text(expected.actorId) && text(expected.studioId)
    && text(expected.buildIdentity) && text(expected.runSha256), 'CAPTURE_EXPECTED_IDENTITY_REQUIRED');
  demand(policy && Number.isFinite(policy.maxGapSeconds), 'CAPTURE_POLICY_REQUIRED');
  const acquisition = handle.mode;
  const receipt = {
    schemaVersion: 1,
    acquisition,
    sessionId: expected.sessionId,
    actorId: expected.actorId,
    studioId: expected.studioId,
    buildIdentity: expected.buildIdentity,
    runSha256: expected.runSha256,
    processIdentity: finalized.sourceIdentity.windowOwner.identity,
    recorderId: finalized.recorder,
    audioEndpoint: finalized.sourceIdentity.audioEndpoint,
    videoSource: finalized.sourceIdentity.videoSource,
    targetProcessIdentity: expected.processIdentity ?? finalized.sourceIdentity.targetProcessIdentity,
    acquisitionDigest: sha256Hex(Buffer.from(canonicalJson(finalized.sourceIdentity), 'utf8')),
    finalized: true,
    startAcknowledgement: handle.events().find(event => event.type === 'started')?.ack ?? null,
    finalizeAcknowledgement: handle.events().find(event => event.type === 'finalized')?.ack ?? null,
    tracks: finalized.tracks,
    clock: expected.clock,
    policyDigest: sha256Hex(Buffer.from(canonicalJson(policy), 'utf8')),
    original: { path: finalized.originalPath, byteLength: finalized.byteLength, sha256: finalized.sha256 },
  };
  demand(text(receipt.startAcknowledgement), 'CAPTURE_START_ACK_MISSING');
  demand(text(receipt.finalizeAcknowledgement), 'CAPTURE_FINALIZE_ACK_MISSING');
  demand(receipt.clock && Array.isArray(receipt.clock.anchors) && receipt.clock.anchors.length === 2, 'CAPTURE_CLOCK_ANCHORS_REQUIRED');
  if (acquisition === 'isolated-owned-session-loopback') {
    // Client PID mapping may not exist yet; without it the mix cannot be proven
    // isolated, so the receipt is refused rather than silently downgraded.
    demand(isolation && isolation.verified === true && isolation.unrelatedAudioExcluded === true
      && Array.isArray(isolation.producers) && isolation.producers.length > 0
      && finalized.sourceIdentity.endpointId === isolation.endpointId
      && finalized.sourceIdentity.endpointSessions.length === isolation.producers.length
      && finalized.sourceIdentity.endpointSessions.every(session => session.identityObserved === true && session.systemSounds === false && isolation.producers.some(producer => producer.processIdentity === session.identity && producer.owned === true && producer.sessionId === expected.sessionId)), 'CAPTURE_ISOLATION_UNPROVEN');
    receipt.isolation = isolation;
  }
  return receipt;
}
