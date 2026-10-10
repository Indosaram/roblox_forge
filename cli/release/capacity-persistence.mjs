import { createHash } from 'node:crypto';

// Independent byte/readback comparisons, never a runtime noLoss boolean.
export function latestRecords(observation) {
  if (!observation?.identity?.namespace || observation.overflow || !Array.isArray(observation.records)) throw new Error('INCOMPLETE_PERSISTENCE_TRACE');
  const records = new Map();
  for (const record of observation.records) {
    if (typeof record.key !== 'string' || typeof record.serialized !== 'string'
        || !Number.isSafeInteger(record.sequence) || !Number.isFinite(record.latencyMs) || record.latencyMs < 0) throw new Error('INVALID_COMMIT_RECORD');
    const wrapper = JSON.parse(record.serialized);
    if (!wrapper || typeof wrapper.data !== 'object') throw new Error('FULL_WRAPPER_REQUIRED');
    const previous = records.get(record.key);
    if (!previous || record.sequence > previous.sequence) records.set(record.key, { ...record, wrapper,
      byteCount: Buffer.byteLength(record.serialized), sha256: createHash('sha256').update(record.serialized).digest('hex') });
  }
  return records;
}

const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;

export function compareReplay(before, after) {
  if (!Array.isArray(before) || !before.length || !Array.isArray(after) || before.length !== after.length) throw new Error('READBACK_REQUIRED');
  const right = new Map(after.map(row => [row.key, row]));
  if (right.size !== after.length || new Set(before.map(row=>row.key)).size!==before.length) throw new Error('DUPLICATE_READBACK_KEY');
  for (const row of before) {
    const next = right.get(row.key);
    if (!next) throw new Error('READBACK_KEY_CHANGED');
    const a = JSON.parse(row.value), b = JSON.parse(next.value);
    // Only wrapper lease/revision metadata may change; complete application data
    // must stay equal for replay of an already-finalized recorded request.
    if (JSON.stringify(canonical(a.data)) !== JSON.stringify(canonical(b.data))) throw new Error('REPLAY_CHANGED_APPLICATION_STATE');
  }
  return { sameApplicationData: true, keys: before.map(row => row.key) };
}

export function verifyLeaseRestart(oldBytes, newBytes, rejection, unchangedBytes) {
  const old=JSON.parse(oldBytes), fresh=JSON.parse(newBytes);
  if(!old.lease?.sessionId || !Number.isSafeInteger(old.generation) || !fresh.lease?.sessionId
      || fresh.lease.sessionId===old.lease.sessionId || !Number.isSafeInteger(fresh.generation)
      || fresh.generation<=old.generation)throw new Error('FRESH_LEASE_GENERATION_REQUIRED');
  if(!sameData(old.data,fresh.data))throw new Error('LEASE_RESTART_APPLICATION_CHANGED');
  if(rejection?.accepted!==false || rejection.reason!=='lease lost' || rejection.transformExecuted!==false)throw new Error('STALE_WRITER_NOT_REJECTED');
  if(newBytes!==unchangedBytes)throw new Error('STALE_WRITER_MUTATED_RECORD');
  return {oldGeneration:old.generation,newGeneration:fresh.generation,staleWriterRejected:true};
}
const sameData=(a,b)=>JSON.stringify(canonical(a))===JSON.stringify(canonical(b));

export function verifyHeldAcquisition(crashedBytes, event, durableBytes) {
  const crashed=JSON.parse(crashedBytes), previous=JSON.parse(event.record.previousSerialized), current=JSON.parse(event.record.serialized);
  if(!event.held || event.ackState!=='held' || event.phase!=='LEASE_ACQUIRED')throw new Error('FRESH_ACQUISITION_NOT_HELD');
  if(!sameData(crashed,previous))throw new Error('ACQUISITION_PREVIOUS_RECORD_CHANGED');
  if(!sameData(current,JSON.parse(durableBytes)))throw new Error('HELD_ACQUISITION_CONTAMINATED');
  if(current.generation!==crashed.generation+1 || current.lease?.sessionId===crashed.lease?.sessionId)throw new Error('ACQUISITION_GENERATION_MISMATCH');
  if(!sameData(previous.data,current.data))throw new Error('ACQUISITION_MIGRATION_NOT_PRESERVING');
  return current;
}

export function ownership(rows) {
  if (!Array.isArray(rows) || new Set(rows.map(row=>row.key)).size!==rows.length) throw new Error('DUPLICATE_READBACK_KEY');
  const wrappers = new Map(rows.map(row => [row.key, JSON.parse(row.value)]));
  const totals = {};
  const add = item => {
    if (typeof item.catalogId !== 'string' || !Number.isSafeInteger(item.quantity) || item.quantity < 0) throw new Error('INVALID_PERSISTED_ITEM');
    totals[item.catalogId] = (totals[item.catalogId] || 0) + item.quantity;
  };
  const walk = value => {
    if (!value || typeof value !== 'object') return;
    // Inventory.save containers carry items; receipt payloads/reservations are
    // not separate ownership and must never enter this traversal.
    if (value.items && value.version != null) {
      for (const item of Object.values(value.items)) add(item);
      return;
    }
    for (const [key, child] of Object.entries(value)) {
      if (!['itemTransfers', 'transferGrants', 'workshop', 'receipts', 'reservations'].includes(key)) walk(child);
    }
  };
  for (const wrapper of wrappers.values()) walk(wrapper.data);
  for (const wrapper of wrappers.values()) {
    for (const [id, receipt] of Object.entries(wrapper.data?.itemTransfers?.receipts || {})) {
      if (receipt.phase !== 'ESCROWED' || !receipt.item) continue;
      const destination = wrappers.get(receipt.request?.destination);
      if (!destination) throw new Error('ESCROW_DESTINATION_READBACK_REQUIRED');
      const credited = destination.data?.itemTransfers?.receipts?.[id];
      if (!credited || !['CREDITED', 'SOURCE_FINALIZED'].includes(credited.phase)) add(receipt.item);
    }
  }
  return totals;
}

export function reconcileWorkload(before, after, actions, content, gathers) {
  const expected = ownership(before);
  const actual = ownership(after);
  const seen = new Set();
  const delta = (id, quantity) => { expected[id] = (expected[id] || 0) + quantity; };
  for (const action of actions) {
    const packet = action.result;
    if (!packet?.result?.ok) continue;
    const request = packet.request;
    const requestId = request?.requestId || packet.requestId;
    if (!requestId) throw new Error('CONSERVATION_REQUEST_ID_REQUIRED');
    const provedGather=action.action==='survival-coop:gather' ? gathers?.find(row=>row.actorId===action.actorId && row.requestId===requestId && row.nodeId===packet.nodeId) : undefined;
    const epoch=request?.sessionEpoch ?? packet.sessionEpoch ?? provedGather?.sessionEpoch;
    if (!Number.isSafeInteger(epoch)) throw new Error('CONSERVATION_REQUEST_EPOCH_REQUIRED');
    const binding = JSON.stringify([action.actorId,epoch,requestId]);
    if (seen.has(binding)) continue;
    seen.add(binding);
    if (action.action === 'survival-coop:gather') {
      if (!provedGather || provedGather.sessionEpoch!==epoch) throw new Error('GATHER_CHARGE_PROOF_REQUIRED');
      const catalogId = content.worldNodes.find(node => node.id === packet.nodeId)?.catalogId;
      const node = content.nodes.find(node => node.id === catalogId);
      if (!node) throw new Error('CONSERVATION_NODE_BINDING_REQUIRED');
      for (const item of node.harvest) delta(item.item, item.quantity);
    } else if (action.action === 'survival-coop:craft-complete') {
      const recipe = content.recipes.find(recipe => recipe.id === action.recipeId);
      if (!recipe) throw new Error('CONSERVATION_RECIPE_BINDING_REQUIRED');
      for (const item of recipe.inputs) delta(item.item, -item.quantity);
      for (const item of recipe.outputs) delta(item.item, item.quantity);
    } else if (action.action === 'survival-coop:settlement-place') {
      const structure = content.structures.find(value => value.id === action.structureId);
      if (!structure) throw new Error('CONSERVATION_STRUCTURE_BINDING_REQUIRED');
      for (const item of structure.cost) delta(item.item, -item.quantity);
    } else if (!['survival-coop:transfer-deposit', 'survival-coop:transfer-withdraw',
      'survival-coop:craft-reserve', 'survival-coop:craft-start', 'survival-coop:craft-cancel', 'survival-coop:settlement-reserve'].includes(action.action)) {
      throw new Error('CONSERVATION_UNACCOUNTED_ACTION');
    }
  }
  const keys = new Set([...Object.keys(expected), ...Object.keys(actual)]);
  const differences = [...keys].filter(key => (expected[key] || 0) !== (actual[key] || 0))
    .map(key => ({ catalogId: key, expected: expected[key] || 0, actual: actual[key] || 0 }));
  return { ok: differences.length === 0, expected, actual, differences, distinctRequests: seen.size };
}

export function gatheringTransitions(before, after, commits, actions, content) {
  // ownership validates duplicate keysets before maps can collapse them.
  ownership(before); ownership(after);
  const baseline=new Map(before.map(row=>[row.key,JSON.parse(row.value)]));
  const final=new Map(after.map(row=>[row.key,JSON.parse(row.value)]));
  const proofs=[];
  for (const [key, wrapper] of baseline) {
    if (!wrapper.data?.nodes?.nodes || !wrapper.data.grants) continue;
    let current=wrapper;
    for (const record of commits.filter(row=>row.key===key).sort((a,b)=>a.sequence-b.sequence)) {
      const previous=JSON.parse(record.previousSerialized), next=JSON.parse(record.serialized);
      if (JSON.stringify(canonical(previous))!==JSON.stringify(canonical(current))) throw new Error('GATHER_COMMIT_CHAIN_INCOMPLETE');
      const added=Object.entries(next.data.grants).filter(([id])=>!previous.data.grants[id]);
      // A grant present in both versions must be byte-identical. Removal is the legitimate
      // runtime.recover() retirement path on this key, so removals are not adjudicated here.
      for (const [grantKey, grant] of Object.entries(previous.data.grants)) {
        if (next.data.grants[grantKey] && JSON.stringify(canonical(next.data.grants[grantKey]))!==JSON.stringify(canonical(grant))) throw new Error('GATHER_GRANT_MODIFIED');
      }
      const previousNodes=previous.data.nodes.nodes, nextNodes=next.data.nodes.nodes;
      if (JSON.stringify(Object.keys(previousNodes).sort())!==JSON.stringify(Object.keys(nextNodes).sort())) throw new Error('GATHER_NODE_SET_CHANGED');
      // The producer changes only a node's charges (replenish() writes charges and the version;
      // Gathering.gather() decrements charges), so every other field of every node is identical.
      for (const nodeId of Object.keys(previousNodes)) {
        if (JSON.stringify(canonical({ ...previousNodes[nodeId], charges: nextNodes[nodeId].charges }))!==JSON.stringify(canonical(nextNodes[nodeId]))) throw new Error('GATHER_NODE_MUTATED');
      }
      // Transform order is replenish() then Gathering.gather() (GatheringRuntime.luau:199).
      // replenish() restores every node whose respawn deadline matured to its timer capacity
      // (version +1 each, deadline cleared at the single site :76); the gather then removes one
      // charge from the request's node (version +1) and re-arms a deadline when that node ends
      // depleted (:261). A deadline that is gone, or later than before, is that restore's mark.
      const priorTimers=previous.data.respawns||{}, timers=next.data.respawns||{};
      const restored={};
      for (const nodeId of Object.keys(previousNodes)) {
        const prior=priorTimers[nodeId], timer=timers[nodeId], oldNode=previousNodes[nodeId];
        if (!prior || !Number.isSafeInteger(prior.deadline) || prior.deadline<1) continue;
        const cleared=!!timer && timer.deadline===undefined;
        const rearmed=!!timer && Number.isSafeInteger(timer.deadline) && timer.deadline>prior.deadline;
        if (!cleared && !rearmed) continue;
        const definition=content.nodes.find(row=>row.id===oldNode.catalogId);
        const configured=content.worldNodes.find(row=>row.id===nodeId);
        if (!definition || configured?.catalogId!==oldNode.catalogId || !Number.isSafeInteger(prior.capacity)
            || !Number.isSafeInteger(configured.charges) || configured.charges!==prior.capacity
            || !timer || timer.capacity!==prior.capacity || oldNode.charges!==0) throw new Error('REPLENISHMENT_BINDING_MISMATCH');
        // ObservedBackend records startedAtMs before the transform and endedAtMs after it, both
        // from DateTime.now().UnixTimestampMillis, the same epoch-millisecond domain as the
        // stored deadline, so the transform may run after the deadline even when the request
        // started before it. Maturity is corroborated by the completion time; a missing value
        // refuses rather than approving an unproven restore.
        if (!Number.isSafeInteger(record.endedAtMs) || record.endedAtMs<prior.deadline) throw new Error('REPLENISHMENT_NOT_MATURED');
        restored[nodeId]=prior.capacity;
      }
      // The gather target comes from the correlated action, never from charge differences: a
      // capacity-1 node restores to 1 and is gathered back to 0, so its charges are equal in
      // both versions and no charge difference identifies it.
      let gather=null;
      if (added.length) {
        if (added.length!==1) throw new Error('GATHER_TRANSITION_NOT_SINGLE');
        const [grantId,grant]=added[0];
        const mint=grant.mints?.[0], req=mint?.request;
        const epoch=Number(req?.epoch);
        if (!req || !Number.isSafeInteger(epoch) || epoch<0 || req.source!==key) throw new Error('GATHER_MINT_IDENTITY_REQUIRED');
        const prefix=`g${Buffer.byteLength(req.actor)}:${req.actor}:${epoch}:`;
        if (!grantId.startsWith(prefix)) throw new Error('GATHER_GRANT_IDENTITY_MISMATCH');
        const suffix=grantId.slice(prefix.length), colon=suffix.indexOf(':');
        const requestId=suffix.slice(colon+1);
        if (colon<1 || Number(suffix.slice(0,colon))!==Buffer.byteLength(requestId)) throw new Error('GATHER_REQUEST_ID_MISMATCH');
        const action=actions.find(row=>row.action==='survival-coop:gather' && row.actorId===req.actor && row.result?.requestId===requestId);
        if (!action || typeof action.result?.nodeId!=='string') throw new Error('GATHER_ACTION_UNBOUND');
        gather={grantId,grant,req,epoch,requestId,nodeId:action.result.nodeId};
      }
      // Expected charges: previous, plus each restore, minus the gather's single charge.
      for (const nodeId of Object.keys(previousNodes)) {
        let expected=previousNodes[nodeId].charges;
        if (restored[nodeId]!==undefined) expected=restored[nodeId];
        if (gather?.nodeId===nodeId) expected-=1;
        if (nextNodes[nodeId].charges!==expected) {
          if (gather?.nodeId===nodeId) throw new Error('GATHER_CHARGE_MISMATCH');
          throw new Error('GATHER_UNBOUND_CHARGE_OR_REPLENISHMENT');
        }
      }
      if (next.data.nodes.version!==previous.data.nodes.version+Object.keys(restored).length+(gather?1:0)) throw new Error('GATHER_REPLENISHMENT_VERSION_MISMATCH');
      // A restore that did not end empty cannot have re-armed a deadline.
      for (const nodeId of Object.keys(restored)) {
        const endsEmpty=nextNodes[nodeId].charges===0;
        if (endsEmpty ? timers[nodeId].deadline===undefined : timers[nodeId].deadline!==undefined) throw new Error('REPLENISHMENT_TIMER_INVALID');
      }
      if (gather) {
        const {grantId,grant,req,epoch,requestId,nodeId}=gather;
        const oldNode=previousNodes[nodeId], node=nextNodes[nodeId];
        const definition=content.nodes.find(row=>row.id===node.catalogId);
        const configured=content.worldNodes.find(row=>row.id===nodeId);
        if (!definition || configured?.catalogId!==node.catalogId) throw new Error('GATHER_CHARGE_MISMATCH');
        if (grant.mints.length!==definition.harvest.length) throw new Error('GATHER_OUTPUT_COUNT_MISMATCH');
        definition.harvest.forEach((output,index)=>{
          const value=grant.mints[index], item=value.item, identity=`${grantId}:output:${index+1}`;
          if (item.catalogId!==output.item || item.quantity!==output.quantity || item.qualityMilli!==oldNode.qualityMilli
              || value.request.id!==identity || value.request.quantity!==output.quantity || value.request.actor!==req.actor
              || value.request.epoch!==req.epoch || value.request.source!==key) throw new Error('GATHER_OUTPUT_BINDING_MISMATCH');
        });
        proofs.push({key,grantId,actorId:req.actor,sessionEpoch:epoch,requestId,nodeId,beforeCharges:oldNode.charges,afterCharges:node.charges,mints:grant.mints});
      }
      current=next;
    }
    if (JSON.stringify(canonical(current))!==JSON.stringify(canonical(final.get(key)))) throw new Error('GATHER_FINAL_READBACK_MISMATCH');
  }
  const successful=actions.filter(row=>row.action==='survival-coop:gather' && row.result?.result?.ok);
  for (const proof of proofs) {
    if (!successful.some(row=>row.actorId===proof.actorId && row.result.requestId===proof.requestId && row.result.nodeId===proof.nodeId)) throw new Error('GATHER_WITHOUT_SUCCESSFUL_ACTION');
  }
  for (const row of successful) {
    const matches=proofs.filter(proof=>proof.actorId===row.actorId && proof.requestId===row.result.requestId && proof.nodeId===row.result.nodeId);
    if (matches.length!==1) throw new Error('GATHER_ACTION_EPOCH_AMBIGUOUS_OR_UNPROVEN');
  }
  return proofs;
}

export async function replayRecorded(client, packet, execute) {
  const request = packet?.request;
  if (!request || typeof request.requestId !== 'string' || !Number.isSafeInteger(request.sessionEpoch)
      || !['survival-coop:transfer-deposit', 'survival-coop:transfer-withdraw'].includes(request.action)
      || !Array.isArray(request.args)) throw new Error('RECORDED_TRANSFER_REQUEST_REQUIRED');
  // JSONDecode preserves the recorded request, including its original epoch.
  // Do not upgrade a stale request to a new epoch or mint a new request ID.
  return execute(client.studioId, 'Client', `local p=game:GetService('Players').LocalPlayer
assert(tostring(p.UserId)==${JSON.stringify(client.userId)},'REPLAY_ACTOR_MISMATCH')
local request=game:GetService('HttpService'):JSONDecode(${JSON.stringify(JSON.stringify(request))})
local result=game:GetService('ReplicatedStorage').ForgeAction:InvokeServer('command',request)
return game:GetService('HttpService'):JSONEncode({request=request,result=result})`);
}

export const censusCode = `local ids={};local seen={}
local policy=require(game:GetService('ReplicatedStorage').Forge.games['primal-isles'].src.shared.WildlifePolicy)
for _,model in workspace:GetDescendants() do
 local id=model:GetAttribute('ForgeWildlifeId')
 if id then assert(not seen[id],'DUPLICATE_NPC_ID');seen[id]=true;table.insert(ids,{id=id,kind=model:GetAttribute('ForgeWildlifeKind')}) end
end
table.sort(ids,function(a,b) return a.id<b.id end)
local configured={};for _,spawn in policy.spawns do table.insert(configured,spawn.id) end;table.sort(configured)
return game:GetService('HttpService'):JSONEncode({npcs=ids,observedCount=#ids,configuredIds=configured,configuredCount=#configured,configuredMaximum=policy.maximum,robloxVersion=version()})`;
