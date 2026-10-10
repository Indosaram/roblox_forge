import { executeSteps } from './capacity-workload.mjs';

const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
const same = (a,b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));

export const saturationLimitsCode = "local p=game:GetService('ServerStorage'):FindFirstChild('ForgeCapacity');assert(p,'LOADED_CAPACITY_LIMITS_UNAVAILABLE');return game:GetService('HttpService'):JSONEncode(p.limits:Invoke())";

// Readback is an independent, complete database keyset, not runtime snapshots.
// Lease metadata may advance; application data must not change during refusal.
function application(rows) {
  if (!Array.isArray(rows) || !rows.length) throw new Error('PERSISTED_KEYSET_REQUIRED');
  const result = {};
  for (const row of rows) {
    if (!row.key || Object.hasOwn(result,row.key) || typeof row.value!=='string') throw new Error('PERSISTED_KEYSET_INVALID');
    const wrapper=JSON.parse(row.value);
    if (!wrapper?.data) throw new Error('PERSISTED_WRAPPER_REQUIRED');
    result[row.key]=wrapper.data;
  }
  return result;
}

export function validateSaturationRow(row) {
  const blockers=[...(row.blockers || [])];
  try {
    if (!Number.isSafeInteger(row.limit) || row.limit<1) throw new Error('LOADED_LIMIT_REQUIRED');
    if (row.kind==='npcs') {
      const p=row.probe;
      if (!p || p.limit!==row.limit || p.error || p.retryLimit!==0) throw new Error('NPC_PROBE_INCOMPLETE');
      if (!Number.isSafeInteger(p.before?.count) || p.before.count<1 || p.before.count>row.limit
          || !Array.isArray(p.before.ids) || p.before.ids.length!==p.before.count
          || new Set(p.before.ids).size!==p.before.count) throw new Error('NPC_INITIAL_CENSUS_INVALID');
      const alreadyFull=p.before.count===row.limit;
      if (alreadyFull ? p.boundary?.kind!=='existing-census' || !same(p.boundary.census,p.before)
          || Object.hasOwn(p.boundary,'accepted') || Object.hasOwn(p.boundary,'attemptedCount')
        : p.boundary?.kind!=='registration' || !p.boundary.accepted || p.boundary.attemptedCount!==row.limit
          || p.boundary.census?.count!==row.limit || !same(p.boundary,p.operations.at(-2))) throw new Error('NPC_BOUNDARY_UNPROVEN');
      if (p.refusal?.accepted!==false || p.refusal.attemptedCount!==row.limit+1
          || !p.refusal.reason?.includes('NPC_BUDGET_OR_ID') || p.refusal.census?.count!==row.limit
          || p.before.ids.includes(p.refusal.id)) throw new Error('NPC_REFUSAL_UNPROVEN');
      if (p.operations.length!==row.limit+1-p.before.count || p.attempts!==p.operations.length
          || p.operations.some((op,i)=>op.kind!=='registration' || op.attemptedCount!==p.before.count+i+1 || op.accepted!==(op.attemptedCount<=row.limit))
          || new Set(p.operations.map(op=>op.id)).size!==p.operations.length
          || p.operations.some(op=>p.before.ids.includes(op.id))
          || !same(p.refusal,p.operations.at(-1))) throw new Error('NPC_OPERATIONS_INCOMPLETE');
      if (!same(p.before,p.after) || !Array.isArray(p.cleanup?.remaining) || p.cleanup.remaining.length) throw new Error('NPC_CLEANUP_INCOMPLETE');
      if (!same(application(row.before),application(row.after))) throw new Error('REFUSAL_CHANGED_APPLICATION_STATE');
    } else if (row.kind==='jobs') {
      const p=row.probe;
      if (!p || p.limit!==row.limit || p.error || p.refusal?.result?.reason!=='JOB_QUEUE_FULL') throw new Error('JOB_REFUSAL_UNPROVEN');
      const persisted=rows=>rows?.find(r=>r.key===row.personalKey);
      if (!same(personalState(persisted(row.before),p.actorId),p.initial)
          || !same(personalState(persisted(row.atLimit),p.actorId),personalState(p.atLimit,p.actorId))
          || !same(personalState(persisted(row.after),p.actorId),personalState(p.afterRefusal,p.actorId))) throw new Error('JOB_READBACK_UNBOUND');
      let current=p.initial;
      for (const cycle of p.cycles) {
        const reserve=p.actions.find(op=>op.result?.result?.data?.jobId===cycle.jobId && op.result?.result?.ok);
        if (!reserve) throw new Error('JOB_OPERATION_UNBOUND');
        const after=personalState(cycle.persisted,p.actorId);
        checkCancelled(current,after,cycle.jobId,Object.keys(current.workshop.entries).length);
        current=after;
      }
      if (Object.keys(current.workshop.entries).length!==row.limit
          || !same(current,personalState(p.atLimit,p.actorId))
          || !same(current,personalState(p.afterRefusal,p.actorId))) throw new Error('JOB_BOUNDARY_UNPROVEN');
    } else if (!blockers.length) throw new Error('SATURATION_CAPABILITY_UNAVAILABLE');
  } catch(error) { blockers.push(error.message); }
  return [...new Set(blockers)];
}

// No callback-shaped synthetic cap adapters: only the maintained input and
// loaded runtime probe are executable here. Unsupported boundaries stay explicit.
export async function collectSaturation({admission,execute,ports,readback,loadedLimits,actor,personalKey}) {
  if (!admission?.ok || !admission.serverId || typeof execute!=='function' || typeof readback!=='function') throw new Error('OWNED_SATURATION_PORTS_REQUIRED');
  const limits=await execute(admission.serverId,'Server',saturationLimitsCode);
  if (loadedLimits && !same(limits,loadedLimits)) throw new Error('LOADED_CAPACITY_LIMITS_CHANGED');
  const rows=[];
  const unavailable={
    payloadBytes:{code:'EXACT_PAYLOAD_PUBLIC_OPERATION_UNAVAILABLE',source:'core/infra/data/FencedStore.luau:_commit -> EnvelopeBudget.check',detail:'Full wrappers are bounded by the loaded budget. Public genre commands have no arbitrary byte-padding field; smaller inventory, job and receipt validators can reject before an exact byte boundary. No padded save is committed.'},
    receipts:{code:'EXACT_RECEIPT_PUBLIC_OPERATION_UNAVAILABLE',source:'genres/survival-coop/module/GatheringRuntime.luau:command; TransferRuntime.luau; core/infra/genre/Session.luau',detail:'The loaded shared receipt limit is distinct from command outcomes and combat receipts. Gather consumes finite charges and inventory; transfer consumes retained source/destination receipts and command outcomes. No isolated shared-receipt bound-plus-one operation exists without satisfying those independent limits.'},
    admission:{code:'ACTUAL_EXTRA_CLIENT_ADMISSION_UNAVAILABLE',source:'genres/survival-coop/module/SurvivalBootstrap.luau:session.join; core/infra/genre/Server.luau:PlayerAdded',detail:'The bound is actual authenticated Session membership. Existing admitted clients cannot prove an additional client rejection. The saturation runner has no owned extra-client launch/termination port and never substitutes a string actor or synthetic join.'},
  };
  for (const kind of ['payloadBytes','receipts','jobs','npcs','admission']) {
    const row={kind,limit:limits[kind],loadedLimits:limits,before:null,atLimit:null,after:null,operations:[],boundary:null,refusal:null,attempts:0,retryLimit:0,cleanup:{allocatedResources:[],remaining:[]},blockers:[]};
    rows.push(row);
    try {
      row.before=await readback(); application(row.before);
      if (unavailable[kind]) {
        row.capability=unavailable[kind];row.blockers.push(row.capability.code);
      } else if (kind==='npcs') {
        row.probe=await execute(admission.serverId,'Server',"return game:GetService('HttpService'):JSONEncode(game:GetService('ServerStorage').ForgeCapacity.npcs:Invoke())");
        row.operations=row.probe.operations;row.boundary=row.probe.boundary;row.refusal=row.probe.refusal;
        row.attempts=row.probe.attempts;row.cleanup=row.probe.cleanup;
        // Probe is non-yielding and has no persistence writes. Its boundary is
        // an actual registration census, not a fabricated persisted NPC record.
        row.persistenceScope='unchanged-durable-application-state';
      } else {
        if (!actor || !admission.clients.some(c=>c.userId===actor.userId && c.studioId===actor.studioId) || !personalKey) throw new Error('JOB_ACTOR_READBACK_REQUIRED');
        row.personalKey=personalKey;
        let latestReadback;
        row.probe=await saturateWorkshop({actor,owned:admission,ports,limit:row.limit,readPersonal:async()=>{
          const all=await readback();
          const personal=all.find(r=>r.key===personalKey);
          if (!personal) throw new Error('PERSONAL_KEY_MISSING');
          latestReadback=all;
          return personal;
        },onBoundary:()=>{row.atLimit=latestReadback;}});
        row.operations=row.probe.actions;row.refusal=row.probe.refusal;
        row.attempts=row.operations.filter(op=>op.action).length;
        row.boundary=row.probe.atLimit;
      }
    } catch(error) { row.blockers.push(String(error.message)); }
    finally {
      try {row.after=await readback();} catch(error){row.blockers.push(String(error.message));}
    }
    row.blockers=validateSaturationRow(row);
  }
  return {rows,blockers:[...new Set(rows.flatMap(row=>row.blockers))]};
}

// Read actual application state from the complete personal persisted wrapper.
// Do not compare lease/revision or command-ledger metadata as gameplay state.
export function personalState(row, actorId) {
  const wrapper=JSON.parse(row.value);
  const data=wrapper?.data?.envelope?.genres?.['survival-coop']?.data;
  if (!data?.inventory?.bag || data.workshop?.actorId!==actorId || !data.workshop.entries) throw new Error('PERSISTED_PERSONAL_WORKSHOP_REQUIRED');
  return { inventory:data.inventory, workshop:data.workshop };
}

export function checkCancelled(before, after, jobId, count) {
  const entries=after.workshop.entries;
  if (Object.keys(entries).length!==count+1 || entries[jobId]?.job?.state!=='Cancelled') throw new Error('CANCELLED_JOB_NOT_PERSISTED');
  // Inventory versions legitimately advance; compare owned items and reserved
  // quantities, not a runtime conservation flag.
  const a={...before.inventory.bag}, b={...after.inventory.bag};
  delete a.version; delete b.version;
  if (!same(a,b)) throw new Error('CANCEL_CHANGED_INVENTORY');
  for (const [id,entry] of Object.entries(before.workshop.entries)) {
    if (!same(entry,entries[id])) throw new Error('PRIOR_RETAINED_JOB_CHANGED');
  }
}

export async function saturateWorkshop({actor,owned,ports,readPersonal,limit,onBoundary}, execute = executeSteps) {
  if (!Number.isSafeInteger(limit) || limit<1 || limit>64) throw new Error('ACTUAL_RETAINED_LIMIT_REQUIRED');
  const report={ok:false,kind:'retained-workshop-jobs',actorId:actor.userId,limit,actions:[],cycles:[]};
  const content=['Players','LocalPlayer','PlayerGui','ForgeSurvivalHUD','SafeArea','SurvivalSheet','Content'];
  const run=async steps=>{
    try { const rows=await execute(steps,actor,owned,ports);report.actions.push(...rows);return rows; }
    catch(error){report.actions.push(...(error.receipts||[]));report.failedStep=error.failedStep;throw error;}
  };
  try {
    let current=personalState(await readPersonal(),actor.userId);
    if (Object.values(current.workshop.entries).some(entry=>!['Cancelled','Committed'].includes(entry.job.state))) throw new Error('ACTIVE_JOB_PREVENTS_RETAINED_CAP_PROBE');
    report.initial=current;
    await run([{op:'keyboard',key:'C',timeout_seconds:5},{op:'click',target:[...content,'Recipe-cord'],timeout_seconds:5}]);
    for(let count=Object.keys(current.workshop.entries).length;count<limit;count++) {
      const rows=await run([
        {op:'click',target:[...content,'Reserve-cord'],resultAction:'survival-coop:craft-reserve',expect:'ok',timeout_seconds:10},
        {op:'bind_result',field:'data.jobId',label:'job'},
        {op:'click',target:[...content,{ref:'job',prefix:'cancel-'}],resultAction:'survival-coop:craft-cancel',expect:'ok',timeout_seconds:10},
      ]);
      const jobId=rows[0].result?.result?.data?.jobId;
      const persisted=await readPersonal();
      const after=personalState(persisted,actor.userId);
      checkCancelled(current,after,jobId,count);
      report.cycles.push({jobId,persisted});current=after;
    }
    report.atLimit=await readPersonal();
    onBoundary?.();
    const rows=await run([{op:'click',target:[...content,'Reserve-cord'],resultAction:'survival-coop:craft-reserve',expect:'refused',timeout_seconds:10}]);
    report.refusal=rows[0].result;
    if(report.refusal?.result?.reason!=='JOB_QUEUE_FULL')throw new Error('RETAINED_CAP_REJECTION_NOT_OBSERVED');
    report.afterRefusal=await readPersonal();
    if(!same(personalState(report.atLimit,actor.userId),personalState(report.afterRefusal,actor.userId)))throw new Error('REFUSED_JOB_CHANGED_APPLICATION_STATE');
    report.ok=true;
  } catch(error){report.error=String(error.cause?.message||error.message);}
  return report;
}
