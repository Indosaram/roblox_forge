import { test, expect } from 'bun:test';
import { readFileSync } from 'node:fs';
import { StudioSession, observedTransferCommand, validateOwnedArtifact } from './studio-driver-session.mjs';
import { createHash } from 'node:crypto';
import { StudioLifecycle } from './studio-driver-lifecycle.mjs';

// The readiness runtime the emitted read embeds, and the module the Lune fixture drives.
const runtimeSource = readFileSync(new URL('../../release/persistence-readiness.luau', import.meta.url), 'utf8');

test('owned artifact binds marker and exact artifact bytes before spawn',()=>{
  const bytes=Buffer.from('actual artifact fixture');
  const config={ownershipToken:'owned-test-marker-123',buildIdentity:{id:'identity'}};
  const sidecar={schemaVersion:1,ownedQaToken:config.ownershipToken,identity:config.buildIdentity,build:'sha256:'+createHash('sha256').update(bytes).digest('hex')};
  expect(()=>validateOwnedArtifact(config,sidecar,bytes)).not.toThrow();
  expect(()=>validateOwnedArtifact(config,{...sidecar,ownedQaToken:undefined},bytes)).toThrow('OWNED_ARTIFACT_MARKER_MISMATCH');
  expect(()=>validateOwnedArtifact(config,{...sidecar,ownedQaToken:'foreign-marker-123'},bytes)).toThrow('OWNED_ARTIFACT_MARKER_MISMATCH');
  expect(()=>validateOwnedArtifact(config,sidecar,Buffer.from('changed'))).toThrow('OWNED_ARTIFACT_HASH_MISMATCH');
});

test('newly connected unrelated instance is never marked or adopted',async()=>{
  const {adapter,state,transport}=(()=>{const f=fixture();return {...f,transport:f.adapter.transport};})();
  await adapter.prepare();state.ids.push('foreign-new');
  const scripts=[];
  const inventory=transport.call;
  transport.call=async(name,args)=>{
    if(name==='list_roblox_studios')return inventory(name,args);
    if(name==='get_studio_state')return {content:[{type:'text',text:'Current Studio Mode: Edit'}]};
    scripts.push(args.code);
    return {content:[{type:'text',text:JSON.stringify({token:'foreign',placeId:0})}]};
  };
  expect(await adapter.identify('owned-test-marker-123')).toEqual({edit:[],server:[],clients:[]});
  expect(scripts.length).toBe(1);
  expect(scripts[0].includes('SetAttribute')).toBe(false);
});

test('a no-place Home studio is skipped while an unexpected state failure still refuses',async()=>{
  const {adapter,state,transport}=(()=>{const f=fixture();return {...f,transport:f.adapter.transport};})();
  await adapter.prepare();
  expect(adapter.baseline).toEqual(['unrelated-editor']);
  state.ids.push('user-home','owned-editor');
  expect(adapter.baseline.includes('user-home')).toBe(false);
  const scripts=[];
  const attempts={};
  const inventory=transport.call;
  transport.call=async(name,args)=>{
    if(name==='list_roblox_studios')return inventory(name,args);
    if(name==='get_studio_state'){
      attempts[args.studio_id]=(attempts[args.studio_id]||0)+1;
      if(args.studio_id==='user-home')throw new Error('get_studio_state: {"content":[{"type":"text","text":"Place is not open"}],"isError":true}');
      return {content:[{type:'text',text:'Current Studio Mode: Edit'}]};
    }
    scripts.push(args.code);
    return {content:[{type:'text',text:JSON.stringify({token:'owned-test-marker-123',placeId:0})}]};
  };
  const found=await adapter.identify('owned-test-marker-123');
  expect(found.edit.map(row=>row.studioId)).toEqual(['owned-editor']);
  expect(scripts.length).toBe(1);
  // The terminal no-place response is classified before the transient retry, so the Home
  // studio is read exactly once and never consumes the 30s retry loop.
  expect(attempts).toEqual({'user-home':1,'owned-editor':1});
  // Skipping a foreign Home studio must not leave a lifecycle failure, which would mark the
  // whole run unresolved through receipt().ok even though nothing owned failed.
  expect(adapter.lifecycle.receipt().failure).toBe(null);
  // Any other state failure is not the no-place response: it propagates with its studio id.
  const strict=(()=>{const f=fixture();return {...f,transport:f.adapter.transport};})();
  await strict.adapter.prepare();
  strict.state.ids.push('owned-editor');
  const strictInventory=strict.transport.call;
  let strictAttempts=0;
  strict.transport.call=async(name,args)=>{
    if(name==='list_roblox_studios')return strictInventory(name,args);
    strictAttempts+=1;
    throw new Error('get_studio_state: {"code":-32603,"message":"Request timeout"}');
  };
  await expect(strict.adapter.identify('owned-test-marker-123')).rejects.toThrow('identify-state owned-editor');
  // An unexpected failure is not transient either: one attempt, no retry.
  expect(strictAttempts).toBe(1);
});

test('transfer crash retains exact observed envelope without rewriting epoch or arguments',()=>{
  const envelope={requestId:'observed-request',sessionEpoch:7,action:'survival-coop:transfer-deposit',args:['item-id',3]};
  const observed={actorId:'-1',requestId:envelope.requestId,action:envelope.action,envelope,serverTime:42};
  const retained=observedTransferCommand(observed,'-1','owned-namespace');
  expect(retained.envelope).toEqual(envelope);
  expect(retained.oldEpoch).toBe(7);
  envelope.args[1]=9;
  expect(retained.envelope.args[1]).toBe(3);
  expect(()=>observedTransferCommand({...observed,requestId:'different'},'-1','owned-namespace')).toThrow('TRANSFER_ENVELOPE_OBSERVATION_INVALID');
});

test('session request lets the transient bridge retry outlive the default lifecycle timeout', async () => {
  const observed = [];
  const lifecycle = {
    observe: async ({ phase, subscribe, action, timeoutMs }) => {
      observed.push({ phase, timeoutMs });
      let eventFired = false;
      subscribe(() => { eventFired = true; return () => {}; });
      const result = await action(new AbortController().signal);
      if (!eventFired) throw new Error('SUBSCRIPTION_EVENT_REQUIRED');
      return { value: result };
    },
  };
  let attempts = 0;
  const transport = { call: async () => ({ content: [{ type: 'text', text: '{}' }] }) };
  // The fake scheduler removes the real 1s retry wait while preserving the retry itself.
  const adapter = new StudioSession(transport, lifecycle, { delay: async () => {} });
  const value = await adapter.request('identify-owner', async () => {
    attempts += 1;
    if (attempts === 1) throw new Error('Target is not reachable');
    return { ready: true };
  });
  expect(observed).toEqual([{ phase: 'identify-owner', timeoutMs: 35000 }]);
  expect(attempts).toBe(2);
  expect(value).toEqual({ ready: true });
});

test('a hub handover that briefly reports no connected Studio is retried, not fatal', async () => {
  const lifecycle = { observe: async ({ subscribe, action }) => { subscribe(() => {}); return { value: await action(new AbortController().signal) }; } };
  const adapter = new StudioSession({ call: async () => ({}) }, lifecycle, { delay: async () => {} });
  let attempts = 0;
  const value = await adapter.request('identify-owner', async () => {
    attempts += 1;
    if (attempts === 1) throw new Error('execute_luau: {"text":"No Roblox Studio instances are connected. Ask the user to confirm"}');
    return { ready: true };
  });
  expect(attempts).toBe(2);
  expect(value).toEqual({ ready: true });
});

test('the startup lease read waits for the persistence bootstrap instead of racing it',async()=>{
  const {adapter}=fixture();
  adapter.active={serverId:'owned-server',clients:[]};
  adapter.controller={close:async()=>({released:true})};
  const codes=[];
  adapter.transport.call=async(name,args)=>{
    if(name!=='execute_luau')throw new Error('unexpected call '+name);
    codes.push(args.code);
    return {content:[{type:'text',text:JSON.stringify({phase:'LEASE_ACQUIRED',record:{key:'expected'},identity:{namespace:'owned'}})}]};
  };
  const value=await adapter.crashStartupLease({key:'expected',namespace:'owned'});
  expect(value.barrier.phase).toBe('LEASE_ACQUIRED');
  const code=codes[0];
  // The RuntimeBackend publishes the object and its marker asynchronously after the server
  // registers, so the read is preceded by the bounded readiness wait for that exact object, and the
  // wait that runs is the module the Lune fixture drives.
  expect(code).toContain(runtimeSource);
  expect(code).toContain("ForgeQAReadiness.await({service=game:GetService('ServerStorage')");
  expect(code).toContain("{object='ForgePersistence',child='StartupLeaseReached',childClass='StringValue',childCondition='nonempty',budgetMs=25000}");
  expect(code.indexOf('ForgeQAReadiness.await(')).toBeLessThan(code.indexOf("local p=game:GetService('ServerStorage').ForgePersistence"));
});

test('a persistence readiness failure fails the phase with its own code',async()=>{
  const {adapter}=fixture();
  adapter.active={serverId:'owned-server',clients:[]};
  adapter.controller={close:async()=>({released:true})};
  adapter.transport.call=async()=>{
    throw new Error('execute_luau: {"content":[{"type":"text","text":"READINESS_CHILD_TIMEOUT:ForgePersistence.StartupLeaseReached"}],"isError":true}');
  };
  await expect(adapter.crashStartupLease({key:'expected',namespace:'owned'})).rejects.toThrow('READINESS_CHILD_TIMEOUT:ForgePersistence.StartupLeaseReached');
  expect(adapter.lifecycle.receipt().failure).toEqual({phase:'startup-lease-held',code:'OPERATION_FAILED'});
});

function fixture() {
  const calls = [];
  const state = { ids: ['unrelated-editor'], lost: false };
  const transport = {
    async request(method) {
      calls.push(method);
      return { tools: [
        { name: 'list_roblox_studios', inputSchema: { properties: {} } },
        { name: 'get_studio_state', inputSchema: { properties: { studio_id: { type: 'string' } } } },
        { name: 'execute_luau', inputSchema: { properties: { code: { type: 'string' }, studio_id: { type: 'string' }, datamodel_type: { enum: ['Edit', 'Server', 'Client'] } } } },
      ] };
    },
    async call(name) {
      calls.push(name);
      if (state.lost) throw new Error('disconnected');
      if (name !== 'list_roblox_studios') throw new Error('unexpected mutation');
      return { content: [{ type: 'text', text: JSON.stringify({ studios: state.ids.map(id => ({ id })) }) }] };
    },
  };
  return { calls, state, adapter: new StudioSession(transport, new StudioLifecycle()) };
}

test('lease renewal requires an actual owned actor before arming',async()=>{
  const {adapter,calls}=fixture();
  await expect(adapter.crashLeaseRenewal({key:'tribe',actorId:'-1',buildIdentity:'build',namespace:'owned'})).rejects.toThrow('OWNED_LEASE_ACTOR_REQUIRED');
  expect(calls).toEqual([]);
});

test('startup lease cannot kill a job from mismatched persisted key',async()=>{
  const {adapter}=fixture();let killed=false;
  adapter.active={serverId:'owned-server',clients:[]};
  adapter.controller={close:async()=>{killed=true;return {released:true};}};
  adapter.transport.call=async()=>({content:[{type:'text',text:JSON.stringify({phase:'LEASE_ACQUIRED',record:{key:'wrong'},identity:{namespace:'owned'}})}]});
  await expect(adapter.crashStartupLease({key:'expected',namespace:'owned'})).rejects.toThrow('STARTUP_LEASE_BINDING_MISMATCH');
  expect(killed).toBe(false);
});

test('product launch blocks before allocation and preserves existing editor', async () => {
  const { calls, state, adapter } = fixture();
  const outcome = await adapter.launch();
  expect(outcome.ok).toBe(false);
  expect(outcome.attempted).toBe(false);
  expect(adapter.lifecycle.receipt().resources).toEqual([]);
  expect(outcome.blockers).toEqual(['OWNED_LAUNCH_CONFIG_REQUIRED']);
  expect(outcome.baseline).toEqual(['unrelated-editor']);
  expect(state.ids).toEqual(['unrelated-editor']);
  expect(calls).toEqual(['tools/list', 'list_roblox_studios']);
});

test('late connected instances remain unclaimed rather than owned or stopped', async () => {
  const { calls, state, adapter } = fixture();
  await adapter.prepare();
  state.ids.push('late-client');
  const result = await adapter.reconcile();
  expect(result.settled).toBe(false);
  expect(result.unclaimed).toEqual(['late-client']);
  expect(calls.every(call => ['tools/list', 'list_roblox_studios'].includes(call))).toBe(true);
});

test('transport loss cannot turn pending allocation into settled absence', async () => {
  const { state, adapter } = fixture();
  await adapter.prepare();
  state.lost = true;
  expect(await adapter.reconcile()).toEqual({ settled: false, blocker: 'RECONCILIATION_TRANSPORT_UNAVAILABLE' });
});
