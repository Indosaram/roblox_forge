import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { resolve } from 'node:path';
import { sha256, validateProvenance, validateCoverage, inspectAudio, runOwned, capabilityStatus } from './qualityav.mjs';

function fixture() {
  const bytes = Buffer.from('fixture container bytes, not actual captured media');
  const expected = { sessionId: 'session', actorId: 'actor', studioId: 'client', buildIdentity: 'build', runSha256: 'run', processIdentity: 'pid-created', recorderId: 'recorder', audioEndpoint: 'endpoint', videoSource: 'client-surface', acquisitionDigest: 'acquisition',
    acquisition: 'owned-process-loopback', finalized: true, startAcknowledgement: 'start', finalizeAcknowledgement: 'final', tracks: { video: 0, audio: 1 },
    clock: { offsetSeconds: 0, rate: 1, uncertaintySeconds: 0, driftSeconds: 0, anchors: [{ ptsSeconds: 0, actionSeconds: 0 }, { ptsSeconds: 2, actionSeconds: 2 }] } };
  const manifest = { ...structuredClone(expected), schemaVersion: 1, original: { sha256: sha256(bytes), byteLength: bytes.length } };
  const probe = { streams: [{ index: 0, codec_type: 'video', codec_name: 'rawvideo' }, { index: 1, codec_type: 'audio', codec_name: 'pcm_f32le', sample_rate: '4', channels: 1 }],
    frames: [0, 1].flatMap(time => [{ stream_index: 0, best_effort_timestamp_time: String(time), duration_time: '1' }, { stream_index: 1, best_effort_timestamp_time: String(time), nb_samples: 4 }]) };
  const hashes = [sha256('first'), sha256('second')];
  const policy = { maxGapSeconds: 0, maxClockErrorSeconds: 0, intervals: [{ id: 'gather', start: 0, end: 2, motion: true }] };
  return { bytes, expected, manifest, probe, hashes, policy };
}

test('original container and independently supplied track/session association are required', () => {
  const f = fixture();
  assert.equal(validateProvenance(f.manifest, f.bytes, f.expected), true);
  assert.throws(() => validateProvenance(f.manifest, Buffer.from('swapped WAV'), f.expected), /ORIGINAL_MISMATCH/);
  for (const key of ['sessionId', 'actorId', 'studioId', 'buildIdentity', 'runSha256', 'processIdentity', 'recorderId', 'audioEndpoint', 'videoSource', 'acquisitionDigest']) {
    assert.throws(() => validateProvenance({ ...f.manifest, [key]: 'swapped' }, f.bytes, f.expected), /SOURCE_MISMATCH/);
  }
  assert.throws(() => validateProvenance({ ...f.manifest, tracks: { audio: 0, video: 1 } }, f.bytes, f.expected), /TRACK_SOURCE_MISMATCH/);
  assert.throws(() => validateProvenance(f.manifest, f.bytes, { ...f.expected, finalized: false }), /ACQUISITION_UNPROVEN/);
});

test('full synchronized intervals reject truncated static gapped or shifted tracks', () => {
  const f = fixture();
  assert.equal(validateCoverage(f.manifest, f.probe, f.hashes, f.policy).audio.length, 2);
  assert.throws(() => validateCoverage(f.manifest, f.probe, [f.hashes[0], f.hashes[0]], f.policy), /STATIC_MOTION/);
  const truncated = structuredClone(f.probe);
  truncated.frames.pop();
  assert.throws(() => validateCoverage(f.manifest, truncated, f.hashes, f.policy), /TRUNCATED/);
  const gap = structuredClone(f.probe);
  gap.frames[1].nb_samples = 2;
  assert.throws(() => validateCoverage(f.manifest, gap, f.hashes, f.policy), /AV_GAP/);
  const shifted = structuredClone(f.manifest);
  shifted.clock.offsetSeconds = 1;
  assert.throws(() => validateCoverage(shifted, f.probe, f.hashes, f.policy), /TRUNCATED/);
  shifted.clock.driftSeconds = 0.1;
  assert.throws(() => validateCoverage(shifted, f.probe, f.hashes, f.policy), /CLOCK_ERROR/);
  assert.throws(() => validateCoverage(f.manifest, f.probe, [], f.policy), /FRAME_COUNT/);
});

test('independently verified isolated owned session mix is admissible without per-client endpoints', () => {
  const f = fixture();
  f.expected.acquisition = f.manifest.acquisition = 'isolated-owned-session-loopback';
  f.expected.isolation = { verified: true, receipt: 'isolated-endpoint-receipt', unrelatedAudioExcluded: true,
    producers: [{ processIdentity: 'pid-created', actorId: 'actor', sessionId: 'session', owned: true }] };
  f.manifest.isolation = structuredClone(f.expected.isolation);
  assert.equal(validateProvenance(f.manifest, f.bytes, f.expected), true);
  f.expected.isolation.unrelatedAudioExcluded = false;
  assert.throws(() => validateProvenance(f.manifest, f.bytes, f.expected), /SESSION_MIX_UNPROVEN/);
});

function processFixture() {
  const child = new EventEmitter();
  child.pid = 123;
  child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
  child.kill = () => { child.emit('close', null, 'SIGKILL'); return true; };
  const timers = new Set();
  const options = { timeoutMs: 100, maxBytes: 32,
    schedule: callback => { timers.add(callback); return callback; }, unschedule: callback => timers.delete(callback),
    spawnProcess: (_executable, _args, config) => { assert.equal(config.windowsHide, true); assert.equal(config.shell, false); return child; } };
  return { child, options, timers };
}

test('decoded samples reject silence truncation and nonfinite audio without claiming listening', () => {
  const f = fixture();
  const coverage = validateCoverage(f.manifest, f.probe, f.hashes, f.policy);
  const pcm = Buffer.alloc(32);
  assert.throws(() => inspectAudio(pcm, f.manifest, f.probe, coverage, f.policy), /SILENT_TRACK/);
  pcm.writeFloatLE(0.5, 0);
  assert.equal(inspectAudio(pcm, f.manifest, f.probe, coverage, f.policy).nonzero, 1);
  const policy = { ...f.policy, intervals: [{ id: 'craft', start: 1, end: 2, motion: false, audioRequired: true }] };
  assert.throws(() => inspectAudio(pcm, f.manifest, f.probe, coverage, policy), /SILENT_INTERVAL/);
  assert.throws(() => inspectAudio(pcm.subarray(0, 28), f.manifest, f.probe, coverage, f.policy), /SAMPLE_COUNT/);
  pcm.writeFloatLE(NaN, 0);
  assert.throws(() => inspectAudio(pcm, f.manifest, f.probe, coverage, f.policy), /NONFINITE_AUDIO/);
});

test('owned decoder succeeds only on observed close and records cleanup', async () => {
  const f = processFixture();
  const pending = runOwned(resolve('decoder.exe'), ['-version'], f.options);
  f.child.stdout.emit('data', Buffer.from('version'));
  f.child.emit('close', 0, null);
  const result = await pending;
  assert.equal(result.stdout.toString(), 'version');
  assert.equal(result.cleanup.ok, true);
  assert.equal(f.timers.size, 0);
});

test('output bounds timeout cancellation and bad exit cannot pass', async () => {
  for (const mode of ['output', 'timeout', 'cancel', 'exit', 'spawn']) {
    const f = processFixture();
    const controller = new AbortController();
    const pending = runOwned(resolve('decoder.exe'), [], { ...f.options, signal: controller.signal });
    const rejected = assert.rejects(pending, /AV_/);
    if (mode === 'output') f.child.stdout.emit('data', Buffer.alloc(33));
    if (mode === 'timeout') [...f.timers][0]();
    if (mode === 'cancel') controller.abort();
    if (mode === 'exit') f.child.emit('close', 1, null);
    if (mode === 'spawn') f.child.emit('error', new Error('missing decoder'));
    await rejected;
    assert.equal(f.timers.size, 0);
  }
});

test('capabilities and image-only claims never mint approval', () => {
  const absent = capabilityStatus();
  assert.equal(absent.releaseApproved, false);
  assert.equal(absent.blockers.length, 3);
  const imageOnly = capabilityStatus({ listening: { api: 'images', audioInput: false, temporalVideoInput: false, commercialUse: true, verifiedReceipt: 'claim' } });
  assert.ok(imageOnly.blockers.includes('LISTENING_CAPABILITY_UNPROVEN'));
  assert.equal(imageOnly.verdict, 'inconclusive');
});
