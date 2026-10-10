import { test, expect } from 'bun:test';
import { latestRecords, compareReplay, replayRecorded, reconcileWorkload, ownership, gatheringTransitions, verifyLeaseRestart, verifyHeldAcquisition } from './capacity-persistence.mjs';

test('held acquisition rejects subsequent startup mutations and unbound migrations',()=>{
  const old=JSON.stringify({generation:1,lease:{sessionId:'old'},data:{quantity:3}});
  const fresh=JSON.stringify({generation:2,lease:{sessionId:'new'},data:{quantity:3}});
  const event={held:true,ackState:'held',phase:'LEASE_ACQUIRED',record:{previousSerialized:old,serialized:fresh}};
  expect(verifyHeldAcquisition(old,event,fresh).generation).toBe(2);
  const changed=JSON.stringify({generation:2,lease:{sessionId:'new'},data:{quantity:4}});
  expect(()=>verifyHeldAcquisition(old,event,changed)).toThrow('HELD_ACQUISITION_CONTAMINATED');
  expect(()=>verifyHeldAcquisition(old,{...event,record:{...event.record,serialized:changed}},changed)).toThrow('ACQUISITION_MIGRATION_NOT_PRESERVING');
  expect(()=>verifyLeaseRestart(old,fresh,{accepted:false,reason:'lease lost',transformExecuted:true},fresh)).toThrow('STALE_WRITER_NOT_REJECTED');
});

test('lease restart requires newer real generation and unchanged stale rejection readback',()=>{
  const old=JSON.stringify({generation:2,lease:{sessionId:'old'},data:{items:3}});
  const fresh=JSON.stringify({generation:3,lease:{sessionId:'fresh'},data:{items:3}});
  expect(verifyLeaseRestart(old,fresh,{accepted:false,reason:'lease lost',transformExecuted:false},fresh).newGeneration).toBe(3);
  expect(()=>verifyLeaseRestart(old,old,{accepted:false,reason:'lease lost',transformExecuted:false},old)).toThrow('FRESH_LEASE_GENERATION_REQUIRED');
  expect(()=>verifyLeaseRestart(old,fresh,{accepted:true},fresh)).toThrow('STALE_WRITER_NOT_REJECTED');
  expect(()=>verifyLeaseRestart(old,fresh,{accepted:false,reason:'lease lost',transformExecuted:false},fresh+' ')).toThrow('STALE_WRITER_MUTATED_RECORD');
});

test('workload reconciliation accounts real catalog mint and consumption once', () => {
  const rows=items=>[{key:'personal',value:JSON.stringify({data:{inventory:{version:1,items}}})}];
  const action={actorId:'a',action:'survival-coop:gather',result:{requestId:'g',sessionEpoch:1,nodeId:'node',result:{ok:true}}};
  const content={worldNodes:[{id:'node',catalogId:'fiber'}],nodes:[{id:'fiber',harvest:[{item:'fiber',quantity:3}]}],recipes:[],structures:[]};
  const after=rows({one:{catalogId:'fiber',quantity:3}});
  const proof=[{actorId:'a',sessionEpoch:1,requestId:'g',nodeId:'node'}];
  expect(reconcileWorkload(rows({}),after,[action,action],content,proof).ok).toBe(true);
  expect(reconcileWorkload(rows({}),rows({one:{catalogId:'fiber',quantity:6}}),[action],content,proof).ok).toBe(false);
});

test('gather charge proof binds durable epoch grant and exact output',()=>{
  const id='g1:a:2:1:r';
  const before={data:{nodes:{version:0,nodes:{node:{catalogId:'fiber',charges:3,qualityMilli:1000}}},grants:{}}};
  const after=structuredClone(before);after.data.nodes.version=1;after.data.nodes.nodes.node.charges=2;
  after.data.grants[id]={mints:[{request:{id:`${id}:output:1`,actor:'a',epoch:'2',source:'nodes',quantity:3},item:{catalogId:'fiber',quantity:3,qualityMilli:1000}}]};
  const rows=value=>[{key:'nodes',value:JSON.stringify(value)}];
  const commits=[{key:'nodes',sequence:1,previousSerialized:JSON.stringify(before),serialized:JSON.stringify(after)}];
  const actions=[{actorId:'a',action:'survival-coop:gather',result:{requestId:'r',nodeId:'node',result:{ok:true}}}];
  const content={worldNodes:[{id:'node',catalogId:'fiber'}],nodes:[{id:'fiber',harvest:[{item:'fiber',quantity:3}]}]};
  expect(gatheringTransitions(rows(before),rows(after),commits,[...actions,...actions],content)[0].sessionEpoch).toBe(2);
  after.data.nodes.nodes.node.charges=1;commits[0].serialized=JSON.stringify(after);
  expect(()=>gatheringTransitions(rows(before),rows(after),commits,actions,content)).toThrow('GATHER_CHARGE_MISMATCH');
});

test('a matured respawn is validated by its timer, capacity and completion time',()=>{
  const rows=value=>[{key:'nodes',value:JSON.stringify(value)}];
  const content={worldNodes:[{id:'node',catalogId:'fiber',charges:3}],nodes:[{id:'fiber',harvest:[{item:'fiber',quantity:3}],respawnMillis:1000}],recipes:[],structures:[]};
  const before={data:{nodes:{version:9,worldRevision:'w',nodes:{node:{catalogId:'fiber',charges:0,qualityMilli:1000}}},grants:{},respawns:{node:{capacity:3,deadline:1000}}}};
  const matured=()=>{const after=structuredClone(before);after.data.nodes.version=10;after.data.nodes.nodes.node.charges=3;delete after.data.respawns.node.deadline;return after;};
  const commits=(after,endedAtMs)=>[{key:'nodes',sequence:1,startedAtMs:900,endedAtMs,previousSerialized:JSON.stringify(before),serialized:JSON.stringify(after)}];
  const run=(after,endedAtMs)=>gatheringTransitions(rows(before),rows(after),commits(after,endedAtMs),[],content);
  expect(run(matured(),1001)).toEqual([]);
  // A request may start before the deadline and complete after it; a completion before the
  // deadline, or a missing completion time, refuses rather than approving an unproven restore.
  expect(()=>run(matured(),999)).toThrow('REPLENISHMENT_NOT_MATURED');
  expect(()=>run(matured(),undefined)).toThrow('REPLENISHMENT_NOT_MATURED');
  // A restore that lands below capacity, or whose deadline is still pending, is an unbound
  // charge change rather than a replenishment.
  const partial=matured();partial.data.nodes.nodes.node.charges=2;
  expect(()=>run(partial,1001)).toThrow('GATHER_UNBOUND_CHARGE_OR_REPLENISHMENT');
  const held=matured();held.data.respawns.node.deadline=1000;
  expect(()=>run(held,1001)).toThrow('GATHER_UNBOUND_CHARGE_OR_REPLENISHMENT');
  // A timer capacity that disagrees with the configured charges refuses.
  const wrongCapacity=matured();wrongCapacity.data.respawns.node.capacity=5;
  expect(()=>run(wrongCapacity,1001)).toThrow('REPLENISHMENT_BINDING_MISMATCH');
  // A version skip, a node mutation and a node-set change refuse.
  const skip=matured();skip.data.nodes.version=11;
  expect(()=>run(skip,1001)).toThrow('GATHER_REPLENISHMENT_VERSION_MISMATCH');
  const mutated=matured();mutated.data.nodes.nodes.node.qualityMilli=500;
  expect(()=>run(mutated,1001)).toThrow('GATHER_NODE_MUTATED');
  const added=matured();added.data.nodes.nodes.extra={catalogId:'fiber',charges:3,qualityMilli:1000};
  expect(()=>run(added,1001)).toThrow('GATHER_NODE_SET_CHANGED');
});

test('a gather may restore matured neighbours and a capacity-1 node it then gathers to zero',()=>{
  const rows=value=>[{key:'nodes',value:JSON.stringify(value)}];
  const content={worldNodes:[{id:'node',catalogId:'fiber',charges:3},{id:'other',catalogId:'fiber',charges:3},{id:'thin',catalogId:'fiber',charges:1}],
    nodes:[{id:'fiber',harvest:[{item:'fiber',quantity:3}],respawnMillis:1000}],recipes:[],structures:[]};
  const grantId='g1:a:2:1:r';
  const mint={request:{id:`${grantId}:output:1`,actor:'a',epoch:'2',source:'nodes',quantity:3},item:{catalogId:'fiber',quantity:3,qualityMilli:1000}};
  const actions=[{actorId:'a',action:'survival-coop:gather',result:{requestId:'r',nodeId:'thin',result:{ok:true}}}];
  const commit=(before,after)=>[{key:'nodes',sequence:1,startedAtMs:900,endedAtMs:1001,previousSerialized:JSON.stringify(before),serialized:JSON.stringify(after)}];
  const before={data:{nodes:{version:9,worldRevision:'w',nodes:{
      node:{catalogId:'fiber',charges:3,qualityMilli:1000},
      other:{catalogId:'fiber',charges:0,qualityMilli:1000},
      thin:{catalogId:'fiber',charges:0,qualityMilli:1000}}},grants:{},
    respawns:{node:{capacity:3},other:{capacity:3,deadline:1000},thin:{capacity:1,deadline:1000}}}};
  const after=structuredClone(before);
  after.data.nodes.version=12;                       // 9 + other + thin + the gather
  after.data.nodes.nodes.other.charges=3;
  after.data.nodes.nodes.thin.charges=0;             // 1, then gathered straight back to 0
  delete after.data.respawns.other.deadline;
  after.data.respawns.thin.deadline=2000;            // re-armed by the immediate depletion
  after.data.grants[grantId]={mints:[mint]};
  const proof=gatheringTransitions(rows(before),rows(after),commit(before,after),actions,content);
  expect(proof.length).toBe(1);
  expect(proof[0].nodeId).toBe('thin');
  expect(proof[0].beforeCharges).toBe(0);
  expect(proof[0].afterCharges).toBe(0);
  // Omitting either restore's version step refuses.
  const skipped=structuredClone(after);skipped.data.nodes.version=11;
  expect(()=>gatheringTransitions(rows(before),rows(skipped),commit(before,skipped),actions,content)).toThrow('GATHER_REPLENISHMENT_VERSION_MISMATCH');
  // A re-armed deadline on a restore that did not end empty refuses.
  const badTimer=structuredClone(after);badTimer.data.respawns.other.deadline=2000;
  expect(()=>gatheringTransitions(rows(before),rows(badTimer),commit(before,badTimer),actions,content)).toThrow('REPLENISHMENT_TIMER_INVALID');
  // An unexplained restoration with no maturity and no gather is an unbound charge change.
  const unbound=structuredClone(before);unbound.data.nodes.version=10;unbound.data.nodes.nodes.other.charges=3;
  expect(()=>gatheringTransitions(rows(before),rows(unbound),commit(before,unbound),[],content)).toThrow('GATHER_UNBOUND_CHARGE_OR_REPLENISHMENT');
  // A grant without a correlated gather action cannot be bound to a node.
  const noAction=structuredClone(after);
  expect(()=>gatheringTransitions(rows(before),rows(noAction),commit(before,noAction),[],content)).toThrow('GATHER_ACTION_UNBOUND');
});

test('credited escrow is not counted twice and missing destination fails closed', () => {
  const request={destination:'target'};
  const source={key:'source',value:JSON.stringify({data:{itemTransfers:{receipts:{x:{phase:'ESCROWED',request,item:{catalogId:'wood',quantity:3}}}}}})};
  const target={key:'target',value:JSON.stringify({data:{inventory:{version:1,items:{x:{catalogId:'wood',quantity:3}}},itemTransfers:{receipts:{x:{phase:'CREDITED',request}}}}})};
  expect(ownership([source,target]).wood).toBe(3);
  expect(()=>ownership([source])).toThrow('ESCROW_DESTINATION_READBACK_REQUIRED');
});

test('duplicate durable keys and missing epochs cannot hide ownership',()=>{
  const row={key:'same',value:JSON.stringify({data:{}})};
  expect(()=>ownership([row,row])).toThrow('DUPLICATE_READBACK_KEY');
  expect(()=>reconcileWorkload([row],[row],[{actorId:'a',action:'survival-coop:gather',result:{requestId:'g',result:{ok:true}}}],{}))
    .toThrow('CONSERVATION_REQUEST_EPOCH_REQUIRED');
});

test('whole persisted application data detects repeated credit while allowing lease metadata', () => {
  const row = (n, revision) => [{ key: 'personal', value: JSON.stringify({ revision, data: { inventory: { items: { wood: { quantity: n } } } } }) }];
  expect(compareReplay(row(3, 1), row(3, 2)).sameApplicationData).toBe(true);
  expect(() => compareReplay(row(3, 1), row(6, 2))).toThrow('REPLAY_CHANGED_APPLICATION_STATE');
});

test('overflow cannot masquerade as complete commit trace', () => {
  expect(() => latestRecords({ identity: { namespace: 'owned' }, overflow: true, records: [] })).toThrow('INCOMPLETE_PERSISTENCE_TRACE');
});

test('replay requires recorded immutable transfer binding before remote invocation', async () => {
  let invoked = false;
  await expect(replayRecorded({}, { request: { action: 'invented' } }, async () => { invoked = true; }))
    .rejects.toThrow('RECORDED_TRANSFER_REQUEST_REQUIRED');
  expect(invoked).toBe(false);
});
