import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { checkpoints, sha256, currentCollectorIdentity } from './capacity-matrix.mjs';
import { compareReplay, ownership, gatheringTransitions, reconcileWorkload, verifyHeldAcquisition, verifyLeaseRestart } from './capacity-persistence.mjs';
import { validateSaturationRow } from './capacity-saturation.mjs';
import { Database } from 'bun:sqlite';

const requireProof = (condition, code) => { if (!condition) throw new Error(code); };
const equal = (a,b) => JSON.stringify(a) === JSON.stringify(b);
const finite = value => Number.isFinite(value) && value >= 0;
const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])) : value;
const same = (a,b) => equal(canonical(a),canonical(b));
export function cleanupProof(value) {
  // Release evidence only. A recorded run failure is a separate fact the caller
  // reports through status/blockers/failure; folding it in renamed a fully released
  // ledger after an admission failure into CLEANUP_UNPROVEN. A real release failure
  // still leaves its row unresolved and its id in residuals, so unknown or missing
  // release evidence keeps refusing here. This mirrors unresolvedResources().
  requireProof(value !== null && typeof value === 'object' && Array.isArray(value.resources)
    && Array.isArray(value.residuals) && !value.residuals.length
    && value.resources.every(row=>row && row.cleanup==='released' && row.state==='released' && row.evidence), 'CLEANUP_UNPROVEN');
}
function jobProof(value, process) {
  cleanupProof(value);
  const row=value.resources.find(row=>row.id==='owned-editor');
  requireProof(row?.acquired && row.identity?.pid===process?.pid && row.identity.creationTime===process.creationTime
    && row.identity.treeOwnership==='windows-job-no-breakaway' && row.evidence.pid===process.pid
    && row.evidence.treeExited===true && row.evidence.eventProof==='JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO','OWNED_JOB_EXIT_UNPROVEN');
}
function quantiles(values, positive = false) {
  requireProof(Array.isArray(values) && values.length > 0 && values.every(value=>finite(value) && (!positive || value>0)), 'INVALID_SAMPLES');
  const sorted=[...values].sort((a,b)=>a-b);
  return {count:sorted.length,p50:sorted[Math.ceil(sorted.length*.5)-1],p95:sorted[Math.ceil(sorted.length*.95)-1],maximum:sorted.at(-1)};
}
function loaded(rows, build, count, session) {
  requireProof(rows?.length===count && new Set(rows.map(row=>row.actorId)).size===count, 'ACTOR_COUNT_MISMATCH');
  for(const row of rows) requireProof(row.role==='client' && row.buildIdentity===build && row.serverBuildIdentity===build
    && row.sessionId===session && typeof row.actorId==='string', 'LOADED_ACTOR_MISMATCH');
}
export function backendProof(before, after, namespace) {
  for(const value of [before,after]) {
    requireProof(value?.backend==='local-sqlite-cas' && value.namespace===namespace && value.coverageComplete===true
      && value.overflow===false && value.inFlight===0 && Array.isArray(value.outcomes)
      && value.outcomes.length===value.requestCount && new Set(value.outcomes.map(row=>row.operation)).size===value.requestCount,
    'BACKEND_COVERAGE_INCOMPLETE');
    requireProof(finite(value.startedAtMs) && value.endedAtMs>=value.startedAtMs
      && Number.isSafeInteger(value.configuredCaps?.maxConcurrentRequests) && value.configuredCaps.maxConcurrentRequests>0
      && value.availableSlots===value.configuredCaps.maxConcurrentRequests-value.inFlight, 'BACKEND_BUDGET_INVALID');
    for(const row of value.outcomes) requireProof(Number.isSafeInteger(row.operation) && row.operation>0
      && row.startedAtMs>=value.startedAtMs && row.endedAtMs>=row.startedAtMs && row.endedAtMs<=value.endedAtMs,
    'BACKEND_OUTCOME_WINDOW_INVALID');
  }
  requireProof(before.epoch===after.epoch && before.startedAtMs===after.startedAtMs && after.endedAtMs>=before.endedAtMs
    && same(before.configuredCaps,after.configuredCaps) && same(after.outcomes.slice(0,before.outcomes.length),before.outcomes), 'BACKEND_IDENTITY_CHANGED');
  const outcomes=after.outcomes.slice(before.outcomes.length);
  requireProof(outcomes.length>0 && outcomes.every(row=>row.admitted===true
    && (row.status===200 && ['read','committed'].includes(row.outcome) || row.status===409 && row.outcome==='cas-conflict')),
  'UNHANDLED_BACKEND_OUTCOME');
  requireProof(after.handledThrottleCount===0 && after.throttleCount===before.throttleCount
    && after.failures===before.failures, 'UNHANDLED_BACKEND_THROTTLE');
  return {kind:'local-concurrent-http-slots',maximum:after.configuredCaps.maxConcurrentRequests,
    peakInFlight:after.peakInFlight,availableSlots:after.availableSlots,operations:outcomes.length};
}
export function measurementProof(report, namespace, build) {
  jobProof(report.lifecycle,report.admission?.process);
  requireProof(report.admission?.ok && report.currentBuild?.id===build && report.admittedPlayers===8, 'MEASUREMENT_ADMISSION_REQUIRED');
  const server=report.loaded?.server;
  requireProof(server?.role==='server' && server.buildIdentity===build && server.sessionId, 'LOADED_SERVER_MISMATCH');
  loaded(report.loaded.clients,build,8,server.sessionId);
  requireProof(report.admission.clients?.length===8 && new Set([report.admission.serverId,...report.admission.clients.map(row=>row.studioId)]).size===9
    && same(report.admission.clients.map(row=>row.userId).sort(),report.loaded.clients.map(row=>row.actorId).sort()), 'ACTUAL_SESSION_COUNT_MISMATCH');
  requireProof(report.hardware?.scope==='owned-local-job-host' && report.hardware.provider==='Windows-CIM'
    && report.hardware.cpu?.length && report.hardware.os?.Version, 'HARDWARE_REQUIRED');
  requireProof(report.samples?.length===9, 'SAMPLE_TARGETS_REQUIRED');
  const first=report.samples[0], clients=[];
  let serverMetrics;
  requireProof(first.endedAtSeconds-first.startedAtSeconds===300, 'WINDOW_DURATION_INVALID');
  requireProof(new Set(report.samples.map(row=>row.loaded?.role==='server'?'server':row.loaded?.actorId)).size===9, 'DUPLICATE_SAMPLE_TARGET');
  for(const sample of report.samples) {
    requireProof(sample.loaded?.buildIdentity===build && sample.loaded.sessionId===server.sessionId
      && sample.startedAtSeconds===first.startedAtSeconds && sample.endedAtSeconds===first.endedAtSeconds
      && typeof sample.robloxVersion==='string' && sample.robloxVersion===first.robloxVersion, 'SAMPLE_BINDING_INVALID');
    requireProof(sample.sampleTimes?.length===sample.frameMs?.length && sample.memoryMb?.length===sample.frameMs?.length
      && sample.engineDtMs?.length===sample.frameMs?.length, 'SAMPLE_COVERAGE_INVALID');
    // A missing engineDtMs therefore refuses here, before any read of it below.
    // engineDtMs is provenance, not the measured duration: a zero engine delta with
    // an advancing sampler clock is retained and counted, while a non-finite or
    // negative delta is still invalid. frameMs keeps its own strictly-positive
    // requirement in quantiles(), so a nonpositive measured clock delta is refused.
    requireProof(sample.engineDtMs.every(value=>finite(value) && value>=0), 'ENGINE_DELTA_INVALID');
    requireProof(sample.sampleTimes.every((time,index)=>finite(time) && time>=sample.startedAtSeconds && time<sample.endedAtSeconds
      && (index===0 || time>sample.sampleTimes[index-1])), 'SAMPLE_TIMESTAMPS_INVALID');
    const frames=quantiles(sample.frameMs,true), memory=quantiles(sample.memoryMb);
    // A sparse series must not claim a full window merely by copying its bounds.
    const duration=sample.frameMs.reduce((a,b)=>a+b,0)/1000;
    requireProof(duration>=299 && sample.sampleTimes[0]-first.startedAtSeconds<=1
      && first.endedAtSeconds-sample.sampleTimes.at(-1)<=1, 'SAMPLE_WINDOW_INCOMPLETE');
    if(sample.loaded.role==='client') {
      requireProof(report.loaded.clients.some(row=>same(row,sample.loaded)) && frames.p95<=33.3,'CLIENT_FRAME_P95_FAILED');
      clients.push({actorId:sample.loaded.actorId,frames,memory});
    } else {
      requireProof(same(sample.loaded,server),'SERVER_SAMPLE_MISMATCH');
      requireProof(frames.p95<=33.3,'SERVER_FRAME_P95_FAILED');
      serverMetrics={frames,memory};
    }
  }
  requireProof(clients.length===8,'CLIENT_SAMPLES_REQUIRED');
  for(const census of [report.censusBefore,report.censusAfter]) requireProof(census && equal(census.npcs.map(row=>row.id),census.configuredIds)
    && census.observedCount===census.npcs.length && census.configuredCount===census.npcs.length
    && census.observedCount<=census.configuredMaximum,'NPC_CENSUS_MISMATCH');
  requireProof(same(report.censusBefore,report.censusAfter),'NPC_CONFIGURATION_CHANGED');
  const backend=backendProof(report.backendBefore,report.backendAfter,namespace);
  for(const trace of [report.persistenceBefore,report.persistenceAfter]) requireProof(trace?.identity?.namespace===namespace
    && !trace.overflow && trace.coverageComplete===true && trace.inFlight===0
    && trace.backendObservation?.coverageComplete===true && trace.backendObservation.namespace===namespace
    && trace.backendObservation.epoch===report.backendBefore.epoch,'PERSISTENCE_COVERAGE_INCOMPLETE');
  requireProof(report.persistenceBefore.identity.epoch===report.persistenceAfter.identity.epoch,'PERSISTENCE_EPOCH_CHANGED');
  const commits=report.persistenceAfter.records.filter(row=>row.sequence>report.persistenceBefore.sequence);
  requireProof(commits.length>0 && same(commits,report.commits),'COMMIT_TRACE_CHANGED');
  const outcomes=report.persistenceAfter.outcomes.filter(row=>row.operation>report.persistenceBefore.attempts);
  requireProof(outcomes.length===report.persistenceAfter.attempts-report.persistenceBefore.attempts
    && outcomes.every(row=>row.acknowledged && row.classificationComplete && row.throttleCount===0 && row.handledThrottleCount===0
      && row.attempts>=1 && row.attempts<=row.retryLimit+1 && row.requests?.length===row.requestCount
      && row.requests.every(request=>request.acknowledged && request.outcome==='acknowledged'
        || request.route==='/cas' && request.outcome==='CAS_CONFLICT')
      && commits.some(commit=>commit.operation===row.operation && commit.key===row.key)), 'RUNTIME_OUTCOME_INCOMPLETE');
  const hostRows=report.backendAfter.outcomes.slice(report.backendBefore.outcomes.length);
  const requests=outcomes.flatMap(row=>row.requests);
  const hostById=new Map(hostRows.map(row=>[row.operation,row]));
  requireProof(requests.length===hostRows.length && new Set(requests.map(row=>row.hostOperation)).size===requests.length
    && requests.every(row=>{
      const host=hostById.get(row.hostOperation);
      return row.correlationComplete===true && row.backendEpoch===report.backendAfter.epoch && host && host.route===row.route && host.key===row.key
        && host.inputRevision===row.inputRevision && host.acknowledgedRevision===row.acknowledgedRevision
        && (row.acknowledged ? host.status===200 : row.outcome==='CAS_CONFLICT' && host.status===409);
    }), 'HOST_RUNTIME_REQUEST_COVERAGE_MISMATCH');
  const limit=report.loadedLimits?.payloadBytes;
  requireProof(Number.isSafeInteger(limit) && limit>0 && limit<=4194304,'LOADED_PAYLOAD_POLICY_REQUIRED');
  for(const row of commits) requireProof(typeof row.serialized==='string' && Buffer.byteLength(row.serialized)<=limit
    && finite(row.latencyMs),'PERSISTED_PAYLOAD_OR_LATENCY_INVALID');
  const baseline=new Map(report.workloadBeforeReadback.map(row=>[row.key,JSON.parse(row.value)]));
  requireProof(baseline.size===report.workloadBeforeReadback.length,'DUPLICATE_BASELINE_KEY');
  for(const record of [...commits].sort((a,b)=>a.sequence-b.sequence)) {
    requireProof(baseline.has(record.key) && same(baseline.get(record.key),JSON.parse(record.previousSerialized)), 'COMMIT_CHAIN_INCOMPLETE');
    baseline.set(record.key,JSON.parse(record.serialized));
  }
  requireProof(report.persistentReadback.length===baseline.size && new Set(report.persistentReadback.map(row=>row.key)).size===baseline.size
    && report.persistentReadback.every(row=>same(baseline.get(row.key),JSON.parse(row.value))),'FINAL_READBACK_UNBOUND');
  requireProof(report.workload?.ok && report.workload.actions.length && report.workload.actions.every(row=>row.before>=first.startedAtSeconds
    && row.after>=row.before && row.after<=first.endedAtSeconds),'WORKLOAD_WINDOW_INVALID');
  const successful=report.workload.actions.filter(row=>row.result?.result?.ok);
  requireProof(report.loaded.clients.every(actor=>successful.some(row=>row.actorId===actor.actorId))
    && ['gather','craft-complete','transfer-deposit','settlement-place'].every(action=>
      successful.some(row=>row.action===`survival-coop:${action}`)), 'WORKLOAD_ACTION_COVERAGE_INCOMPLETE');
  const gathers=gatheringTransitions(report.workloadBeforeReadback,report.persistentReadback,commits,report.workload.actions,report.accountingContent);
  const conservation=reconcileWorkload(report.workloadBeforeReadback,report.persistentReadback,report.workload.actions,report.accountingContent,gathers);
  requireProof(conservation.ok,'WORKLOAD_QUANTITY_CHANGED');
  compareReplay(report.persistentReadback,report.replayReadback);
  return {measured:true,players:8,crossServer:false,scope:'local-sqlite-host-only',clients,server:serverMetrics,backend,
    auxiliaryEngineObservations:{updateAsyncBudget:{source:'DataStoreService.UpdateAsync',scope:'Roblox-engine-only',
      applicableToMeasuredBackend:false,samples:report.samples.find(row=>row.loaded.role==='server').updateAsyncBudget || []}},
    commitLatencyMs:quantiles(commits.map(row=>row.latencyMs)),payloadBytes:quantiles(commits.map(row=>Buffer.byteLength(row.serialized))),
    hardware:report.hardware,robloxVersion:first.robloxVersion,startedAtSeconds:first.startedAtSeconds,endedAtSeconds:first.endedAtSeconds,
    sharedMutationActors:1};
}

export function recoveryProof(report, phase, namespace, build) {
  jobProof(report.lifecycle,report.admission?.process);
  requireProof(report.currentBuild?.id===build,'RECOVERY_BUILD_MISMATCH');
  if(phase.startsWith('LEASE_')) {
    const crash=report.leaseCrash, fresh=report.leaseRecovery;
    requireProof(crash?.released===true && crash.barrier?.phase===phase && crash.barrier.identity?.namespace===namespace
      && crash.barrier.held && crash.barrier.ackState==='held','LEASE_CRASH_UNPROVEN');
    jobProof(fresh?.cleanup,fresh?.admission?.process);
    requireProof(crash.process?.pid===report.admission.process.pid && crash.process.creationTime===report.admission.process.creationTime
      && fresh.admission.process.creationTime!==crash.process.creationTime,'DISTINCT_CRASH_JOB_REQUIRED');
    requireProof(fresh.loaded?.buildIdentity===build && fresh.admission?.leaseBarrierAdmission
      && fresh.expiryObservation?.at>=JSON.parse(crash.barrier.record.serialized).lease.expiresAt,'LEASE_RESTART_BINDING_INVALID');
    verifyHeldAcquisition(crash.barrier.record.serialized,fresh.heldAcquisition,fresh.beforeProbe.value);
    const old=JSON.parse(crash.barrier.record.previousSerialized), committed=JSON.parse(crash.barrier.record.serialized);
    requireProof(phase==='LEASE_ACQUIRED' ? committed.generation>(old?.generation||0)
      : old.lease?.sessionId===committed.lease?.sessionId && old.generation===committed.generation
        && committed.lease.expiresAt>old.lease.expiresAt,'DURABLE_LEASE_TRANSITION_INVALID');
    requireProof(same(JSON.parse(fresh.crashedReadback.value),JSON.parse(crash.barrier.record.serialized)),'CRASHED_READBACK_CHANGED');
    return verifyLeaseRestart(crash.barrier.record.serialized,fresh.beforeProbe.value,fresh.rejection,fresh.afterProbe.value);
  }
  const value=report.recovery, crash=value?.crash, barrier=crash?.barrier;
  requireProof(crash?.released===true && barrier?.phase===phase && barrier.identity?.namespace===namespace
    && barrier.held && barrier.ackState==='held' && crash.runtime?.buildIdentity===build,'TRANSFER_CRASH_UNPROVEN');
  jobProof(value.cleanup,value.restart?.process);
  requireProof(crash.process?.pid===report.admission.process.pid && crash.process.creationTime===report.admission.process.creationTime
    && value.restart.process.creationTime!==crash.process.creationTime,'DISTINCT_CRASH_JOB_REQUIRED');
  requireProof(value.loaded?.buildIdentity===build && value.loaded.sessionId!==crash.runtime.sessionId
    && value.loadTrace?.identity?.namespace===namespace && value.loadTrace.identity.epoch!==barrier.identity.epoch
    && !value.loadTrace.overflow,'FRESH_RECOVERY_REQUIRED');
  loaded(value.loadedClients,build,8,value.loaded.sessionId);
  requireProof(same(ownership(value.before),ownership(value.after)),'RECOVERY_QUANTITY_CHANGED');
  compareReplay(value.after,value.replayReadback);
  const original=crash.originalCommand, id=barrier.requestId;
  requireProof(original?.namespace===namespace && original.envelope?.sessionEpoch===original.oldEpoch
    && same(value.commandReplay?.request,original.envelope),'ORIGINAL_COMMAND_CHANGED');
  requireProof(value.restart.clients.some(row=>row.userId===original.actorId)
    && value.loadedClients.some(row=>row.actorId===original.actorId),'RECOVERY_ACTOR_MISSING');
  const barrierWrapper=JSON.parse(barrier.record.serialized);
  const durable=value.crashedReadback?.find(row=>row.key===barrier.record.key);
  requireProof(durable && same(JSON.parse(durable.value),barrierWrapper),'DURABLE_BARRIER_READBACK_MISMATCH');
  requireProof(same(ownership(value.before),ownership(value.crashedReadback)),'CRASH_BOUNDARY_QUANTITY_CHANGED');
  const boundary=barrierWrapper.data?.itemTransfers?.receipts?.[id];
  requireProof(boundary?.phase===phase && boundary.request?.id===id,'DURABLE_PHASE_NOT_PROVEN');
  const request=boundary.request, rows=new Map(value.after.map(row=>[row.key,JSON.parse(row.value)]));
  const source=rows.get(request.source)?.data?.itemTransfers?.receipts?.[id];
  const destination=rows.get(request.destination)?.data?.itemTransfers?.receipts?.[id];
  requireProof(source?.phase==='FINALIZED' && Number.isSafeInteger(source.stateVersion) && destination?.phase==='CREDITED'
    && same(source.request,destination.request) && same(source.request,request) && request.actor===original.actorId,
  'TERMINAL_TRANSFER_NOT_PROVEN');
  return {phase,requestId:id,stateVersion:source.stateVersion};
}

// A run that never bound a build failed before it could be collected: the collector records
// its own blocker (COLLECTION_FAILED) and no currentBuild, so comparing builds reported
// STAGE_BUILD_CHANGED and replaced the real cause (observed: LEASE_ACQUIRED's
// 'ForgePersistence is not a valid member of ServerStorage'). The run's recorded failure keeps
// its precedence; a run that did bind a different build is still a genuine STAGE_BUILD_CHANGED.
export function stageRunBinding(stage, buildIdentity) {
  const unbound=stage.runs.find(run=>!run.currentBuild);
  requireProof(!unbound, unbound?.blockers?.[0] || 'COLLECTION_FAILED');
  requireProof(stage.runs.every(run=>same(run.currentBuild,buildIdentity)),'STAGE_BUILD_CHANGED');
}

// Read retained originals again after cleanup. Digest equality is integrity,
// not origin: only the maintained collector calls this on its own fresh matrix.
export async function admitMatrix(matrix) {
  const result={schema:'capacity-admission/v1',ok:false,status:'BLOCKED',blockers:[],
    supportedEnvelope:{measured:false,crossServer:false},recovery:{status:'BLOCKED',checkpoints:[],blockers:[]}};
  const stages=new Map();
  requireProof(matrix.schema==='capacity-matrix/v1' && /^[a-f0-9]{64}$/.test(matrix.collectorIdentity)
    && /^[a-f0-9]{64}$/.test(matrix.buildIdentity?.artifactSha256),'CURRENT_SOURCE_ARTIFACT_BINDING_REQUIRED');
  requireProof(await currentCollectorIdentity()===matrix.collectorIdentity
    && matrix.sourceVerification?.before===matrix.collectorIdentity && matrix.sourceVerification.after===matrix.collectorIdentity
    && matrix.sourceVerification.artifactBefore===matrix.buildIdentity.artifactSha256
    && matrix.sourceVerification.artifactAfter===matrix.buildIdentity.artifactSha256,'CURRENT_SOURCE_ARTIFACT_CHANGED');
  for(const stage of matrix.stages) {
    try {
      requireProof(!stages.has(stage.phase),'DUPLICATE_STAGE');
      requireProof(['MEASUREMENT',...checkpoints].includes(stage.phase)
        && stage.receipt?.path===`${stage.phase}.json` && stage.database?.path===`${stage.phase}.sqlite`,'RETAINED_PATH_INVALID');
      const bytes=await readFile(join(matrix.directory,stage.receipt.path));
      requireProof(sha256(bytes)===stage.receipt.sha256 && bytes.length===stage.receipt.bytes,'RECEIPT_HASH_MISMATCH');
      const original=JSON.parse(bytes);
      const {receipt,...current}=stage;
      requireProof(same(original,current),'RECEIPT_CONTENT_CHANGED');
      const db=await readFile(join(matrix.directory,stage.database.path));
      requireProof(sha256(db)===stage.database.sha256 && db.length===stage.database.bytes,'DATABASE_HASH_MISMATCH');
      const retained=new Database(join(matrix.directory,stage.database.path),{readonly:true});
      try {
        const rows=retained.query('SELECT key,revision,value FROM records WHERE namespace=? ORDER BY key').all(stage.namespace);
        requireProof(same(rows,stage.finalReadback),'RETAINED_DATABASE_READBACK_MISMATCH');
      } finally { retained.close(); }
      const last=stage.runs.at(-1);
      const saturationEnd=last?.saturation?.rows?.at(-1)?.after;
      if(saturationEnd) {
        const rows=last.saturation.rows;
        compareReplay(last.replayReadback,rows[0].before);
        for(let i=1;i<rows.length;i++) compareReplay(rows[i-1].after,rows[i].before);
        requireProof(same(ownership(last.replayReadback),ownership(saturationEnd)),'SATURATION_QUANTITY_CHANGED');
      }
      const endpoint=last?.recovery?.replayReadback || saturationEnd || last?.replayReadback;
      if(endpoint) {
        compareReplay(endpoint,stage.finalReadback);
        const finalByKey=new Map(stage.finalReadback.map(row=>[row.key,row]));
        requireProof(endpoint.every(row=>Number.isSafeInteger(row.revision)
          && finalByKey.get(row.key)?.revision>=row.revision),'RETAINED_REVISION_REGRESSED');
      } else if(last?.leaseRecovery) {
        const row=stage.finalReadback.find(row=>row.key===last.leaseCrash.barrier.record.key);
        requireProof(row && same(JSON.parse(row.value),JSON.parse(last.leaseRecovery.afterProbe.value))
          && row.revision>=last.leaseRecovery.afterProbe.revision,'RETAINED_LEASE_READBACK_CHANGED');
      }
      cleanupProof(stage.cleanup);
      for(const run of stage.runs) cleanupProof(run.lifecycle);
      requireProof(!stage.error && stage.runs.length>0,'STAGE_INCOMPLETE');
      stageRunBinding(stage,matrix.buildIdentity);
      stages.set(stage.phase,stage);
    } catch(error) { result.blockers.push(`${stage.phase}:${error.message}`); }
  }
  try {
    requireProof(matrix.players===8,'EIGHT_PLAYERS_REQUIRED');
    const stage=stages.get('MEASUREMENT');requireProof(stage,'MEASUREMENT_MISSING');
    result.supportedEnvelope=measurementProof(stage.runs.at(-1),stage.namespace,matrix.buildIdentity.id);
  } catch(error) {result.blockers.push(error.message);}
  for(const phase of checkpoints) {
    try {
      const stage=stages.get(phase);requireProof(stage,'CHECKPOINT_MISSING');
      result.recovery.checkpoints.push(recoveryProof(stage.runs.at(-1),phase,stage.namespace,matrix.buildIdentity.id));
    } catch(error) {result.recovery.blockers.push(`${phase}:${error.message}`);}
  }
  // Concrete saturation validator is supplied by the maintained probe module;
  // unsupported kinds remain explicit and cannot be masked by report.ok.
  const saturation=stages.get('MEASUREMENT')?.runs.at(-1)?.saturation;
  for(const kind of ['payloadBytes','receipts','jobs','npcs','admission']) {
    const row=saturation?.rows?.find(row=>row.kind===kind);
    if(!row) result.recovery.blockers.push(`SATURATION_REQUIRED:${kind}`);
    else result.recovery.blockers.push(...validateSaturationRow(row).map(code=>`${kind}:${code}`));
  }
  if(!result.recovery.blockers.length) result.recovery.status='PASS';
  result.blockers.push(...result.recovery.blockers);
  result.ok=result.supportedEnvelope.measured && result.recovery.status==='PASS' && !result.blockers.length;
  result.status=result.ok?'PASS':'BLOCKED';
  return result;
}
