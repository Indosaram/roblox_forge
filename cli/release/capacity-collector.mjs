import { StdioMcp } from '../forge/qa/studio-driver.mjs';
import { StudioSession } from '../forge/qa/studio-driver-session.mjs';
import { StudioLifecycle } from '../forge/qa/studio-driver-lifecycle.mjs';
import { createHash } from 'node:crypto';
import { observedWait, runWorkload, executeSteps } from './capacity-workload.mjs';
import { openStore } from './local-persistence-host.mjs';
import { latestRecords, compareReplay, replayRecorded, censusCode, ownership, reconcileWorkload, gatheringTransitions, verifyLeaseRestart, verifyHeldAcquisition } from './capacity-persistence.mjs';
import { hardware } from './capacity-hardware.mjs';
import { collectSaturation, saturationLimitsCode } from './capacity-saturation.mjs';
import { collectMatrix, awaitLeaseExpiry, currentCollectorIdentity, sha256 } from './capacity-matrix.mjs';
import { objectReadiness } from './persistence-readiness.mjs';
import { admitMatrix } from './capacity-admission.mjs';
import { readFile } from 'node:fs/promises';

// The two reads the lease-restart path issues against the freshly restarted server. Both are
// preceded by the bounded readiness wait: the embedded ForgeBuildIdentity script assigns its
// Handshake callback before parenting it (buildidentity.luau:146 then :149), so the parented child is
// the readiness contract and the caller's own Invoke is what proves the callback is live, and the
// RuntimeBackend publishes ForgePersistence and ObservedLeaseExpiry from its own startup path, so an
// unguarded read races the bootstrap (observed: COLLECTION_FAILED, 'ForgePersistence is not a valid
// member of ServerStorage').
export const leaseIdentityRead = `${objectReadiness({service:'ServerScriptService',object:'ForgeBuildIdentity',child:'Handshake',childClass:'BindableFunction'})}
return game:GetService('HttpService'):JSONEncode(game:GetService('ServerScriptService').ForgeBuildIdentity.Handshake:Invoke())`;
export const leaseExpiryRead = `${objectReadiness({service:'ServerStorage',object:'ForgePersistence',attribute:'ObservedLeaseExpiry'})}
return game:GetService('HttpService'):JSONEncode({at=game:GetService('ServerStorage').ForgePersistence:GetAttribute('ObservedLeaseExpiry')})`;

// This is executable instrumentation, not a claimed product API. Execute only
// after maintained ownership and freshly loaded build handshakes are admitted.
// Server clock is shared via GetServerTimeNow; dt is the actual engine signal.
export function sampleCode({ buildIdentity, actorId, startSeconds, endSeconds, server = false, continuation = false, sliceIndex }) {
  if (!/^sha256:[a-f0-9]{64}$/.test(buildIdentity) || !Number.isFinite(startSeconds)
      || !Number.isFinite(endSeconds) || endSeconds <= startSeconds || endSeconds - startSeconds > 300
      || !Number.isInteger(sliceIndex) || sliceIndex < 1
      || (!server && (typeof actorId !== 'string' || !/^-?\d+$/.test(actorId)))) throw new Error('INVALID_SAMPLE_REQUEST');
  return `local run=game:GetService('RunService')
local stats=game:GetService('Stats')
local player=game:GetService('Players').LocalPlayer
${server ? "assert(run:IsServer(),'SERVER_REQUIRED')" : `assert(run:IsClient() and tostring(player.UserId)==${JSON.stringify(actorId)},'ACTOR_MISMATCH')`}
local owner=${server ? "game:GetService('ServerScriptService')" : "player:FindFirstChild('PlayerScripts')"}
local identity=owner and owner:FindFirstChild('ForgeBuildIdentity')
local handshake=identity and identity:FindFirstChild('Handshake')
assert(handshake,'LOADED_HANDSHAKE_REQUIRED')
local loaded=handshake:Invoke()
assert(loaded.buildIdentity==${JSON.stringify(buildIdentity)},'LOADED_BUILD_MISMATCH')
local beginAt,endAt=${startSeconds},${endSeconds}
-- A continuation slice resumes after its predecessor returned, so "now" may
-- already be past beginAt; the first slice still owns the strict boundary.
${continuation ? "assert(workspace:GetServerTimeNow()<endAt,'WINDOW_ALREADY_ENDED')" : "assert(workspace:GetServerTimeNow()<beginAt,'WINDOW_ALREADY_STARTED')"}
local done=Instance.new('BindableEvent')
local frames,engineDt,memory,timestamps,budgets={},{},{},{},{}
local completed=false
local connection
local lastNow=workspace:GetServerTimeNow()
local function finish() if completed then return end;completed=true;if connection then connection:Disconnect() end;done:Fire() end
connection=run.${server ? 'Heartbeat' : 'RenderStepped'}:Connect(function(dt)
 local now=workspace:GetServerTimeNow()
 if now>=endAt then finish();return end
 if now>=beginAt then
  -- frameMs is the observed interval between this sampler's callbacks on the shared
  -- server clock, the same clock as sampleTimes. It is a wall-clock frame period
  -- (it includes engine scheduling gaps) and is deliberately NOT claimed equal to
  -- the engine's internal step time. The engine dt argument is retained separately
  -- as provenance because it can report exactly 0 for a step where this clock
  -- advanced (observed on the server: 5 of 54570 frames).
  table.insert(frames,(now-lastNow)*1000);table.insert(engineDt,dt*1000)
  table.insert(memory,stats:GetTotalMemoryUsageMb());table.insert(timestamps,now)
  ${server ? "table.insert(budgets,game:GetService('DataStoreService'):GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync))" : ''}
 end
 lastNow=now
end)
local timedOut=false
local deadline=task.delay(math.max(0,endAt-workspace:GetServerTimeNow())+5,function() timedOut=true;finish() end)
if not completed then done.Event:Wait() end
connection:Disconnect()
if coroutine.status(deadline)=='suspended' then task.cancel(deadline) end
done:Destroy()
assert(not timedOut and #frames>0,'METRIC_WINDOW_INCOMPLETE')
for i=1,#frames do assert(frames[i]>0,'SAMPLE_CLOCK_NONPOSITIVE') end
local http=game:GetService('HttpService')
local json=http:JSONEncode({loaded=loaded,frameMs=frames,engineDtMs=engineDt,memoryMb=memory,updateAsyncBudget=budgets,sampleTimes=timestamps,startedAtSeconds=beginAt,endedAtSeconds=endAt,robloxVersion=version()})
-- execute_luau truncates result text at ~100,000 characters and one frame per
-- tick exceeds that within a slice, so hold the encoded series in StringValue
-- parts and let the collector read the parts back raw (ASCII-checked first).
for i=1,#json do if json:byte(i)>127 then error('SAMPLE_PART_NON_ASCII') end end
local root=${server ? "game:GetService('ServerStorage')" : "player:FindFirstChild('PlayerScripts')"}
assert(root,'SAMPLE_PART_ROOT_UNAVAILABLE players='..#game:GetService('Players'):GetPlayers()..' parent='..tostring(player and player.Parent and player.Parent.Name))
local holder=Instance.new('Folder')
holder.Name='ForgeCapacitySample${sliceIndex}'
local lens={}
local pos=1
local idx=1
while pos<=#json do
 local piece=string.sub(json,pos,math.min(pos+79999,#json))
 local part=Instance.new('StringValue')
 part.Name='Part'..idx
 part.Value=piece
 part.Parent=holder
 lens[idx]=#piece
 pos=pos+#piece
 idx=idx+1
end
holder.Parent=root
return http:JSONEncode({parts=lens,bytes=#json,startedAtSeconds=beginAt,endedAtSeconds=endAt,holder=holder.Name})`;
}

// No elapsed sleeps: each execute returns after its exact engine window signal.
// The owned adapter must provide cancellation/reconciliation for lost replies.
//
// StudioMCP answers "Request timeout" once a single execute_luau hold reaches
// its ~300s server cap, which the full 300s window (plus the 10s admission
// horizon) always exceeds, and one slice's full frame series still exceeds the
// ~100k execute_luau text cap. Slice the window in two, read each slice's
// StringValue-part payload back raw, and overlap the readback with the next
// slice's hold so the inter-slice gap stays at one request round-trip.
const SLICE_SECONDS = 150;
export async function collectWindow(owned, request, lifecycle) {
  if (!owned || typeof owned.execute !== 'function' || !Array.isArray(owned.clients)
      || owned.clients.length !== request.players || !owned.serverId) throw new Error('OWNED_ADAPTER_REQUIRED');
  const ids = new Set([owned.serverId]);
  const actors = new Set();
  for (const client of owned.clients) {
    if (!client.studioId || ids.has(client.studioId) || !client.actorId || actors.has(client.actorId)) throw new Error('DUPLICATE_CLIENT');
    ids.add(client.studioId); actors.add(client.actorId);
  }
  const asArray = value => Array.isArray(value) ? value : [];
  const readSlice = async (studioId, model, handle) => {
    if (typeof owned.executeRawText !== 'function') throw new Error('OWNED_ADAPTER_REQUIRED');
    if (!handle || typeof handle.holder !== 'string' || !Number.isInteger(handle.bytes) || handle.bytes < 1
        || !Array.isArray(handle.parts) || handle.parts.length < 1
        || handle.parts.some(n => !Number.isInteger(n) || n < 1)
        || handle.parts.reduce((total, n) => total + n, 0) !== handle.bytes) throw new Error('SAMPLE_PART_HANDLE_INVALID');
    const root = model === 'Server' ? "game:GetService('ServerStorage')"
      : "game:GetService('Players').LocalPlayer:FindFirstChild('PlayerScripts')";
    const locate = `local root=${root};local h=root and root:FindFirstChild(${JSON.stringify(handle.holder)})`;
    try {
      const chunks = [];
      for (let index = 1; index <= handle.parts.length; index++) {
        // Bounded sub-call label so the next authorized run can tell a slice execute apart from
        // a part readback; no retry and no timeout change.
        let piece;
        try {
          piece = await owned.executeRawText(studioId, model,
            `${locate};assert(h,'SAMPLE_PART_HOLDER_MISSING');local v=h:FindFirstChild('Part${index}');assert(v and v:IsA('StringValue'),'SAMPLE_PART_MISSING');return v.Value`);
        } catch (error) { throw new Error(`sample-part-${index}: ${String(error && error.message || error)}`); }
        if (typeof piece !== 'string' || piece.length !== handle.parts[index - 1]) throw new Error('SAMPLE_PART_READBACK_INVALID');
        chunks.push(piece);
      }
      const json = chunks.join('');
      if (Buffer.byteLength(json, 'utf8') !== handle.bytes) throw new Error('SAMPLE_PART_TRUNCATED');
      try { return JSON.parse(json); }
      catch (error) { throw new Error(`SAMPLE_PART_PARSE_FAILED:${error && error.message}`); }
    } finally {
      try { await owned.executeRawText(studioId, model, `${locate};if h then h:Destroy() end;return 'gone'`); }
      catch { /* the session may already be closing; the holder dies with it */ }
    }
  };
  const targets = [{ studioId: owned.serverId, server: true }, ...owned.clients];
  const rows = await Promise.all(targets.map(target => {
    let notify;
    return lifecycle.observe({ phase: 'capacity-window', timeoutMs: request.timeoutMs,
      subscribe: resolve => { notify = resolve; return () => { notify = () => {}; }; },
      action: async signal => {
        try {
        const slices = [];
        for (let index = 0; ; index++) {
          const begin = request.startSeconds + index * SLICE_SECONDS;
          if (begin >= request.endSeconds) break;
          slices.push([begin, Math.min(request.startSeconds + (index + 1) * SLICE_SECONDS, request.endSeconds)]);
        }
        const reads = [];
        for (let index = 0; index < slices.length; index++) {
          const [begin, end] = slices[index];
          const model = target.server ? 'Server' : 'Client';
          // Bounded sub-call label; the outer catch still prefixes the actor or server.
          let handle;
          try {
            handle = await owned.execute(target.studioId, model,
              sampleCode({ ...request, actorId: target.actorId, server: !!target.server, sliceIndex: index + 1,
                startSeconds: begin, endSeconds: end, continuation: index > 0 }), signal);
          } catch (error) { throw new Error(`sample-slice-${index + 1}: ${String(error && error.message || error)}`); }
          if (!handle || handle.startedAtSeconds !== begin || handle.endedAtSeconds !== end) throw new Error('SAMPLE_SLICE_BOUND_MISMATCH');
          // Read the previous slice's parts while the next slice holds the
          // window; awaiting the readback here would widen the coverage gap.
          reads.push(readSlice(target.studioId, model, handle));
        }
        let merged = null;
        for (const value of await Promise.all(reads)) {
          if (value.loaded?.buildIdentity !== request.buildIdentity || value.loaded?.sessionId !== owned.serverSessionId
              || (!target.server && (value.loaded?.actorId !== target.actorId || value.loaded?.serverBuildIdentity !== request.buildIdentity))) throw new Error('LOADED_IDENTITY_MISMATCH');
          merged = merged ? {
            loaded: merged.loaded,
            frameMs: merged.frameMs.concat(value.frameMs),
            engineDtMs: merged.engineDtMs.concat(value.engineDtMs),
            memoryMb: merged.memoryMb.concat(value.memoryMb),
            updateAsyncBudget: asArray(merged.updateAsyncBudget).concat(asArray(value.updateAsyncBudget)),
            sampleTimes: merged.sampleTimes.concat(value.sampleTimes),
            startedAtSeconds: merged.startedAtSeconds,
            endedAtSeconds: value.endedAtSeconds,
            robloxVersion: merged.robloxVersion,
          } : value;
        }
        notify(merged);
        return { studioId: target.studioId, ...merged };
        } catch (error) {
          throw new Error(`${target.server ? 'server' : target.actorId}: ${String(error && error.message || error)}`);
        }
      } });
  }));
  return rows.map(row => row.value);
}

const decode = result => {
  if (result.isError) throw new Error('METRIC_EXECUTE_FAILED');
  const text = (result.content || []).filter(part => part.type === 'text').map(part => part.text).join('\n');
  const marker = text.match(/FORGE_QA_JSON:([^\r\n]+)/);
  return JSON.parse(marker ? marker[1] : text);
};

// execute_luau truncates result text at ~100,000 characters (measured), and
// StringValue.Value caps at 200,000 characters, while a workload snapshot can
// exceed both (measured 819,412 base64 chars). Hold one encoded snapshot across
// bounded StringValue parts and read it back in base64 chunks; base64 keeps
// every chunk ASCII-safe to slice at any byte offset.
const SNAPSHOT_CHUNK = 60000;
const SNAPSHOT_PART = 180000;
const SNAPSHOT_SETUP_CODE = `local http=game:GetService('HttpService');local ss=game:GetService('ServerStorage');local p=ss:FindFirstChild('ForgePersistence');assert(p,'PERSISTENCE_TELEMETRY_UNAVAILABLE');local json=http:JSONEncode(p.snapshot:Invoke());local B='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';local out={};for i=1,#json,3 do local a,b,c=json:byte(i,i+2);local n=a*65536+(b or 0)*256+(c or 0);local c1=math.floor(n/262144)%64;local c2=math.floor(n/4096)%64;local c3=math.floor(n/64)%64;local c4=n%64;out[#out+1]=B:sub(c1+1,c1+1)..B:sub(c2+1,c2+1)..(b and B:sub(c3+1,c3+1) or '=')..(c and B:sub(c4+1,c4+1) or '=')end;local b64=table.concat(out);for _,c in ss:GetChildren() do if c.Name:sub(1,21)=='ForgeCapacitySnapshot' then c:Destroy() end end;local PART=${SNAPSHOT_PART};local parts=math.ceil(#b64/PART);for i=1,parts do local v=Instance.new('StringValue');v.Name='ForgeCapacitySnapshot'..i;v.Value=b64:sub((i-1)*PART+1,math.min(i*PART,#b64));v.Parent=ss end;return http:JSONEncode({jsonBytes=#json,b64Bytes=#b64,partBytes=PART,parts=parts})`;

export const persistenceSnapshot = (rawCall, rearm, limits) => async () => {
  const totalBudgetMs = limits?.totalBudgetMs;
  const maxBytes = limits?.maxBytes;
  const chunkBudgetMs = limits?.chunkBudgetMs;
  if (!Number.isSafeInteger(totalBudgetMs) || totalBudgetMs <= 0
      || !Number.isSafeInteger(maxBytes) || maxBytes <= 0
      || !Number.isSafeInteger(chunkBudgetMs) || chunkBudgetMs <= 0) throw new Error('PERSISTENCE_SNAPSHOT_LIMITS_REQUIRED');
  // One total budget for the whole readback, fixed before any call: setup and every
  // chunk are each armed with min(per-call cap, remaining), so re-arming can never
  // extend the readback past this deadline. The total is a fixed bound, never the
  // product of chunk count and per-call cap.
  const deadline = Date.now() + totalBudgetMs;
  const arm = () => {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error('PERSISTENCE_SNAPSHOT_BUDGET_EXHAUSTED');
    rearm?.(Math.min(chunkBudgetMs, remaining));
  };
  const destroyCode = `local ss=game:GetService('ServerStorage');for _,c in ss:GetChildren() do if c.Name:sub(1,21)=='ForgeCapacitySnapshot' then c:Destroy() end end;return 'gone'`;
  try {
    arm();
    const setup = JSON.parse(await rawCall(SNAPSHOT_SETUP_CODE));
    if (!Number.isInteger(setup.jsonBytes) || setup.jsonBytes < 1
        || !Number.isInteger(setup.b64Bytes) || setup.b64Bytes < 1
        || !Number.isInteger(setup.partBytes) || setup.partBytes < 1
        || !Number.isInteger(setup.parts) || setup.parts !== Math.ceil(setup.b64Bytes / setup.partBytes)) {
      throw new Error('PERSISTENCE_SNAPSHOT_UNAVAILABLE');
    }
    const readCode = (offset, end) => `local ss=game:GetService('ServerStorage');local off=${offset};local fin=${end};local PART=${setup.partBytes};local out={};local pos=off;while pos<=fin do local idx=math.floor((pos-1)/PART);local localOff=pos-idx*PART;local take=math.min(fin-pos+1,PART-localOff+1);local v=ss:FindFirstChild('ForgeCapacitySnapshot'..(idx+1));assert(v,'PERSISTENCE_SNAPSHOT_HOLDER_LOST');out[#out+1]=v.Value:sub(localOff,localOff+take-1);pos=pos+take end;return table.concat(out)`;
    // The captured encoded length is finite and known here. Refuse a capture above
    // the explicit accepted maximum before reading it.
    if (setup.b64Bytes > maxBytes) throw new Error('PERSISTENCE_SNAPSHOT_TOO_LARGE');
    const chunks = [];
    let seen = 0;
    for (let offset = 1; offset <= setup.b64Bytes; offset += SNAPSHOT_CHUNK) {
      arm();
      const end = Math.min(offset + SNAPSHOT_CHUNK - 1, setup.b64Bytes);
      const piece = await rawCall(readCode(offset, end));
      if (typeof piece !== 'string' || piece.length < 1) throw new Error('PERSISTENCE_SNAPSHOT_CHUNK_EMPTY');
      chunks.push(piece);
      seen += piece.length;
    }
    if (seen !== setup.b64Bytes) throw new Error('PERSISTENCE_SNAPSHOT_TRUNCATED');
    const json = Buffer.from(chunks.join(''), 'base64').toString('utf8');
    if (Buffer.byteLength(json, 'utf8') !== setup.jsonBytes) throw new Error('PERSISTENCE_SNAPSHOT_DECODE_LENGTH_MISMATCH');
    try { return JSON.parse(json); }
    catch (error) { throw new Error(`PERSISTENCE_SNAPSHOT_PARSE_FAILED:${error && error.message}`); }
  } finally {
    // Cleanup is a separate, independently capped budget (one per-call cap), always
    // attempted even after the total readback budget is exhausted, so an aborted
    // readback cannot leak its retained holder. It is not charged to the total.
    try {
      rearm?.(chunkBudgetMs);
      await rawCall(destroyCode);
    }
    catch { /* the session may already be closing; the holder dies with it */ }
  }
};

async function restartLease(request, crash) {
  const local=request.driver.localPersistence;
  if(!local || !crash.released || crash.barrier.identity.namespace!==local.namespace)throw new Error('OWNED_LOCAL_LEASE_CRASH_REQUIRED');
  const old=JSON.parse(crash.barrier.record.serialized);
  const previous=JSON.parse(crash.barrier.record.previousSerialized);
  if(crash.barrier.phase==='LEASE_RENEWED' && (!previous?.lease || old.generation!==previous.generation
      || old.lease?.sessionId!==previous.lease.sessionId || old.lease.expiresAt<=previous.lease.expiresAt))throw new Error('DURABLE_RENEWAL_NOT_PROVEN');
  if(crash.barrier.phase==='LEASE_ACQUIRED' && old.generation<=(previous?.generation||0))throw new Error('DURABLE_ACQUISITION_NOT_PROVEN');
  if(!old.lease || !Number.isSafeInteger(old.lease.expiresAt))throw new Error('DURABLE_LEASE_REQUIRED');
  const lifecycle=new StudioLifecycle();
  const cancel=()=>{lifecycle.fail('cancel','CANCELLED');void lifecycle.close();};
  request.signal?.addEventListener('abort',cancel,{once:true});
  const result={ok:false,barrierTransition:{phase:crash.barrier.phase,previous,current:old}};
  let store;
  try {
    store=openStore(local.path);
    result.crashedReadback=store.read(local.namespace,crash.barrier.record.key);
    if(JSON.stringify(JSON.parse(result.crashedReadback.value))!==JSON.stringify(old))throw new Error('CRASHED_COMMIT_READBACK_CHANGED');
    // Expiry is the behavior under test: schedule its exact deadline rather
    // than poll or shorten the persisted lease to make reacquisition pass.
    await awaitLeaseExpiry(old.lease.expiresAt,request.signal);
    const transport=new StdioMcp(request.driver.command,request.driver.args,90000,lifecycle);
    await transport.initialize();
    const session=new StudioSession(transport,lifecycle);
    // Same launch-span budget as attempt(): spawn plus registration plus the
    // admission horizon must not race the constructor's initial 90s deadline.
    transport.deadline = Date.now() + 400000;
    const config={...request.driver,persistence:{...request.driver.persistence}};
    config.persistence.leaseAcquireKey=crash.barrier.record.key;
    config.persistence.waitLeaseExpiry=old.lease.expiresAt;
    const admission=await session.launch(config,request.players);
    result.admission=admission;
    if(!admission.ok)throw new Error('LEASE_RESTART_ADMISSION_FAILED');
    const execute=async code=>decode(await transport.call('execute_luau',{studio_id:admission.serverId,datamodel_type:'Server',code}));
    if(!admission.leaseBarrierAdmission)throw new Error('CONTROLLED_LEASE_ADMISSION_REQUIRED');
    const loaded=await execute(leaseIdentityRead);
    result.loaded=loaded;
    if(loaded.buildIdentity!==request.buildIdentity.id)throw new Error('LEASE_RESTART_BUILD_MISMATCH');
    result.expiryObservation=await execute(leaseExpiryRead);
    if(result.expiryObservation.at<old.lease.expiresAt || !Number.isSafeInteger(result.expiryObservation.at))throw new Error('AUTHORITATIVE_EXPIRY_NOT_OBSERVED');
    const key=crash.barrier.record.key;
    result.heldAcquisition=await execute("local p=game:GetService('ServerStorage').ForgePersistence;local event=game:GetService('HttpService'):JSONDecode(p.StartupLeaseReached.Value);local s=p.barrierStatus:Invoke(event.ticket);assert(s.held and s.expiresAtMs-DateTime.now().UnixTimestampMillis>30000,'ACQUISITION_NOT_HELD');return game:GetService('HttpService'):JSONEncode(s)");
    if(result.heldAcquisition.record?.key!==key || result.heldAcquisition.identity?.namespace!==local.namespace)throw new Error('HELD_ACQUISITION_BINDING_MISMATCH');
    result.beforeProbe=store.read(local.namespace,key);
    verifyHeldAcquisition(result.crashedReadback.value,result.heldAcquisition,result.beforeProbe.value);
    result.rejection=await execute(`return game:GetService('HttpService'):JSONEncode(game:GetService('ServerStorage').ForgePersistence.probeStaleLease:Invoke(${JSON.stringify(key)},${JSON.stringify(old.lease.sessionId)},${old.generation}))`);
    result.afterProbe=store.read(local.namespace,key);
    const stillHeld=await execute(`return game:GetService('HttpService'):JSONEncode(game:GetService('ServerStorage').ForgePersistence.barrierStatus:Invoke(${JSON.stringify(result.heldAcquisition.ticket)}))`);
    if(!stillHeld.held || stillHeld.ackState!=='held')throw new Error('ACQUISITION_HOLD_LOST_DURING_PROBE');
    result.proof=verifyLeaseRestart(crash.barrier.record.serialized,result.beforeProbe.value,result.rejection,result.afterProbe.value);
    result.ok=true;
  } catch(error){result.error=String(error.message);}
  finally {store?.close();result.cleanup=await lifecycle.close();request.signal?.removeEventListener('abort',cancel);if(!result.cleanup.ok)result.ok=false;}
  return result;
}

// Always enter the maintained owned launch path, not configured existing IDs.
export async function attempt(request, transport, lifecycle) {
  const session = new StudioSession(transport, lifecycle);
  // The CIM probe measures the host, not the Studio job, so sample it before
  // the owned launch: ten spawning instances repeatedly starved PowerShell
  // past the observe ceiling (owned runs 1, 6 and 7 died at capacity-hardware).
  const hardwareResult = await hardware(lifecycle);
  // The launch path spans spawn, registration, the 10-second admission
  // horizon and actor observation; on a loaded host that exceeds the
  // constructor's initial 90s deadline (owned run 8 died at ESCROWED launch
  // with MCP deadline). Lift only the absolute deadline: per-call timeout
  // stays at timeoutMs, so every call remains individually bounded.
  transport.deadline = Date.now() + 400000;
  const admission = await session.launch(request.driver, request.players);
  const report = { ok: false, status: 'BLOCKED', requestedPlayers: request.players,
    admission, blockers: [...(admission.blockers || [])], admittedPlayers: 0,
    currentBuild: request.buildIdentity, checkpoint: request.checkpoint, hardware: hardwareResult };
  if (!admission.ok) return report;
  if(admission.leaseBarrierAdmission) {
    report.leaseCrash=await session.crashStartupLease({key:request.driver.persistence.leaseAcquireKey,namespace:request.driver.persistence.namespace});
    report.leaseRecovery=await restartLease(request,report.leaseCrash);
    if(!report.leaseRecovery.ok)report.blockers.push('LEASE_RESTART_FENCING_FAILED');
    return report;
  }
  const execute = async (studioId, model, code, signal) => {
    if (signal?.aborted) throw new Error('CANCELLED');
    return decode(await transport.call('execute_luau', {
      studio_id: studioId, datamodel_type: model, code,
    }));
  };
  const executeRawText = async (studioId, model, code) => {
    const result = await transport.call('execute_luau', { studio_id: studioId, datamodel_type: model, code });
    if (result.isError) throw new Error('METRIC_EXECUTE_FAILED');
    return (result.content || []).filter(part => part.type === 'text').map(part => part.text).join('');
  };
  // ForgeBuildIdentity.Handshake appears asynchronously after registration;
  // probe against its arrival instead of failing the run on one early call.
  const loadedTransient = error => /LOADED_HANDSHAKE_REQUIRED|BUILD_HANDSHAKE_UNAVAILABLE/.test(String((error && error.message) || error));
  const retryLoaded = async run => {
    // Arrival is environment scheduling (nine instances loading at up to 60fps
    // of background render), not product behavior; budget it generously while
    // staying inside the transport's 400s probe deadline so a genuinely
    // missing handshake still fails with its own assert text.
    const until = Date.now() + 300000;
    for (;;) {
      try { return await run(); }
      catch (error) {
        if (!loadedTransient(error) || Date.now() >= until) throw error;
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    }
  };
  // Probes run right after registration; give them their own bounded arrival
  // budget instead of whatever remains of the launch window.
  transport.deadline = Date.now() + 400000;
  transport.timeoutMs = 410000;
  try {
    const server = await retryLoaded(() => execute(admission.serverId, 'Server', `local script=game:GetService('ServerScriptService'):FindFirstChild('ForgeBuildIdentity');local h=script and script:FindFirstChild('Handshake');assert(h,'LOADED_HANDSHAKE_REQUIRED');return game:GetService('HttpService'):JSONEncode({loaded=h:Invoke(),now=workspace:GetServerTimeNow()})`));
    if (!request.buildIdentity?.id || server.loaded?.buildIdentity !== request.buildIdentity.id
        || server.loaded?.role !== 'server' || !server.loaded?.sessionId) throw new Error('LOADED_IDENTITY_MISMATCH');
    const clients = admission.clients.map(client => ({ studioId: client.studioId, actorId: client.userId }));
	const identities = await Promise.all(clients.map(async client => {
	  const loaded = await retryLoaded(() => execute(client.studioId, 'Client', `local p=game:GetService('Players').LocalPlayer;assert(tostring(p.UserId)==${JSON.stringify(client.actorId)},'ACTOR_MISMATCH');local ps=p:FindFirstChild('PlayerScripts');local script=ps and ps:FindFirstChild('ForgeBuildIdentity');local h=script and script:FindFirstChild('Handshake');assert(h,'LOADED_HANDSHAKE_REQUIRED');return game:GetService('HttpService'):JSONEncode(h:Invoke())`));
	  if (loaded.role !== 'client' || loaded.actorId !== client.actorId || loaded.sessionId !== server.loaded.sessionId
	      || loaded.buildIdentity !== request.buildIdentity.id || loaded.serverBuildIdentity !== request.buildIdentity.id) throw new Error('LOADED_IDENTITY_MISMATCH');
	  return loaded;
	}));
	if (new Set(identities.map(identity => identity.actorId)).size !== request.players
	    || new Set([admission.serverId, ...clients.map(client => client.studioId)]).size !== request.players + 1) throw new Error('DUPLICATE_CLIENT');
    report.loaded = { server: server.loaded, clients: identities };
    report.loadedLimits = await execute(admission.serverId, 'Server', saturationLimitsCode);
    const clock = await execute(admission.serverId, 'Server', "return game:GetService('HttpService'):JSONEncode({now=workspace:GetServerTimeNow()})");
    // Wrap-up reads are a separate phase from sampling. The snapshot readback gets
    // one fixed total budget, a per-call cap, and an explicit accepted maximum
    // capture size. The maximum is set from the retained artifact: the MEASUREMENT
    // persistence snapshot JSON is ~3.78 MB (serialized+previousSerialized+outcomes)
    // so its base64 readback is ~5.04 MB; 32 MB leaves ~6x headroom for later
    // checkpoints without accepting an unbounded capture.
    const READBACK_CHUNK_BUDGET_MS = 90000;
    const READBACK_TOTAL_BUDGET_MS = 400000;
    const READBACK_MAX_BYTES = 33554432;
    const rearmReadback = budgetMs => {
      transport.timeoutMs = budgetMs;
      transport.deadline = Date.now() + budgetMs;
    };
    const persistence = persistenceSnapshot(code => executeRawText(admission.serverId, 'Server', code), rearmReadback,
      { totalBudgetMs: READBACK_TOTAL_BUDGET_MS, maxBytes: READBACK_MAX_BYTES, chunkBudgetMs: READBACK_CHUNK_BUDGET_MS });
    report.persistenceBefore = await persistence();
    // Restore a normal phase budget: the readback's last chunk budget must not leak
    // into the census reads that follow.
    transport.timeoutMs = READBACK_CHUNK_BUDGET_MS;
    transport.deadline = Date.now() + READBACK_TOTAL_BUDGET_MS;
    report.backendBefore = request.host?.observation();
    if (request.checkpoint === 'LEASE_KEY_DISCOVERY') {
      const record = [...latestRecords(report.persistenceBefore).values()].find(row => row.wrapper.lease && row.wrapper.data?.nodes);
      if (!record) throw new Error('OBSERVED_LEASE_KEY_REQUIRED');
      report.leaseKey = record.key;
      return report;
    }
    const accountingContent = await execute(admission.serverId,'Server',"local shared=game:GetService('ReplicatedStorage').Forge.games['primal-isles'].src.shared;local c=require(shared.SurvivalContent);return game:GetService('HttpService'):JSONEncode({nodes=c.nodes,recipes=c.recipes,structures=c.structures,worldNodes=require(shared.SurvivalWorldConfig).nodes})");
    report.accountingContent = accountingContent;
    if (request.driver.localPersistence) {
      const local=request.driver.localPersistence;
      const store=openStore(local.path);
      try { report.workloadBeforeReadback=store.rows(local.namespace); }
      finally { store.close(); }
    }
    report.censusBefore = await execute(admission.serverId, 'Server', censusCode);
    if (!['studio-local', 'studio-datastore'].includes(report.persistenceBefore.identity?.mode)
        || !report.persistenceBefore.identity?.namespace || report.persistenceBefore.overflow) throw new Error('PERSISTENT_TELEMETRY_REQUIRED');
    // Installation has a 10-second admission horizon, not a synthetic sample or
    // host sleep. Every probe refuses if transport latency misses that horizon.
    const startSeconds = clock.now + 10;
    const endSeconds = startSeconds + 300;
    transport.deadline = Date.now() + 400000;
    // Two 150s sampling holds plus part readbacks run inside this attempt; the
    // default 90s transport timeout would kill every sample, so lift it to the
    // deadline (min() still caps calls at the window budget).
    transport.timeoutMs = 410000;
    const sampling = collectWindow({ execute, executeRawText, serverId: admission.serverId,
      serverSessionId: server.loaded.sessionId, clients }, { players: request.players,
      buildIdentity: request.buildIdentity.id, startSeconds, endSeconds, timeoutMs: 400000 }, lifecycle);
    sampling.catch(() => {});
    const call = (name, args) => transport.call(name, args);
    const workloadExecute = (id, model, code) => execute(id, model,
      `${observedWait}\n${code}\nreturn game:GetService('HttpService'):JSONEncode(value)`);
    // Subscribe to the server's exact shared-clock boundary before workload input.
    await execute(admission.serverId, 'Server', `${observedWait}
local boundary=Instance.new('BindableEvent')
local connection=game:GetService('RunService').Heartbeat:Connect(function() if workspace:GetServerTimeNow()>=${startSeconds} then boundary:Fire() end end)
local ok,err=pcall(function() observe(boundary.Event,function() return true end,function() return workspace:GetServerTimeNow()<${startSeconds} end) end)
connection:Disconnect();boundary:Destroy();assert(ok,err)
assert(workspace:GetServerTimeNow()>=${startSeconds},'WORKLOAD_WINDOW_NOT_STARTED')
return game:GetService('HttpService'):JSONEncode({started=true})`);
    try {
      report.workload = await runWorkload(admission, { execute: workloadExecute, call,
        snapshot: actor => execute(admission.serverId, 'Server', `return game:GetService('HttpService'):JSONEncode(game:GetService('ServerStorage').ForgeQA.snapshot:Invoke('survival-coop',${JSON.stringify(actor)}))`),
        clock: async () => (await execute(admission.serverId, 'Server', "return game:GetService('HttpService'):JSONEncode({now=workspace:GetServerTimeNow()})")).now });
    } finally {
      // The workload can settle ~200s before the two 150s sampling slices do;
      // a short post-workload budget expired between the slices (MCP deadline).
      // Keep a slice-capable window until sampling settles, then give the
      // wrap-up reads their own bounded budget.
      transport.timeoutMs = 410000;
      transport.deadline = Date.now() + 400000;
      try { report.samples = await sampling; }
      finally {
        // Entering the readback phase arms its own bounded chunk budget; the readback
        // then enforces one fixed total deadline internally (observed: a fixed 120s
        // wrap-up budget expired mid-readback at ESCROWED and surfaced as MCP deadline).
        rearmReadback(READBACK_CHUNK_BUDGET_MS);
      }
    }
    report.persistenceAfter = await persistence();
    // Same restore after the final readback, before backend/census wrap-up reads.
    transport.timeoutMs = READBACK_CHUNK_BUDGET_MS;
    transport.deadline = Date.now() + READBACK_TOTAL_BUDGET_MS;
    report.backendAfter = request.host?.observation();
    report.censusAfter = await execute(admission.serverId, 'Server', censusCode);
    report.persistedMetrics = [...latestRecords(report.persistenceAfter).values()].map(({ wrapper, serialized, previousSerialized, ...record }) => record);
    if (report.persistenceAfter.identity?.epoch !== report.persistenceBefore.identity.epoch
        || report.persistenceAfter.identity?.namespace !== report.persistenceBefore.identity.namespace
        || report.persistenceAfter.overflow) throw new Error('PERSISTENCE_TRACE_INCOMPLETE');
    report.commits = report.persistenceAfter.records.filter(record => record.sequence > report.persistenceBefore.sequence);
    report.backendOutcomes=(report.persistenceAfter.outcomes || []).filter(row=>row.operation>report.persistenceBefore.attempts);
    for(const outcome of report.backendOutcomes) {
      if(outcome.retryLimit!==undefined && (!Number.isInteger(outcome.attempts) || outcome.attempts<1 || outcome.attempts>outcome.retryLimit+1))report.blockers.push('BACKEND_ATTEMPT_BOUND_VIOLATED');
      if(!outcome.acknowledged)report.blockers.push(outcome.error==='LOCAL_HTTP_429'?'UNHANDLED_BACKEND_THROTTLE':'BACKEND_OPERATION_FAILED');
      if(outcome.acknowledged && !report.commits.some(record=>record.operation===outcome.operation && record.key===outcome.key))report.blockers.push('BACKEND_OUTCOME_COMMIT_UNBOUND');
    }
    if (report.persistenceAfter.identity.mode === 'studio-local' && request.driver.localPersistence) {
      const local = request.driver.localPersistence;
      if (local.namespace !== report.persistenceAfter.identity.namespace) throw new Error('LOCAL_NAMESPACE_MISMATCH');
      const store = openStore(local.path);
      try {
        const keys = [...new Set([...report.commits.map(record => record.key), ...(report.workloadBeforeReadback || []).map(row=>row.key)])];
        report.persistentReadback = store.rows(local.namespace);
        report.persistedOwnership = ownership(report.persistentReadback);
        if (!report.workloadBeforeReadback?.length || keys.some(key=>!report.workloadBeforeReadback.some(row=>row.key===key))) {
          report.blockers.push('WORKLOAD_BASELINE_KEYSET_INCOMPLETE');
        } else {
          report.gatheringTransitions=gatheringTransitions(report.workloadBeforeReadback,report.persistentReadback,report.commits,report.workload.actions,accountingContent);
          report.workloadConservation=reconcileWorkload(report.workloadBeforeReadback,report.persistentReadback,report.workload.actions,accountingContent,report.gatheringTransitions);
          if (!report.workloadConservation.ok) report.blockers.push('WORKLOAD_CONSERVATION_FAILED');
        }
        const transfer = report.workload?.actions.find(action => action.action === 'survival-coop:transfer-deposit' && action.result?.request);
        if (transfer) {
          const actor = admission.clients.find(client => client.userId === transfer.actorId);
          report.replay = await replayRecorded(actor, transfer.result, execute);
          report.replayReadback = store.rows(local.namespace);
          report.replayComparison = compareReplay(report.persistentReadback, report.replayReadback);
        } else report.blockers.push('RECORDED_TRANSFER_REQUEST_UNAVAILABLE');
        report.persistenceScope = 'local-sqlite-host-only';
      } finally { store.close(); }
    }
    if (!report.commits.length) report.blockers.push('NO_ACKNOWLEDGED_WORKLOAD_COMMITS');
    if (report.persistenceAfter.handledThrottleCount == null) report.blockers.push('HANDLED_THROTTLE_CLASSIFICATION_UNAVAILABLE');
    if (!report.workload?.ok || report.workload.actions.some(action => action.before < startSeconds || action.after > endSeconds)) report.blockers.push('WORKLOAD_FAILED_OR_OUTSIDE_WINDOW');
    report.admittedPlayers = clients.length;
    report.measurementKind = 'actual-input-gather-craft-transfer-build';
    report.currentBuild = request.buildIdentity;
    if(request.checkpoint === 'LEASE_RENEWED' || request.driver.leaseRenewalKey) {
      const observed=request.driver.leaseRenewalKey ? latestRecords(report.persistenceAfter).get(request.driver.leaseRenewalKey)
        : [...latestRecords(report.persistenceAfter).values()].find(row=>row.wrapper.lease && row.wrapper.data?.nodes);
      if(!observed?.wrapper?.lease)throw new Error('OBSERVED_LEASE_KEY_REQUIRED');
      report.leaseCrash=await session.crashLeaseRenewal({key:observed.key,actorId:'-1',buildIdentity:request.buildIdentity.id,namespace:report.persistenceAfter.identity.namespace});
      report.leaseRecovery=await restartLease(request,report.leaseCrash);
      if(!report.leaseRecovery.ok)report.blockers.push('LEASE_RESTART_FENCING_FAILED');
      return report;
    }
    if (request.checkpoint === 'MEASUREMENT' && request.driver.localPersistence && report.workload?.ok) {
      const local=request.driver.localPersistence;
      const fiberActor=report.workload.actions.find(action=>action.actorId!=='-1' && action.action==='survival-coop:gather' && action.result?.nodeId==='fiber-bush-01' && action.result?.result?.ok);
      const actor=admission.clients.find(client=>client.userId===fiberActor?.actorId);
      const personalRecord=[...latestRecords(report.persistenceAfter).values()].find(row=>row.wrapper.data?.envelope?.genres?.['survival-coop']?.data?.workshop?.actorId===actor?.userId);
      if (!actor || !personalRecord) report.blockers.push('SATURATION_PERSONAL_ACTOR_READBACK_REQUIRED');
      else {
        const store=openStore(local.path);
        transport.deadline=Date.now()+1800000;
        try { report.saturation=await collectSaturation({actor,admission,execute,loadedLimits:report.loadedLimits,
          personalKey:personalRecord.key, ports:{execute:workloadExecute,call,clock:async()=>Date.now()/1000},
          readback:async()=>store.rows(local.namespace)}); }
        finally {store.close();}
      }
    }
    if (request.recovery) {
      report.recovery = { attempted: false, phase: request.recovery, blockers: [] };
      const local = request.driver.localPersistence;
      const transfer = report.workload?.actions.find(action => action.action === 'survival-coop:transfer-deposit' && action.result?.request);
      const records = latestRecords(report.persistenceAfter);
      const receipt = [...records.values()].flatMap(row => Object.values(row.wrapper.data?.itemTransfers?.receipts || {}))
        .find(value => value.request?.actor === transfer?.actorId && value.request?.source && value.request?.destination);
      if (!local || !receipt || !report.workload?.ok) {
        report.recovery.blockers.push('OBSERVED_TRANSFER_KEYS_AND_LOCAL_BACKEND_REQUIRED');
      } else {
        const actor = admission.clients.find(client => client.userId === transfer.actorId);
        // All tree stock was lawfully spent/deposited. Withdraw an existing
        // warehouse unit first, then deposit that actual unit at the held gate.
        const snapshot = await execute(admission.serverId, 'Server', `return game:GetService('HttpService'):JSONEncode(game:GetService('ServerStorage').ForgeQA.snapshot:Invoke('survival-coop',${JSON.stringify(actor.userId)}))`);
        const wood = Object.entries(snapshot.warehouse?.items || {}).find(([, item]) => item.catalogId === 'wood' && item.quantity > 0)?.[0];
        if (!wood) throw new Error('RECOVERY_WAREHOUSE_STOCK_REQUIRED');
        const ports = { execute: workloadExecute, call, clock: async () => Date.now() / 1000 };
        const content = ['Players','LocalPlayer','PlayerGui','ForgeSurvivalHUD','SafeArea','SurvivalSheet','Content'];
        await executeSteps([
          {op:'walk_to',target:'Workspace.DevelopmentIsland.WarehouseApproach',withinStuds:2,timeout_seconds:40},
          {op:'keyboard',key:'I',timeout_seconds:5},
          {op:'click',target:[...content,`Withdraw-${wood}`],resultAction:'survival-coop:transfer-withdraw',expect:'ok',timeout_seconds:15},
        ],actor,admission,ports);
        const personal = await execute(admission.serverId,'Server',`return game:GetService('HttpService'):JSONEncode(game:GetService('ServerStorage').ForgeQA.snapshot:Invoke('survival-coop',${JSON.stringify(actor.userId)}))`);
        const item = Object.entries(personal.inventory?.bag?.items || {}).find(([, value])=>value.catalogId==='wood' && value.quantity>0)?.[0];
        if (!item) throw new Error('RECOVERY_ACTUAL_ITEM_REQUIRED');
        await executeSteps([{op:'click',target:[...content,'InventoryGrid',item],timeout_seconds:5}],actor,admission,ports);
        const store = openStore(local.path);
        try {
          report.recovery.before = store.rows(local.namespace);
          report.recovery.attempted = true;
          const phase = request.recovery === 'transfer' ? 'ESCROWED' : request.recovery;
          report.recovery.crash = await session.crashTransfer({actorId:actor.userId,
            key:phase==='CREDITED'?receipt.request.destination:receipt.request.source, phase,
            buildIdentity:request.buildIdentity.id, namespace:local.namespace,
            input:()=>call('user_mouse_input',{studio_id:actor.studioId,datamodel_type:'Client',actions:[{action:'mouseButtonClick',mouse_button:'left',instance_path:'game.'+[...content,`Deposit-${item}`].join('.')}]})});
          report.recovery.crashedReadback = store.rows(local.namespace);
          const freshLifecycle = new StudioLifecycle();
          const cancelFresh=()=>{freshLifecycle.fail('cancel','CANCELLED');void freshLifecycle.close();};
          request.signal?.addEventListener('abort',cancelFresh,{once:true});
          try {
            const freshTransport = new StdioMcp(request.driver.command,request.driver.args,90000,freshLifecycle);
            await freshTransport.initialize();
            const freshSession = new StudioSession(freshTransport,freshLifecycle);
            const expiry = Math.max(...report.recovery.crashedReadback.map(row=>JSON.parse(row.value)?.lease?.expiresAt || 0));
            await awaitLeaseExpiry(expiry,request.signal);
            const fresh = await freshSession.launch({...request.driver,persistence:{...request.driver.persistence,waitLeaseExpiry:expiry}},request.players);
            report.recovery.restart = fresh;
            if (!fresh.ok) throw new Error('RECOVERY_RESTART_FAILED');
            const freshExecute = async (id,model,code) => decode(await freshTransport.call('execute_luau',{studio_id:id,datamodel_type:model,code}));
            report.recovery.loaded = await freshExecute(fresh.serverId,'Server',"return game:GetService('HttpService'):JSONEncode(game:GetService('ServerScriptService').ForgeBuildIdentity.Handshake:Invoke())");
            if (report.recovery.loaded.buildIdentity!==request.buildIdentity.id || report.recovery.loaded.sessionId===server.loaded.sessionId) throw new Error('RECOVERY_FRESH_BUILD_REQUIRED');
            report.recovery.loadedClients = [];
            for (const next of fresh.clients) {
              const loaded = await freshExecute(next.studioId,'Client',"return game:GetService('HttpService'):JSONEncode(game:GetService('Players').LocalPlayer.PlayerScripts.ForgeBuildIdentity.Handshake:Invoke())");
              if (loaded.actorId!==next.userId || loaded.buildIdentity!==request.buildIdentity.id || loaded.sessionId!==report.recovery.loaded.sessionId) throw new Error('RECOVERY_ACTOR_ADMISSION_FAILED');
              report.recovery.loadedClients.push(loaded);
            }
            report.recovery.loadTrace = await persistenceSnapshot(code => executeRawText(fresh.serverId, 'Server', code),
              budgetMs => { freshTransport.timeoutMs = budgetMs; freshTransport.deadline = Date.now() + budgetMs; },
              { totalBudgetMs: READBACK_TOTAL_BUDGET_MS, maxBytes: READBACK_MAX_BYTES, chunkBudgetMs: READBACK_CHUNK_BUDGET_MS })();
            if (report.recovery.loadTrace.identity.namespace!==local.namespace || report.recovery.loadTrace.identity.epoch===report.persistenceAfter.identity.epoch || report.recovery.loadTrace.overflow) throw new Error('RECOVERY_PERSISTENCE_CHANGED');
            const original = report.recovery.crash.originalCommand;
            if (!original || original.actorId!==actor.userId || original.namespace!==local.namespace
                || original.envelope?.sessionEpoch!==original.oldEpoch) throw new Error('OBSERVED_ORIGINAL_COMMAND_REQUIRED');
            const rejoined = fresh.clients.find(client=>client.userId===original.actorId);
            if (!rejoined || rejoined.studioId===actor.studioId) throw new Error('FRESH_AUTHENTICATED_ACTOR_REQUIRED');
            report.recovery.commandReplay = await replayRecorded(rejoined,{request:original.envelope},freshExecute);
            // Never rewrite the original epoch to evade current ingress. A
            // rejected stale request is retained, not called a successful replay.
            report.recovery.commandReplayAccepted=report.recovery.commandReplay.result?.ok===true;
            report.recovery.commandReplayRejection=report.recovery.commandReplayAccepted?null:report.recovery.commandReplay.result?.reason || 'UNKNOWN_REPLAY_REJECTION';
            report.recovery.after = store.rows(local.namespace);
            report.recovery.ownershipBefore = ownership(report.recovery.before);
            report.recovery.ownershipAfter = ownership(report.recovery.after);
            const ordered=value=>JSON.stringify(Object.entries(value).sort(([a],[b])=>a.localeCompare(b)));
            if (ordered(report.recovery.ownershipBefore)!==ordered(report.recovery.ownershipAfter)) throw new Error('CRASH_OWNERSHIP_CHANGED');
            const transferId=report.recovery.crash.barrier.requestId;
            const afterByKey=new Map(report.recovery.after.map(row=>[row.key,JSON.parse(row.value)]));
            const sourceReceipt=afterByKey.get(receipt.request.source)?.data?.itemTransfers?.receipts?.[transferId];
            const destinationReceipt=afterByKey.get(receipt.request.destination)?.data?.itemTransfers?.receipts?.[transferId];
            const binding=sourceReceipt?.request;
            const terminal=sourceReceipt?.phase==='FINALIZED' && Number.isSafeInteger(sourceReceipt.stateVersion)
              && destinationReceipt?.phase==='CREDITED' && binding?.id===transferId
              && binding?.actor===original.actorId && binding?.source===receipt.request.source
              && binding?.destination===receipt.request.destination
              && ['id','actor','epoch','expiresAt','source','destination','itemId','outputId','quantity']
                .every(key=>binding[key]===destinationReceipt.request?.[key]);
            report.recovery.terminalReadback={proven:!!terminal,transferId,sourceReceipt,destinationReceipt};
            if (!terminal) report.recovery.blockers.push('PERSISTED_TERMINAL_TRANSFER_NOT_PROVEN');
            report.recovery.replayReadback=store.rows(local.namespace);
            report.recovery.stableReadback=compareReplay(report.recovery.after,report.recovery.replayReadback);
          } finally { report.recovery.cleanup = await freshLifecycle.close(); request.signal?.removeEventListener('abort',cancelFresh); }
        } finally { store.close(); }
      }
    }
    for (const census of [report.censusBefore, report.censusAfter]) {
      if (JSON.stringify(census.npcs.map(npc => npc.id)) !== JSON.stringify(census.configuredIds)
          || census.observedCount > census.configuredMaximum) report.blockers.push('CONFIGURED_NPC_CENSUS_MISMATCH');
    }
  } catch (error) {
    lifecycle.fail('capacity-window', 'CAPACITY_WINDOW_FAILED');
    // Keep the real failure for evidence: CAPACITY_WINDOW_FAILED alone hides
    // which stage broke (same class as the collectorError record above).
    report.attemptError = String((error && error.stack) || (error && error.message) || error).slice(0, 600);
    report.blockers.push(error.message === 'LOADED_IDENTITY_MISMATCH' ? error.message : 'CAPACITY_WINDOW_FAILED');
  }
  return report;
}

if (import.meta.main) {
  const lifecycle = new StudioLifecycle();
  const controller = new AbortController();
  let output;
  const cancel = () => { controller.abort(); lifecycle.fail('cancel', 'CANCELLED'); void lifecycle.close(); };
  process.once('SIGINT', cancel); process.once('SIGTERM', cancel);
  try {
    // The request arrives as a file argument; plain stdin remains supported
    // for direct piping (Lune's process.exec stdin truncates in some sessions).
    let rawRequest;
    if (process.argv[2]) {
      rawRequest = await readFile(process.argv[2], 'utf8');
    } else {
      const chunks = [];
      for await (const chunk of process.stdin) chunks.push(chunk);
      rawRequest = Buffer.concat(chunks).toString('utf8');
    }
    const request = JSON.parse(rawRequest);
    const config = request.driver;
    // Lune cannot encode an empty array: args=[] arrives as an object. Accept
    // exactly that object form alongside a real string array (3829724 class).
    const args = config && Array.isArray(config.args) ? config.args
      : (config && config.args !== null && typeof config.args === 'object'
          && !Array.isArray(config.args) && Object.keys(config.args).length === 0 ? [] : null);
    if (!Number.isInteger(request.players) || request.players < 1 || !config
        || typeof config.command !== 'string' || !Array.isArray(args)
        || args.some(arg => typeof arg !== 'string')) throw new Error('COLLECTOR_CONFIG_REQUIRED');
    const actualCollector=await currentCollectorIdentity();
    const actualArtifact=sha256(await readFile(config.buildPath));
    if(actualCollector!==request.collectorIdentity || actualArtifact!==request.buildIdentity?.artifactSha256) throw new Error('CURRENT_INPUT_MISMATCH');
    const matrix = await collectMatrix({...request,signal:controller.signal}, async (next, job) => {
      const transport = new StdioMcp(config.command, config.args, 90000, job);
      await transport.initialize();
      return attempt(next, transport, job);
    });
    matrix.sourceVerification={before:actualCollector,after:await currentCollectorIdentity(),artifactBefore:actualArtifact,
      artifactAfter:sha256(await readFile(config.buildPath))};
    if(matrix.sourceVerification.after!==actualCollector || matrix.sourceVerification.artifactAfter!==actualArtifact) throw new Error('INPUT_CHANGED_DURING_COLLECTION');
    output = { ...await admitMatrix(matrix), matrix };
  } catch (error) {
    lifecycle.fail('capacity', 'COLLECTOR_FAILED');
    output = { ok: false, status: 'BLOCKED', admittedPlayers: 0, blockers: ['COLLECTOR_FAILED'],
      collectorError: String(error && error.message ? error.message : error) };
  } finally {
    const cleanup = await lifecycle.close();
    process.removeListener('SIGINT', cancel); process.removeListener('SIGTERM', cancel);
    output ??= { ok: false, status: 'BLOCKED', blockers: ['CANCELLED'] };
    output.lifecycle = cleanup;
    if (!cleanup.ok) output.blockers.push('OWNED_RESOURCE_UNRESOLVED');
    if (!cleanup.ok) { output.ok=false; output.status='BLOCKED'; }
    output.sha256 = createHash('sha256').update(JSON.stringify(output)).digest('hex');
    console.log(JSON.stringify(output));
    process.exitCode = output.ok ? 0 : 1;
  }
}
