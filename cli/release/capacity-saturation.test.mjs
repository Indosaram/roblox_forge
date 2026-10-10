import { test, expect } from 'bun:test';
import { checkCancelled, personalState, saturateWorkshop, validateSaturationRow } from './capacity-saturation.mjs';

const state=()=>({inventory:{bag:{version:1,items:{fiber:{catalogId:'fiber',quantity:3}},reservations:{}}},workshop:{actorId:'a',entries:{}}});
test('cancelled retained job conserves owned inputs and clears reservations',()=>{
  const before=state(),after=state();
  after.inventory.bag.version=3;
  after.workshop.entries.job={job:{state:'Cancelled'}};
  expect(()=>checkCancelled(before,after,'job',0)).not.toThrow();
  after.inventory.bag.reservations.job={fiber:3};
  expect(()=>checkCancelled(before,after,'job',0)).toThrow('CANCEL_CHANGED_INVENTORY');
});

function persistedInputHarness(corrupt = false) {
  const data=state();let serial=0;const calls=[];
  const listeners=new Set();
  const ports={
    subscribe: listener=>{listeners.add(listener);return()=>listeners.delete(listener);},
    input(action){
      calls.push(action);
      let result;
      if(action==='survival-coop:craft-reserve'){
        if(Object.keys(data.workshop.entries).length===2)result={ok:false,reason:'JOB_QUEUE_FULL'};
        else {
          const jobId=`job-${++serial}`;
          data.workshop.entries[jobId]={job:{state:'Reserved'}};
          data.inventory.bag.reservations[jobId]={fiber:3};
          result={ok:true,data:{jobId}};
        }
      }else{
        const jobId=`job-${serial}`;
        data.workshop.entries[jobId].job.state='Cancelled';
        delete data.inventory.bag.reservations[jobId];
        if(corrupt && serial===2)data.workshop.entries['job-1'].job.state='Reserved';
        result={ok:true};
      }
      for(const listener of listeners)listener({request:{requestId:`input-${calls.length}`,action},result});
    },
  };
  // Deterministic input adapter at the executeSteps seam: exact response listener
  // exists before action, and actual state transitions determine its response.
  const execute=async steps=>{
    const rows=[];
    for(const step of steps){
      if(!step.resultAction)continue;
      let packet;const dispose=ports.subscribe(value=>{packet=value;});
      try{ports.input(step.resultAction);}finally{dispose();}
      if(!packet)throw new Error('missing subscribed response');
      rows.push({op:step.op,result:packet});
      if(packet.result.ok!==(step.expect==='ok')){const error=new Error('unexpected input result');error.receipts=rows;error.failedStep=step;throw error;}
    }
    return rows;
  };
  return {execute,calls,ports,readPersonal:async()=>({value:JSON.stringify({data:{envelope:{genres:{'survival-coop':{data}}}}})})};
}

test('saturation drives persisted cycles then observes exact rejection without mutation',async()=>{
  const harness=persistedInputHarness();
  const result=await saturateWorkshop({actor:{userId:'a'},owned:{},ports:harness.ports,readPersonal:harness.readPersonal,limit:2},harness.execute);
  expect(result.ok).toBe(true);
  expect(result.cycles).toHaveLength(2);
  expect(harness.calls).toEqual(['survival-coop:craft-reserve','survival-coop:craft-cancel','survival-coop:craft-reserve','survival-coop:craft-cancel','survival-coop:craft-reserve']);
  expect(result.refusal.result.reason).toBe('JOB_QUEUE_FULL');
  expect(result.afterRefusal).toEqual(result.atLimit);
});

test('corrupted prior job preserves executed prefix and halts before cap probe',async()=>{
  const harness=persistedInputHarness(true);
  const result=await saturateWorkshop({actor:{userId:'a'},owned:{},ports:harness.ports,readPersonal:harness.readPersonal,limit:2},harness.execute);
  expect(result.ok).toBe(false);
  expect(result.error).toBe('PRIOR_RETAINED_JOB_CHANGED');
  expect(result.actions).toHaveLength(4);
  expect(result.cycles).toHaveLength(1);
  expect(harness.calls).toHaveLength(4);
});
test('persisted personal workshop is bound to actor',()=>{
  const row={value:JSON.stringify({data:{envelope:{genres:{'survival-coop':{data:state()}}}}})};
  expect(personalState(row,'a').workshop.actorId).toBe('a');
  expect(()=>personalState(row,'b')).toThrow('PERSISTED_PERSONAL_WORKSHOP_REQUIRED');
});

// Raw UNIT fixtures exercise evidence rejection only, never runtime approval.
test('NPC validator requires actual boundary operations, unchanged readbacks and cleanup',()=>{
  const before=[{key:'personal',value:JSON.stringify({data:{quantity:3}})}];
  const operations=[
    {kind:'registration',id:'qa-cap-2',attemptedCount:2,accepted:true,census:{count:2}},
    {kind:'registration',id:'qa-cap-3',attemptedCount:3,accepted:false,reason:'NPC_BUDGET_OR_ID',census:{count:2}},
  ];
  const row={kind:'npcs',limit:2,before,after:structuredClone(before),blockers:[],probe:{
    limit:2,before:{count:1,ids:['original']},after:{count:1,ids:['original']},
    operations,boundary:operations[0],refusal:operations[1],attempts:2,retryLimit:0,cleanup:{remaining:[]},
  }};
  expect(validateSaturationRow(row)).toEqual([]);
  const changed=structuredClone(row);changed.after[0].value=JSON.stringify({data:{quantity:4}});
  expect(validateSaturationRow(changed)).toContain('REFUSAL_CHANGED_APPLICATION_STATE');
  const leaked=structuredClone(row);leaked.probe.cleanup.remaining.push('qa-cap-2');
  expect(validateSaturationRow(leaked)).toContain('NPC_CLEANUP_INCOMPLETE');
  const forged=structuredClone(row);forged.probe.refusal.accepted=true;
  expect(validateSaturationRow(forged)).toContain('NPC_REFUSAL_UNPROVEN');
  const missing=structuredClone(row);missing.probe.operations=[];
  expect(validateSaturationRow(missing)).toContain('NPC_BOUNDARY_UNPROVEN');
});

test('fully populated eight NPC boundary is an existing census, not a registration',()=>{
  const census={count:8,ids:Array.from({length:8},(_,i)=>`original-${i}`)};
  const persisted=[{key:'wildlife',value:JSON.stringify({data:{npcs:census.ids}})}];
  const refusal={kind:'registration',id:'qa-cap-9',attemptedCount:9,accepted:false,reason:'NPC_BUDGET_OR_ID',census:structuredClone(census)};
  const row={kind:'npcs',limit:8,before:persisted,after:structuredClone(persisted),blockers:[],probe:{
    limit:8,before:census,after:structuredClone(census),boundary:{kind:'existing-census',census:structuredClone(census)},
    operations:[refusal],refusal,attempts:1,retryLimit:0,cleanup:{remaining:[]},
  }};
  expect(validateSaturationRow(row)).toEqual([]);
  const invented=structuredClone(row);invented.probe.boundary.accepted=true;
  expect(validateSaturationRow(invented)).toContain('NPC_BOUNDARY_UNPROVEN');
  const removed=structuredClone(row);removed.probe.after.ids.pop();removed.probe.after.count--;
  expect(validateSaturationRow(removed)).toContain('NPC_CLEANUP_INCOMPLETE');
  const incomplete=structuredClone(row);incomplete.probe.boundary.census.ids.pop();
  expect(validateSaturationRow(incomplete)).toContain('NPC_BOUNDARY_UNPROVEN');
});

test('unsupported public operations cannot pass using success flags',()=>{
  for(const kind of ['payloadBytes','receipts','admission']) {
    expect(validateSaturationRow({kind,limit:4096,ok:true,noLoss:true,blockers:[]})).toContain('SATURATION_CAPABILITY_UNAVAILABLE');
  }
});
