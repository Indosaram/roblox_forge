// Runtime adapters must come from maintained telemetry integration, never a
// module path or callback supplied by an evidence file. This orchestration
// cannot grant that authority; production must bind the actual event source.
export const crashCheckpoints = ['ESCROWED', 'CREDITED', 'FINALIZED', 'LEASE_ACQUIRED', 'LEASE_RENEWED'];

async function bounded(action, signal, label) {
  const controller = new AbortController();
  let timer, cancel;
  const stopped = new Promise((_, reject) => {
    cancel = () => { controller.abort(); reject(new Error(`${label}_CANCELLED`)); };
    signal?.addEventListener('abort', cancel, { once: true });
    timer = setTimeout(() => { controller.abort(); reject(new Error(`${label}_TIMEOUT`)); }, 60000);
  });
  try {
    if (signal?.aborted) throw new Error(`${label}_CANCELLED`);
    return await Promise.race([Promise.resolve().then(() => action(controller.signal)), stopped]);
  } finally { clearTimeout(timer); signal?.removeEventListener('abort', cancel); }
}

export async function recoverAtBarrier({ session, runtime, binding, checkpoint, key, requestId, trigger, restart, signal }) {
  if (!crashCheckpoints.includes(checkpoint) || typeof session.crashAtBarrier !== 'function'
      || typeof trigger !== 'function' || typeof key !== 'string' || typeof requestId !== 'string'
      || typeof runtime?.persistentSnapshot !== 'function' || typeof restart !== 'function') {
    throw new Error('LIVE_BARRIER_ADAPTER_REQUIRED');
  }
  const before = await runtime.persistentSnapshot();
  const durable = before?.identity?.mode === 'studio-datastore'
    ? before.identity.universeId > 0
    : before?.identity?.mode === 'studio-local' && before?.bridgeProof?.namespace === binding.namespace
      && before.bridgeProof.durableCommit === true && before.bridgeProof.restartReadback === true
      && typeof before.bridgeProof.receiptSha256 === 'string';
  if (!before || before.namespace !== binding.namespace || !durable
      || !before.sha256 || !before.records) throw new Error('PERSISTENT_SNAPSHOT_REQUIRED');
  const termination = await session.crashAtBarrier({ key, requestId, phase: checkpoint,
    trigger, buildIdentity: binding.build, namespace: binding.namespace });
  if (termination.released !== true || termination.barrier?.phase !== checkpoint
      || termination.barrier?.requestId !== requestId) throw new Error('CRASH_BARRIER_MISMATCH');
  let fresh, primary, cleanupFailure, result;
  try {
    // Restart must own a NEW lifecycle, transport and StudioSession, not revive
    // the killed session or replace persisted values with a local snapshot.
    fresh = await bounded(abort => restart({ namespace: binding.namespace, build: binding.build, signal: abort }), signal, 'RESTART');
    if (!fresh?.runtime || !fresh.sessionId || fresh.sessionId === binding.sessionId
        || fresh.namespace !== binding.namespace || fresh.build !== binding.build) throw new Error('DISTINCT_PERSISTENT_RESTART_REQUIRED');
    const recovered = await fresh.runtime.recover(termination.barrier.requestId, signal);
    const after = await fresh.runtime.persistentSnapshot();
    const replay = await fresh.runtime.recover(termination.barrier.requestId, signal);
    const afterReplay = await fresh.runtime.persistentSnapshot();
    // The live runtime owns semantic inventory/escrow accounting. Hash equality
    // alone is not conservation (lease metadata legitimately changes).
    const conservation = await fresh.runtime.compareRecovery({ before, barrier: termination.barrier,
      recovered, after, replay, afterReplay });
    if (conservation?.ok !== true || conservation.requestId !== termination.barrier.requestId
        || conservation.noLoss !== true || conservation.noDuplication !== true
        || conservation.staleWriterRejected !== true) throw new Error('LIVE_CONSERVATION_NOT_PROVEN');
    result = { checkpoint, before, termination, recovered, after, replay, afterReplay, conservation };
  } catch (error) {
    primary = error;
  } finally {
    if (fresh) {
      try {
        const cleanup = await bounded(abort => fresh.close(abort), undefined, 'RECOVERY_CLEANUP');
        if (!cleanup?.ok) cleanupFailure = cleanup || { ok: false };
      } catch (error) { cleanupFailure = { ok: false, error: String(error) }; }
    }
  }
  if (primary || cleanupFailure) {
    const error = new Error(primary?.message || 'RECOVERY_CLEANUP_UNPROVEN', { cause: primary });
    error.cleanup = cleanupFailure;
    error.evidence = { before, termination };
    throw error;
  }
  return result;
}

export async function saturateCaps(runtime, signal) {
  const limits = await runtime.configuredLimits();
  const rows = [];
  for (const kind of ['payloadBytes', 'receipts', 'jobs', 'npcs', 'admission']) {
    const limit = limits[kind];
    if (!Number.isInteger(limit) || limit < 1) throw new Error(`ACTUAL_CAP_REQUIRED:${kind}`);
    // Adapter performs real authorized operations until the exact configured
    // limit plus one request. No cap is lowered just to manufacture a rejection.
    const before = await runtime.persistentSnapshot();
    const result = await runtime.saturate(kind, limit, signal);
    const after = await runtime.persistentSnapshot();
    if (result?.limit !== limit || result.acceptedAtLimit !== true || result.rejectedBeyondLimit !== true
        || !Number.isInteger(result.attempts) || result.attempts < 1
        || !Number.isInteger(result.retryLimit) || result.retryLimit < 0
        || !Number.isInteger(result.maximumRetries) || result.maximumRetries < 0
        || result.maximumRetries > result.retryLimit || result.unhandledThrottles !== 0) throw new Error(`CAP_PROOF_FAILED:${kind}`);
    const conserved = await runtime.compareRejectedMutation(before, after, result);
    if (conserved?.ok !== true) throw new Error(`CAP_CONSERVATION_FAILED:${kind}`);
    rows.push({ kind, limit, before, result, after, conserved });
  }
  return rows;
}
