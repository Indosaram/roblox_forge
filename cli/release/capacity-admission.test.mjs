import { test, expect } from 'bun:test';
import { backendProof, cleanupProof, measurementProof, recoveryProof, stageRunBinding } from './capacity-admission.mjs';

// UNIT ONLY: these rows exercise arithmetic/contracts, not live capacity.
const backend = () => ({backend:'local-sqlite-cas',namespace:'unit',epoch:'unit-epoch',startedAtMs:1,endedAtMs:10,
  configuredCaps:{maxConcurrentRequests:64},availableSlots:64,peakInFlight:1,inFlight:0,coverageComplete:true,
  overflow:false,requestCount:0,outcomes:[],handledThrottleCount:0,throttleCount:0,failures:0});
test('complete local request delta yields only local concurrency budget',()=>{
  const before=backend(),after=backend();
  after.outcomes=[{operation:1,startedAtMs:3,endedAtMs:4,admitted:true,status:200,outcome:'read'}];
  after.requestCount=1;
  expect(backendProof(before,after,'unit')).toEqual({kind:'local-concurrent-http-slots',maximum:64,peakInFlight:1,availableSlots:64,operations:1});
});
test('missing host coverage and real unhandled 429 cannot be zero-throttle approval',()=>{
  for(const mutate of [value=>{value.coverageComplete=false;},value=>{value.overflow=true;},value=>{value.inFlight=1;},
    value=>{value.epoch='other';},value=>{value.outcomes[0].status=429;value.outcomes[0].outcome='admission-throttle';},
    value=>{value.handledThrottleCount=null;},value=>{value.requestCount=2;}]) {
    const before=backend(),after=backend();
    after.outcomes=[{operation:1,startedAtMs:3,endedAtMs:4,admitted:true,status:200,outcome:'read'}];after.requestCount=1;
    mutate(after);expect(()=>backendProof(before,after,'unit')).toThrow();
  }
});
test('cleanup booleans cannot hide actual resource residuals',()=>{
  expect(()=>cleanupProof({ok:true,failure:null,resources:[{cleanup:'pending'}],residuals:[]})).toThrow('CLEANUP_UNPROVEN');
  expect(()=>cleanupProof({ok:true,failure:null,resources:[],residuals:['owned-editor']})).toThrow('CLEANUP_UNPROVEN');
});
test('a released ledger after a run failure is cleanup-proven while unknown release evidence still refuses',()=>{
  const released={cleanup:'released',state:'released',evidence:{pid:1}};
  // The admission failure is the run's own blocker; it must not rename a fully
  // released ledger into CLEANUP_UNPROVEN. Independent gates still refuse a failed run:
  // measurementProof requires admission.ok and recoveryProof the crash/lease gates, and
  // admitMatrix records the per-stage error, so no false PASS follows from this.
  expect(()=>cleanupProof({ok:false,failure:{phase:'session-admission',code:'EDITOR_NOT_REGISTERED_AT_PROCESS_ADMISSION'},
    resources:[released],residuals:[]})).not.toThrow();
  // Unknown or missing release evidence stays fail-closed, including the shape loss
  // that would present an empty array as {}.
  for(const value of [null,undefined,{}, {resources:[released]}, {resources:[released],residuals:{}},
    {resources:[{cleanup:'pending',state:'released',evidence:{}}],residuals:[]},
    {resources:[{cleanup:'released',state:'released'}],residuals:[]},
    {resources:[released],residuals:['owned-editor']}])
    expect(()=>cleanupProof(value)).toThrow('CLEANUP_UNPROVEN');
});
test('all-green candidate flags cannot replace loaded actors or owned exit proof',()=>{
  const fake={ok:true,admittedPlayers:8,currentBuild:{id:'unit'},admission:{ok:true},
    lifecycle:{ok:true,resources:[],residuals:[]},workloadConservation:{ok:true},recovery:{terminalReadback:{proven:true}}};
  expect(()=>measurementProof(fake,'unit','unit')).toThrow('OWNED_JOB_EXIT_UNPROVEN');
  for(const phase of ['ESCROWED','CREDITED','FINALIZED','LEASE_ACQUIRED','LEASE_RENEWED'])
    expect(()=>recoveryProof(fake,phase,'unit','unit')).toThrow('OWNED_JOB_EXIT_UNPROVEN');
});

function measurementFixture() {
  const build='unit', namespace='unit';
  const process={pid:123,creationTime:'unit-created'};
  const lifecycle={ok:true,resources:[{id:'owned-editor',acquired:true,state:'released',cleanup:'released',
    identity:{...process,treeOwnership:'windows-job-no-breakaway'},evidence:{pid:123,treeExited:true,eventProof:'JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO'}}],residuals:[]};
  const clients=Array.from({length:8},(_,i)=>({role:'client',actorId:String(i),buildIdentity:build,serverBuildIdentity:build,sessionId:'unit-session'}));
  const server={role:'server',buildIdentity:build,sessionId:'unit-session'};
  const nodes={data:{nodes:{version:0,nodes:{node:{catalogId:'tree',charges:3,qualityMilli:1000}}},grants:{}}};
  const next=structuredClone(nodes),grant='g1:0:1:1:g';
  next.data.nodes.version=1;next.data.nodes.nodes.node.charges=2;
  next.data.grants[grant]={mints:[{request:{id:`${grant}:output:1`,actor:'0',epoch:'1',source:'nodes',quantity:1},item:{catalogId:'wood',quantity:1,qualityMilli:1000}}]};
  const personal={data:{inventory:{version:1,items:{}}}}, earned={data:{inventory:{version:1,items:{wood:{catalogId:'wood',quantity:1}}}}};
  const rows=(n,p)=>[{key:'nodes',value:JSON.stringify(n)},{key:'personal',value:JSON.stringify(p)}];
  const before=rows(nodes,personal),after=rows(next,earned);
  const commits=after.map((row,i)=>({key:row.key,operation:i+1,sequence:i+1,previousSerialized:before[i].value,serialized:row.value,latencyMs:1}));
  const b=backend(),a=backend();
  a.outcomes=Array.from({length:4},(_,i)=>({operation:i+1,startedAtMs:3,endedAtMs:4,admitted:true,status:200,
    route:i%2?'/cas':'/read',outcome:i%2?'committed':'read',key:i<2?'nodes':'personal',
    ...(i%2?{inputRevision:1,acknowledgedRevision:2}:{acknowledgedRevision:1})}));a.requestCount=4;
  const outcomes=[1,2].map(operation=>({operation,key:operation===1?'nodes':'personal',acknowledged:true,classificationComplete:true,
    throttleCount:0,handledThrottleCount:0,attempts:1,retryLimit:15,requestCount:2,
    requests:a.outcomes.slice((operation-1)*2,operation*2).map(row=>({route:row.route,key:row.key,hostOperation:row.operation,backendEpoch:a.epoch,correlationComplete:true,
      inputRevision:row.inputRevision,acknowledgedRevision:row.acknowledgedRevision,acknowledged:true,outcome:'acknowledged'}))}));
  const trace={identity:{namespace,epoch:'runtime-unit'},overflow:false,coverageComplete:true,inFlight:0,backendObservation:b,records:[],outcomes:[],attempts:0,sequence:0};
  const action=(actor,kind,id,extra={})=>({actorId:actor,action:`survival-coop:${kind}`,before:110,after:111,
    result:{requestId:id,sessionEpoch:1,result:{ok:true}},...extra});
  const actions=clients.map(row=>action(row.actorId,'transfer-deposit',`t${row.actorId}`));
  actions.push(action('0','gather','g',{result:{requestId:'g',sessionEpoch:1,nodeId:'node',result:{ok:true}}}),
    action('0','craft-complete','c',{recipeId:'unit-recipe'}),action('0','settlement-place','s',{structureId:'unit-structure'}));
  const census={npcs:[{id:'npc'}],configuredIds:['npc'],observedCount:1,configuredCount:1,configuredMaximum:8};
  return {lifecycle,currentBuild:{id:build},admittedPlayers:8,admission:{ok:true,process,serverId:'server',clients:clients.map(row=>({studioId:`client${row.actorId}`,userId:row.actorId}))},
    loaded:{server,clients},hardware:{scope:'owned-local-job-host',provider:'Windows-CIM',cpu:[{}],os:{Version:'unit'}},
    samples:[server,...clients].map(loaded=>({loaded,startedAtSeconds:100,endedAtSeconds:400,robloxVersion:'unit',
      frameMs:Array(10000).fill(30),engineDtMs:Array(10000).fill(30),memoryMb:Array(10000).fill(100),sampleTimes:Array.from({length:10000},(_,i)=>100+i*.03)})),
    censusBefore:census,censusAfter:census,backendBefore:b,backendAfter:a,persistenceBefore:trace,
    persistenceAfter:{...trace,backendObservation:a,records:commits,outcomes,attempts:2,sequence:2},commits,loadedLimits:{payloadBytes:4000000},
    workload:{ok:true,actions},accountingContent:{worldNodes:[{id:'node',catalogId:'tree'}],nodes:[{id:'tree',harvest:[{item:'wood',quantity:1}]}],
      recipes:[{id:'unit-recipe',inputs:[],outputs:[]}],structures:[{id:'unit-structure',cost:[]}]},
    workloadBeforeReadback:before,persistentReadback:after,replayReadback:after};
}
test('UNIT complete independently reconciled measurement can admit its narrow envelope',()=>{
  const result=measurementProof(measurementFixture(),'unit','unit');
  expect(result.measured).toBe(true);expect(result.players).toBe(8);expect(result.crossServer).toBe(false);
  expect(result.clients).toHaveLength(8);
});
test('UNIT server metrics are retained and slow server blocks admission',()=>{
  const row=measurementFixture();
  row.samples[0].updateAsyncBudget=[100,99];
  const result=measurementProof(row,'unit','unit');
  expect(result.server.frames).toEqual({count:10000,p50:30,p95:30,maximum:30});
  expect(result.server.memory).toEqual({count:10000,p50:100,p95:100,maximum:100});
  expect(result.auxiliaryEngineObservations.updateAsyncBudget.applicableToMeasuredBackend).toBe(false);
  expect(result.auxiliaryEngineObservations.updateAsyncBudget.samples).toEqual([100,99]);
  row.samples[0].frameMs.fill(34);
  expect(()=>measurementProof(row,'unit','unit')).toThrow('SERVER_FRAME_P95_FAILED');
});
test('UNIT slow client wrong request correlation and quantity drift refuse envelope',()=>{
  for(const mutate of [r=>{r.samples[1].frameMs.fill(34);},r=>{r.samples.pop();},
    r=>{r.persistenceAfter.outcomes[0].requests[0].hostOperation=99;},
    r=>{r.persistentReadback=structuredClone(r.persistentReadback);const v=JSON.parse(r.persistentReadback[1].value);v.data.inventory.items.wood.quantity=2;r.persistentReadback[1].value=JSON.stringify(v);},
    r=>{r.loadedLimits.payloadBytes=1;}]) {
    const row=measurementFixture();mutate(row);expect(()=>measurementProof(row,'unit','unit')).toThrow();
  }
});

function transferFixture(phase) {
  const measured=measurementFixture(), original={requestId:'transfer',sessionEpoch:1,action:'survival-coop:transfer-deposit',args:[]};
  const request={id:'transfer',actor:'0',source:'source',destination:'destination',epoch:'1',quantity:1,itemId:'wood',outputId:'wood',expiresAt:99};
  const item={catalogId:'wood',quantity:1};
  const wrapper=(items,receipts)=>({data:{inventory:{version:1,items},itemTransfers:{receipts}}});
  const rows=(source,destination)=>[{key:'source',value:JSON.stringify(source)},{key:'destination',value:JSON.stringify(destination)}];
  const before=rows(wrapper({wood:item},{}),wrapper({},{}));
  const source=wrapper({}, {transfer:{phase:phase==='FINALIZED'?'FINALIZED':'ESCROWED',request,item,stateVersion:2}});
  const destination=wrapper(phase==='ESCROWED'?{}:{wood:item},phase==='ESCROWED'?{}:{transfer:{phase:'CREDITED',request}});
  const crashed=rows(source,destination);
  const after=rows(wrapper({}, {transfer:{phase:'FINALIZED',request,item,stateVersion:2}}),wrapper({wood:item},{transfer:{phase:'CREDITED',request}}));
  const process={pid:456,creationTime:'fresh-created'}, cleanup=structuredClone(measured.lifecycle);
  cleanup.resources[0].identity={...cleanup.resources[0].identity,...process};cleanup.resources[0].evidence.pid=456;
  return {...measured,recovery:{before,crashedReadback:crashed,after,replayReadback:after,cleanup,
    restart:{process,clients:measured.admission.clients},loaded:{buildIdentity:'unit',sessionId:'fresh'},
    loadedClients:measured.loaded.clients.map(row=>({...row,sessionId:'fresh'})),loadTrace:{identity:{namespace:'unit',epoch:'fresh-epoch'},overflow:false},
    commandReplay:{request:original,result:{ok:false,reason:'stale epoch'}},
    crash:{released:true,process:measured.admission.process,runtime:measured.loaded.server,
      originalCommand:{namespace:'unit',actorId:'0',oldEpoch:1,envelope:original},
      barrier:{held:true,ackState:'held',phase,requestId:'transfer',identity:{namespace:'unit',epoch:'old-epoch'},
        record:{key:phase==='CREDITED'?'destination':'source',serialized:phase==='CREDITED'?crashed[1].value:crashed[0].value}}}}};
}
test('UNIT terminal recovery is independent of stale ingress replay refusal',()=>{
  for(const phase of ['ESCROWED','CREDITED','FINALIZED']) {
    expect(recoveryProof(transferFixture(phase),phase,'unit','unit').requestId).toBe('transfer');
  }
});
test('UNIT missing terminal credit changed original epoch and changed durable barrier reject',()=>{
  for(const mutate of [r=>{r.recovery.commandReplay.request={...r.recovery.commandReplay.request,sessionEpoch:2};},
    r=>{r.recovery.crashedReadback=[];},r=>{r.recovery.loaded.sessionId='unit-session';},
    r=>{const value=JSON.parse(r.recovery.after[1].value);delete value.data.itemTransfers.receipts.transfer;r.recovery.after[1].value=JSON.stringify(value);}
  ]) {const row=transferFixture('ESCROWED');mutate(row);expect(()=>recoveryProof(row,'ESCROWED','unit','unit')).toThrow();}
});


test('UNIT a run that never bound a build keeps its recorded failure over STAGE_BUILD_CHANGED',()=>{
  const build={id:'sha256:unit'};
  expect(()=>stageRunBinding({runs:[{currentBuild:build}]},build)).not.toThrow();
  // A run that failed before collection records its own blocker and no currentBuild (observed:
  // the LEASE_ACQUIRED restart read of a ServerStorage member that did not exist yet). That
  // failure keeps its precedence instead of being renamed to a build change.
  expect(()=>stageRunBinding({runs:[{currentBuild:build},{blockers:['COLLECTION_FAILED'],error:'x'}]},build))
    .toThrow('COLLECTION_FAILED');
  // A run that did bind a different build is still a genuine stage build change.
  expect(()=>stageRunBinding({runs:[{currentBuild:{id:'sha256:other'}}]},build)).toThrow('STAGE_BUILD_CHANGED');
  expect(()=>stageRunBinding({runs:[{currentBuild:build},{currentBuild:{id:'sha256:other'}}]},build)).toThrow('STAGE_BUILD_CHANGED');
  // A shape loss with no recorded blocker still refuses rather than approving the stage.
  expect(()=>stageRunBinding({runs:[{}]},build)).toThrow('COLLECTION_FAILED');
});

test('UNIT engine dt provenance is retained while invalid deltas still refuse',()=>{
  // The fixture clock advances 30ms per sample and frameMs is 30, so the authored
  // measured period matches its provenance; engineDtMs is provenance, not duration.
  const zeroed=measurementFixture();
  zeroed.samples[0].engineDtMs=Array(10000).fill(0);
  expect(measurementProof(zeroed,'unit','unit').server.frames.count).toBe(10000);
  const nonFinite=measurementFixture();
  nonFinite.samples[0].engineDtMs[0]=Number.NaN;
  expect(()=>measurementProof(nonFinite,'unit','unit')).toThrow('ENGINE_DELTA_INVALID');
  const negative=measurementFixture();
  negative.samples[0].engineDtMs[1]=-1;
  expect(()=>measurementProof(negative,'unit','unit')).toThrow('ENGINE_DELTA_INVALID');
  const missing=measurementFixture();
  delete missing.samples[0].engineDtMs;
  expect(()=>measurementProof(missing,'unit','unit')).toThrow('SAMPLE_COVERAGE_INVALID');
  const short=measurementFixture();
  short.samples[0].engineDtMs=short.samples[0].engineDtMs.slice(0,5);
  expect(()=>measurementProof(short,'unit','unit')).toThrow('SAMPLE_COVERAGE_INVALID');
});

test('UNIT a nonpositive measured clock delta is still refused',()=>{
  const stalled=measurementFixture();
  stalled.samples[0].frameMs[5000]=0;
  expect(()=>measurementProof(stalled,'unit','unit')).toThrow('INVALID_SAMPLES');
  const negative=measurementFixture();
  negative.samples[3].frameMs[0]=-1;
  expect(()=>measurementProof(negative,'unit','unit')).toThrow('INVALID_SAMPLES');
});
