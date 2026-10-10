// Structural AV evidence, not a listening evaluator or release authority.
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdtemp, rm, stat } from 'node:fs/promises';
import { join, isAbsolute } from 'node:path';
import { StudioLifecycle } from '../qa/studio-driver-lifecycle.mjs';

export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const text = value => typeof value === 'string' && value.trim().length > 0;
const finite = Number.isFinite;
const demand = (condition, code) => { if (!condition) throw new Error(code); };
const hex = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);

// expected is supplied by the owned session adapter, never copied from media metadata.
// Its recorder receipt is an audit boundary, not a cryptographic proof of acquisition.
export function validateProvenance(manifest, bytes, expected) {
  demand(manifest?.schemaVersion === 1 && expected, 'AV_MANIFEST_REQUIRED');
  demand(hex(manifest.original?.sha256) && manifest.original.sha256 === sha256(bytes)
    && manifest.original.byteLength === bytes.length, 'AV_ORIGINAL_MISMATCH');
  for (const key of ['sessionId', 'actorId', 'studioId', 'buildIdentity', 'runSha256', 'processIdentity', 'recorderId', 'audioEndpoint', 'videoSource', 'acquisitionDigest']) {
    demand(text(expected[key]) && manifest[key] === expected[key], 'AV_SOURCE_MISMATCH:' + key);
  }
  demand(['owned-process-loopback', 'isolated-owned-session-loopback'].includes(expected.acquisition)
    && manifest.acquisition === expected.acquisition && expected.finalized === true
    && text(expected.startAcknowledgement) && text(expected.finalizeAcknowledgement), 'AV_ACQUISITION_UNPROVEN');
  if (expected.acquisition === 'isolated-owned-session-loopback') {
    demand(expected.isolation?.verified === true && text(expected.isolation.receipt)
      && expected.isolation.unrelatedAudioExcluded === true
      && Array.isArray(expected.isolation.producers) && expected.isolation.producers.length > 0
      && expected.isolation.producers.every(source => text(source.processIdentity) && text(source.actorId)
        && source.sessionId === expected.sessionId && source.owned === true)
      && JSON.stringify(manifest.isolation) === JSON.stringify(expected.isolation), 'AV_SESSION_MIX_UNPROVEN');
  }
  const { audio, video } = manifest.tracks || {};
  demand(Number.isInteger(audio) && audio >= 0 && Number.isInteger(video) && video >= 0 && audio !== video, 'AV_TRACK_MAPPING_REQUIRED');
  demand(audio === expected.tracks?.audio && video === expected.tracks?.video, 'AV_TRACK_SOURCE_MISMATCH');
  const clock = manifest.clock;
  demand(clock && JSON.stringify(clock) === JSON.stringify(expected.clock)
    && finite(clock.offsetSeconds) && finite(clock.rate) && clock.rate > 0
    && finite(clock.uncertaintySeconds) && clock.uncertaintySeconds >= 0
    && finite(clock.driftSeconds) && clock.driftSeconds >= 0, 'AV_CLOCK_UNPROVEN');
  demand(Array.isArray(clock.anchors) && clock.anchors.length === 2, 'AV_CLOCK_ANCHORS_REQUIRED');
  for (const anchor of clock.anchors) demand(finite(anchor.ptsSeconds) && finite(anchor.actionSeconds)
    && Math.abs(clock.offsetSeconds + anchor.ptsSeconds * clock.rate - anchor.actionSeconds)
      <= clock.uncertaintySeconds + clock.driftSeconds, 'AV_CLOCK_ANCHOR_MISMATCH');
  demand(clock.anchors[1].ptsSeconds > clock.anchors[0].ptsSeconds
    && clock.anchors[1].actionSeconds > clock.anchors[0].actionSeconds, 'AV_CLOCK_ANCHOR_ORDER');
  return true;
}

export function validateCoverage(manifest, probe, frameHashes, policy) {
  demand(policy && finite(policy.maxGapSeconds) && policy.maxGapSeconds >= 0
    && finite(policy.maxClockErrorSeconds) && policy.maxClockErrorSeconds >= 0
    && Array.isArray(policy.intervals) && policy.intervals.length > 0, 'AV_COVERAGE_POLICY_REQUIRED');
  const clock = manifest.clock;
  demand(clock.uncertaintySeconds + clock.driftSeconds <= policy.maxClockErrorSeconds, 'AV_CLOCK_ERROR');
  const streams = probe?.streams;
  demand(Array.isArray(streams) && Array.isArray(probe.frames), 'AV_PROBE_INVALID');
  const coverage = {};
  for (const kind of ['video', 'audio']) {
    const index = manifest.tracks[kind];
    const stream = streams.find(row => row.index === index);
    demand(stream?.codec_type === kind && text(stream.codec_name), 'AV_TRACK_TYPE_MISMATCH');
    if (kind === 'audio') demand(Number(stream.sample_rate) > 0 && Number.isInteger(stream.channels) && stream.channels > 0, 'AV_AUDIO_FORMAT_INVALID');
    const frames = probe.frames.filter(row => row.stream_index === index);
    demand(frames.length > 0, 'AV_EMPTY_TRACK');
    let previous = -Infinity;
    coverage[kind] = frames.map(frame => {
      const pts = Number(frame.best_effort_timestamp_time ?? frame.pts_time);
      const duration = kind === 'audio' ? Number(frame.nb_samples) / Number(stream.sample_rate)
        : Number(frame.duration_time ?? frame.pkt_duration_time);
      demand(finite(pts) && finite(duration) && duration > 0 && pts > previous, 'AV_FRAME_TIME_INVALID');
      previous = pts;
      return { start: clock.offsetSeconds + pts * clock.rate, end: clock.offsetSeconds + (pts + duration) * clock.rate };
    });
  }
  demand(frameHashes.length === coverage.video.length && frameHashes.every(hex), 'AV_DECODE_FRAME_COUNT');
  for (const interval of policy.intervals) {
    demand(text(interval.id) && finite(interval.start) && finite(interval.end) && interval.end > interval.start
      && typeof interval.motion === 'boolean', 'AV_INTERVAL_INVALID');
    demand(interval.start >= clock.anchors[0].actionSeconds && interval.end <= clock.anchors[1].actionSeconds, 'AV_CLOCK_COVERAGE');
    for (const kind of ['audio', 'video']) {
      const frames = coverage[kind].filter(frame => frame.end > interval.start && frame.start < interval.end);
      demand(frames.length > 0 && frames[0].start <= interval.start && frames.at(-1).end >= interval.end, 'AV_TRUNCATED:' + interval.id);
      for (let i = 1; i < frames.length; i++) demand(frames[i].start - frames[i - 1].end <= policy.maxGapSeconds, 'AV_GAP:' + interval.id);
    }
    if (interval.motion) {
      const hashes = frameHashes.filter((_hash, index) => coverage.video[index].end > interval.start && coverage.video[index].start < interval.end);
      demand(new Set(hashes).size > 1, 'AV_STATIC_MOTION:' + interval.id);
    }
  }
  return coverage;
}

export function inspectAudio(pcm, manifest, probe, coverage, policy) {
  const stream = probe.streams.find(row => row.index === manifest.tracks.audio);
  const frames = probe.frames.filter(row => row.stream_index === manifest.tracks.audio);
  const samples = frames.reduce((count, frame) => count + Number(frame.nb_samples), 0);
  demand(Number.isSafeInteger(samples) && pcm.length === samples * stream.channels * 4, 'AV_DECODE_SAMPLE_COUNT');
  let offset = 0, nonzero = 0, clipped = 0;
  const audibleIntervals = new Set();
  for (let index = 0; index < frames.length; index++) {
    const count = Number(frames[index].nb_samples);
    demand(Number.isSafeInteger(count) && count > 0, 'AV_AUDIO_FRAME_INVALID');
    for (let sampleIndex = 0; sampleIndex < count; sampleIndex++) {
      const time = coverage.audio[index].start + sampleIndex / Number(stream.sample_rate) * manifest.clock.rate;
      for (let channel = 0; channel < stream.channels; channel++) {
        const sample = pcm.readFloatLE(offset); offset += 4;
        demand(finite(sample), 'AV_NONFINITE_AUDIO');
        if (sample !== 0) {
          nonzero++;
          for (const interval of policy.intervals) if (time >= interval.start && time < interval.end) audibleIntervals.add(interval.id);
        }
        if (Math.abs(sample) >= 1) clipped++;
      }
    }
  }
  demand(nonzero > 0, 'AV_SILENT_TRACK');
  for (const interval of policy.intervals) if (interval.audioRequired === true) demand(audibleIntervals.has(interval.id), 'AV_SILENT_INTERVAL:' + interval.id);
  return { samples, nonzero, clipped };
}

// Direct executable only: no shell, no grandchildren, bounded bytes/time, close observed.
export async function runOwned(executable, args, { timeoutMs, maxBytes, signal, stdin, environment, spawnProcess = spawn, schedule = setTimeout, unschedule = clearTimeout }) {
  demand(isAbsolute(executable) && timeoutMs > 0 && finite(timeoutMs) && Number.isSafeInteger(maxBytes) && maxBytes > 0, 'AV_PROCESS_LIMITS_REQUIRED');
  const lifecycle = new StudioLifecycle({ timeoutMs, schedule, unschedule });
  let child, timer, cleanupTimer, abort, ended = false, failure, exitCode = null, exitSignal = null, size = 0;
  const stdout = [], stderr = [];
  let resolveClosed;
  const closed = new Promise(resolve => { resolveClosed = resolve; });
  const row = lifecycle.attempt('decoder', executable, async () => {
    if (!child || ended) return { released: true, evidence: { exitCode, signal: exitSignal, spawned: Boolean(child) } };
    child.kill('SIGKILL');
    await closed;
    demand(ended, 'AV_PROCESS_EXIT_UNPROVEN');
    return { released: true, evidence: { exitCode, signal: exitSignal } };
  });
  try {
    demand(!signal?.aborted, 'AV_CANCELLED');
    child = spawnProcess(executable, args, { windowsHide: true, shell: false, stdio: [stdin === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'], env: environment });
    if (child.pid) lifecycle.acquire(row, { pid: child.pid });
    const stop = code => {
      failure ??= code;
      child.kill('SIGKILL');
      // If close is never delivered, bounded cleanup reports the unresolved resource.
      if (!cleanupTimer) cleanupTimer = schedule(resolveClosed, timeoutMs);
    };
    child.once('error', () => { failure ??= 'AV_SPAWN_FAILED'; if (!child.pid) { ended = true; resolveClosed(); } else stop(failure); });
    child.once('close', (code, signalName) => { ended = true; exitCode = code; exitSignal = signalName; resolveClosed(); });
    for (const [stream, target] of [[child.stdout, stdout], [child.stderr, stderr]]) stream.on('data', bytes => {
      size += bytes.length;
      if (size > maxBytes) stop('AV_OUTPUT_LIMIT');
      else target.push(Buffer.from(bytes));
    });
    abort = () => stop('AV_CANCELLED');
    signal?.addEventListener('abort', abort, { once: true });
    timer = schedule(() => stop('AV_PROCESS_TIMEOUT'), timeoutMs);
    if (signal?.aborted) abort();
    if (stdin !== undefined) {
      child.stdin.on('error', () => stop('AV_STDIN_FAILED'));
      child.stdin.end(stdin);
    }
    await closed;
    if (failure) throw new Error(failure);
    demand(exitCode === 0 && exitSignal === null, 'AV_DECODER_EXIT');
  } catch (error) {
    failure ??= error.message;
    lifecycle.fail('decode', failure);
  } finally {
    unschedule(timer); unschedule(cleanupTimer);
    signal?.removeEventListener('abort', abort);
  }
  const cleanup = await lifecycle.close();
  const report = { executable, args, exitCode, exitSignal, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr), cleanup };
  if (failure || !cleanup.ok) throw Object.assign(new Error(failure || 'AV_CLEANUP_UNPROVEN'), { report });
  return report;
}

// Calling this executes real decoders. Importing/planning never does.
// The caller persists this report and owns the original capture outside scratch.
export async function decodeOriginal({ originalPath, manifest, expected, policy, decoder, scratchParent, limits, signal }) {
  manifest = structuredClone(manifest);
  expected = structuredClone(expected);
  policy = structuredClone(policy);
  decoder = structuredClone(decoder);
  demand(Number.isSafeInteger(limits?.maxOriginalBytes) && limits.maxOriginalBytes > 0
    && (await stat(originalPath)).size <= limits.maxOriginalBytes, 'AV_ORIGINAL_SIZE_LIMIT');
  demand(decoder?.commercialUse === true && text(decoder.licenseBasis)
    && hex(decoder.ffmpegSha256) && hex(decoder.ffprobeSha256), 'AV_DECODER_CAPABILITY_REQUIRED');
  const originals = await readFile(originalPath);
  demand(originals.length <= limits.maxOriginalBytes, 'AV_ORIGINAL_SIZE_LIMIT');
  validateProvenance(manifest, originals, expected);
  demand(hex(expected.coveragePolicySha256) && expected.coveragePolicySha256 === sha256(JSON.stringify(policy)), 'AV_POLICY_BINDING_REQUIRED');
  for (const name of ['ffmpeg', 'ffprobe']) demand(sha256(await readFile(decoder[name])) === decoder[name + 'Sha256'], 'AV_DECODER_IDENTITY_MISMATCH');
  const directory = await mkdtemp(join(scratchParent, 'forge-av-'));
  const input = join(directory, 'original.media');
  const runs = [];
  const execute = async (executable, args) => {
    const result = await runOwned(executable, args, { ...limits, signal });
    runs.push({ ...result, stdout: undefined, stderr: result.stderr.toString('utf8'), stdoutSha256: sha256(result.stdout) });
    if (!args.includes('-version')) demand(result.stderr.length === 0, 'AV_DECODER_ERROR_OUTPUT');
    return result.stdout;
  };
  try {
    await writeFile(input, originals, { flag: 'wx' });
    const versions = {};
    for (const name of ['ffmpeg', 'ffprobe']) versions[name] = (await execute(decoder[name], ['-version'])).toString('utf8');
    const probe = JSON.parse((await execute(decoder.ffprobe, ['-v', 'error', '-protocol_whitelist', 'file', '-show_streams', '-show_frames', '-show_format', '-of', 'json', input])).toString('utf8'));
    const common = ['-nostdin', '-v', 'error', '-xerror', '-protocol_whitelist', 'file', '-copyts', '-i', input];
    const frameText = (await execute(decoder.ffmpeg, [...common, '-map', '0:' + manifest.tracks.video, '-an', '-fps_mode', 'passthrough', '-f', 'framehash', '-hash', 'sha256', 'pipe:1'])).toString('utf8');
    const frameHashes = frameText.split(/\r?\n/).filter(line => line.trim() && !line.startsWith('#')).map(line => line.split(',').at(-1).trim());
    const pcm = await execute(decoder.ffmpeg, [...common, '-map', '0:' + manifest.tracks.audio, '-vn', '-c:a', 'pcm_f32le', '-f', 'f32le', 'pipe:1']);
    const coverage = validateCoverage(manifest, probe, frameHashes, policy);
    const audioStream = probe.streams.find(stream => stream.index === manifest.tracks.audio);
    const audioStats = inspectAudio(pcm, manifest, probe, coverage, policy);
    demand(sha256(await readFile(input)) === manifest.original.sha256 && sha256(await readFile(originalPath)) === manifest.original.sha256, 'AV_ORIGINAL_CHANGED');
    for (const name of ['ffmpeg', 'ffprobe']) demand(sha256(await readFile(decoder[name])) === decoder[name + 'Sha256'], 'AV_DECODER_CHANGED');
    return { schemaVersion: 1, verdict: 'inconclusive', blockers: ['LISTENING_NOT_PERFORMED', 'TEMPORAL_SEMANTIC_REVIEW_REQUIRED'],
      original: structuredClone(manifest.original), provenance: structuredClone(manifest), versions, runs, probe, coverage, frameHashes,
      audio: { parentSha256: manifest.original.sha256, streamIndex: manifest.tracks.audio, sha256: sha256(pcm), sampleRate: Number(audioStream.sample_rate), channels: audioStream.channels, ...audioStats, pcm },
      limits: 'Structural decoding is not listening, correct cue recognition, or meaningful motion approval.' };
  } catch (error) {
    error.avEvidence = { verdict: 'inconclusive', original: manifest.original, runs, failedRun: error.report, blocker: error.message };
    throw error;
  } finally {
    // Only our temporary copy is removed. Caller-owned original is never modified.
    await rm(directory, { recursive: true });
  }
}

export function capabilityStatus({ acquisition, listening, decoder } = {}) {
  const blockers = [];
  if (!acquisition?.api || !(acquisition?.processLoopback === true || acquisition?.isolatedSessionLoopback === true) || acquisition?.synchronizedTracks !== true || !text(acquisition?.verifiedReceipt)) blockers.push('OWNED_AV_ACQUISITION_UNPROVEN');
  if (!listening?.api || listening?.audioInput !== true || listening?.temporalVideoInput !== true || listening?.commercialUse !== true || !text(listening?.verifiedReceipt)) blockers.push('LISTENING_CAPABILITY_UNPROVEN');
  if (!decoder?.verifiedReceipt) blockers.push('DECODER_EXECUTION_UNPROVEN');
  return { verdict: 'inconclusive', blockers, releaseApproved: false, reason: 'Capability declarations never establish a listened session or release authority.' };
}
