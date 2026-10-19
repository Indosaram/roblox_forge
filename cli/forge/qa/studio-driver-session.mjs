import { createHash } from 'node:crypto';
import { launchOwnedEditor } from './studio-driver-process.mjs';
import { startHost } from '../../release/local-persistence-host.mjs';
import { objectReadiness } from '../../release/persistence-readiness.mjs';
import { mkdir, readFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';

export async function openOwnedPersistence(config, lifecycle) {
  if (!config || typeof config.directory!=='string') throw new Error('OWNED_PERSISTENCE_CONFIG_REQUIRED');
  const directory=resolve(config.directory);
  let host,created=false;
  const row=lifecycle.attempt('local-persistence','local-persistence-host',async()=>{
    host?.stop();
    // Retain original DB and WAL for failure/recovery evidence. Never delete
    // a user path or an acknowledged persistent snapshot during cleanup.
    return {released:true,evidence:{stopped:true,directory,retained:created}};
  });
  await mkdir(directory); // exclusive creation; existing user paths are refused
  created=true;
  host=startHost({path:join(directory,'profiles.sqlite'),namespace:config.namespace,port:config.port,token:config.token});
  if(host.ready?.listening!==true || host.ready.hostname!=='127.0.0.1' || host.ready.namespace!==config.namespace || host.ready.port!==config.port)throw new Error('LOCAL_HOST_LISTENING_UNPROVEN');
  lifecycle.acquire(row,host.ready);
  return {...host.ready,instanceId:digest({directory,namespace:config.namespace}),ownership:row.identity};
}

const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
export function validateOwnedArtifact(config, sidecar, bytes) {
  if(typeof config.ownershipToken!=='string' || !/^[A-Za-z0-9-]{16,128}$/.test(config.ownershipToken) || sidecar?.schemaVersion!==1 || sidecar.ownedQaToken!==config.ownershipToken)throw new Error('OWNED_ARTIFACT_MARKER_MISMATCH');
  if(sidecar.build!=='sha256:'+createHash('sha256').update(bytes).digest('hex'))throw new Error('OWNED_ARTIFACT_HASH_MISMATCH');
  if(!config.buildIdentity?.id || sidecar.identity?.id!==config.buildIdentity.id)throw new Error('OWNED_ARTIFACT_BUILD_IDENTITY_MISMATCH');
}
export function observedTransferCommand(observed, actorId, namespace) {
  const envelope=observed?.envelope;
  if(observed?.actorId!==actorId || !envelope || envelope.requestId!==observed.requestId || envelope.action!==observed.action || !['survival-coop:transfer-deposit','survival-coop:transfer-withdraw'].includes(envelope.action) || !Number.isSafeInteger(envelope.sessionEpoch) || envelope.sessionEpoch<0 || !Array.isArray(envelope.args) || Object.keys(envelope).some(key=>!['requestId','sessionEpoch','action','args'].includes(key)))throw new Error('TRANSFER_ENVELOPE_OBSERVATION_INVALID');
  return {envelope:structuredClone(envelope),actorId,namespace,oldEpoch:envelope.sessionEpoch,observedServerTime:observed.serverTime};
}
const decode = result => {
  if (result.isError) throw new Error('SESSION_DISCOVERY_FAILED');
  const text = (result.content || []).filter(part => part.type === 'text').map(part => part.text).join('\n');
  const marker = text.match(/FORGE_QA_JSON:([^\r\n]+)/);
  return JSON.parse(marker ? marker[1] : text);
};

// StdioMcp.call throws `${name}: ${JSON.stringify(result)}` only when the product returns an
// isError result. Only that exact no-place response means the studio has no open place (the
// user's Home window) and cannot be the owned editor being admitted; every other failure
// (disconnect, deadline, auth, unknown shape) must propagate, so the classifier parses the
// contract instead of matching a loose substring.
const NO_PLACE_RESPONSE = 'Place is not open';
const noPlaceResponse = error => {
  const message = String((error && error.message) || error);
  const match = /^get_studio_state: (\{[\s\S]*\})$/.exec(message);
  if (!match) return false;
  try {
    const body = JSON.parse(match[1]);
    return body?.isError === true && Array.isArray(body.content) && body.content.length > 0
      && body.content.every(part => part?.type === 'text')
      && body.content.map(part => part.text).join('\n') === NO_PLACE_RESPONSE;
  } catch { return false; }
};
// Returned by request() instead of throwing when the product reports the exact terminal
// no-place response, so a caller can skip a foreign Home studio without the lifecycle
// recording a failure that would mark an otherwise clean run unresolved.
const NO_PLACE = Symbol('forge.studio.noPlace');

// This adapter deliberately has no OS launch/kill fallback. The maintained
// product contract can inventory connected instances, but cannot correlate a
// lost editor allocation response or prove cancellation of a pending launch.
export class StudioSession {
  constructor(transport, lifecycle, options = {}) {
    this.transport = transport;
    this.lifecycle = lifecycle;
    this.discovery = null;
    this.baseline = null;
    // Pacing for the transient bridge retry below. Injectable so a test drives the retry
    // through a fake scheduler instead of a real timer; the product default is the measured
    // 1s interval.
    this.delay = typeof options.delay === 'function' ? options.delay : ms => new Promise(resolve => setTimeout(resolve, ms));
  }

  async request(phase, action) {
    let notify;
    // A datamodel that has just registered reports a transient reachability failure
    // until its Luau bridge finishes loading (observed on the installed build: the
    // first execute after registration fails with 'Target is not reachable'). Retry
    // only that failure against a bounded deadline so a slow bridge never fails a
    // run; every other error still propagates immediately. A no-place response is not a
    // bridge that is still loading, so it is classified separately below and never retried.
    // A hub handover (see studio-driver.mjs) briefly reports no connected instance.
    const transientBridge = error => /Target is not reachable|createExecuteLuauBridge|No Roblox Studio instances are connected|is not connected/i.test(String(error && error.message ? error.message : error));
    const deadline = Date.now() + 30000;
    return (await this.lifecycle.observe({
      phase,
      // The observe budget has to outlive the 30s transient-bridge retry
      // deadline above: with the lifecycle default (10s) a slow booting
      // window hit OPERATION_TIMEOUT before a single retry could land,
      // killing admission on a transient the retry exists to absorb.
      timeoutMs: 35000,
      subscribe: resolve => { notify = resolve; return () => { notify = () => {}; }; },
      action: async signal => {
        let result;
        for (;;) {
          try { result = await action(signal); break; }
          catch (error) {
            // A studio with no place open is terminal: return the sentinel instead of
            // throwing so the caller skips the id, and so the lifecycle records no failure
            // for a foreign Home studio (any recorded failure makes the run unresolved).
            // Only identify-state consumes the sentinel; every other phase and every other
            // non-transient error still propagates unchanged, so an owned operation can never
            // be masked by the exact no-place text.
            if (phase === 'identify-state' && noPlaceResponse(error)) { result = NO_PLACE; break; }
            if (!transientBridge(error) || Date.now() >= deadline) throw error;
            await this.delay(1000);
          }
        }
        notify('response');
        return result;
      },
    })).value;
  }

  async discover() {
    const schemas = await this.request('session-schema', () => this.transport.request('tools/list', {}));
    const required = { list_roblox_studios: [], execute_luau: ['code', 'datamodel_type', 'studio_id'], get_studio_state: ['studio_id'] };
    const blockers = [];
    const recorded = [];
    for (const [name, parameters] of Object.entries(required)) {
      const schema = schemas.tools?.find(tool => tool.name === name);
      if (!schema || parameters.some(key => !schema.inputSchema?.properties?.[key])) {
        blockers.push(`UNSUPPORTED_PRODUCT_SCHEMA:${name}`);
        continue;
      }
      if (name === 'execute_luau' && !['Edit', 'Server', 'Client'].every(model => schema.inputSchema.properties.datamodel_type.enum?.includes(model))) {
        blockers.push('UNSUPPORTED_PRODUCT_SCHEMA:execute_luau.datamodel_type');
      }
      recorded.push({ name, inputSchema: schema.inputSchema, sha256: digest(schema) });
    }
    this.discovery = { schemas: recorded, blockers };
    return this.discovery;
  }

  async inventory() {
    if (!this.discovery || this.discovery.blockers.length) throw new Error('SESSION_DISCOVERY_REQUIRED');
    const result = decode(await this.request('session-inventory', () => this.transport.call('list_roblox_studios', {})));
    if (!Array.isArray(result.studios) || result.studios.some(studio => typeof studio.id !== 'string' || !studio.id) || new Set(result.studios.map(studio => studio.id)).size !== result.studios.length) throw new Error('INVALID_STUDIO_INVENTORY');
    // Preserve IDs only: instance names may contain local paths or user data.
    return result.studios.map(studio => studio.id);
  }

  async prepare() {
    const discovery = await this.discover();
    if (!discovery.blockers.length) this.baseline = await this.inventory();
    return {
      ok: discovery.blockers.length === 0,
      schemas: discovery.schemas,
      baseline: this.baseline,
      blockers: discovery.blockers,
    };
  }

  async launch(config, players) {
    const readiness = await this.prepare();
    if (!readiness.ok) return { ...readiness, attempted: false };
    try {
      if (!config?.editor || !/^[a-zA-Z0-9-]+$/.test(config.ownershipToken || '') || !Number.isInteger(players) || players < 2) throw new Error('OWNED_LAUNCH_CONFIG_REQUIRED');
      const sidecar=JSON.parse(await readFile(config.buildPath+'.identity.json','utf8'));
      validateOwnedArtifact(config,sidecar,await readFile(config.buildPath));
      const launched = await launchOwnedEditor({ executable: config.editor.executable, artifact: config.buildPath, desktop: config.desktop }, this.lifecycle);
      this.controller = launched.controller;
      const { controller, ...processIdentity } = launched;
      this.processIdentity = processIdentity;
      // Request completion is an observation boundary, not an invented
      // registration notification. Missing registration is reported precisely.
      // Studio needs a real, bounded window to start and register its MCP server: a
      // single listing immediately after launch always lost that race (measured: the
      // editor starts, runs and exits while registration arrives tens of seconds
      // later). This observes the actual registration event against a deadline; it
      // never fabricates a notification, and a missing registration still fails with
      // the same precise code.
      const registrationDeadlineMs = Number.isInteger(config.registrationTimeoutMs) ? config.registrationTimeoutMs : 180000;
      const registrationStartedAt = Date.now();
      let found = await this.identify(config.ownershipToken);
      while (found.edit.length !== 1 && Date.now() - registrationStartedAt < registrationDeadlineMs && !this.lifecycle.closing) {
        await new Promise(resolve => setTimeout(resolve, 2000));
        found = await this.identify(config.ownershipToken);
      }
      if (found.edit.length !== 1) throw new Error('EDITOR_NOT_REGISTERED_AT_PROCESS_ADMISSION');
      if(config.persistence) {
        const p=config.persistence;
        if(p.leaseAcquireKey!==undefined && (typeof p.leaseAcquireKey!=='string'||!p.leaseAcquireKey||p.leaseAcquireKey.length>128))throw new Error('INVALID_STARTUP_LEASE_KEY');
        if(!/^[a-z0-9-]{1,32}$/.test(p.namespace) || !/^[a-f0-9]{64}$/.test(p.token) || !Number.isInteger(p.port) || p.port<1024 || p.port>65535)throw new Error('INVALID_RUNTIME_PERSISTENCE_CONFIG');
        const installed=await this.request('runtime-persistence-config',()=>this.transport.call('execute_luau',{
          studio_id:found.edit[0].studioId,datamodel_type:'Edit',
          code:`assert(game.PlaceId==0);assert(game:GetService('ReplicatedStorage'):GetAttribute('ForgeQAOwner')==${JSON.stringify(config.ownershipToken)});local storage=game:GetService('ServerStorage');assert(not storage:FindFirstChild('ForgeOwnedPersistenceConfig'),'runtime config already exists');local f=Instance.new('Folder');f.Name='ForgeOwnedPersistenceConfig';f:SetAttribute('Mode','studio-local');f:SetAttribute('Namespace',${JSON.stringify(p.namespace)});f:SetAttribute('Port',${p.port});f:SetAttribute('Token',${JSON.stringify(p.token)});f.Parent=storage;local http=game:GetService('HttpService');http.HttpEnabled=true;assert(http.HttpEnabled,'HTTP_ENABLE_FAILED');return 'RUNTIME_CONFIG_INSTALLED'`,
        }));
        this.installation={succeeded:!installed.isError,beforePlay:true,mode:'studio-local',namespace:p.namespace,invocation:'execute_luau/Edit:ForgeOwnedPersistenceConfig',sessionOwnership:`${this.processIdentity.pid}:${this.processIdentity.creationTime}`,hostOwnership:p.instanceId};
        if(p.leaseAcquireKey) await this.request('startup-lease-selector',()=>this.transport.call('execute_luau',{
          studio_id:found.edit[0].studioId,datamodel_type:'Edit',
          code:`game:GetService('ServerStorage').ForgeOwnedPersistenceConfig:SetAttribute('LeaseAcquireKey',${JSON.stringify(p.leaseAcquireKey)});return 'LEASE_SELECTOR_INSTALLED'`,
        }));
        if(p.waitLeaseExpiry!==undefined) {
          if(!Number.isSafeInteger(p.waitLeaseExpiry))throw new Error('INVALID_LEASE_EXPIRY');
          await this.request('lease-expiry-selector',()=>this.transport.call('execute_luau',{studio_id:found.edit[0].studioId,datamodel_type:'Edit',code:`game:GetService('ServerStorage').ForgeOwnedPersistenceConfig:SetAttribute('WaitLeaseExpiry',${p.waitLeaseExpiry});return 'EXPIRY_SELECTOR_INSTALLED'`}));
        }
      }
      const start = await this.request('start-owned-test', () => this.transport.call('execute_luau', {
        studio_id: found.edit[0].studioId, datamodel_type: 'Edit',
        code: `assert(game.PlaceId==0);assert(game:GetService('ReplicatedStorage'):GetAttribute('ForgeQAOwner')==${JSON.stringify(config.ownershipToken)});task.defer(function() game:GetService('StudioTestService'):ExecuteMultiplayerTestAsync(${players},{}) end);return game:GetService('HttpService'):JSONEncode({startRequested=true})`,
      }));
      if (decode(start).startRequested !== true) throw new Error('MULTIPLAYER_START_NOT_ACKNOWLEDGED');
      // The multiplayer test spins up a server and one client per player asynchronously, so
      // observing their registration once, immediately after the start request, loses the
      // same race the editor listing did. Observe the actual registration against a bounded
      // deadline; a missing actor still fails with the same precise code.
      const actorDeadlineMs = Number.isInteger(config.actorTimeoutMs) ? config.actorTimeoutMs : 180000;
      const actorStartedAt = Date.now();
      let actors = await this.identify(config.ownershipToken);
      while (
        (actors.server.length !== 1 || actors.clients.length !== players) &&
        Date.now() - actorStartedAt < actorDeadlineMs &&
        !this.lifecycle.closing
      ) {
        await new Promise(resolve => setTimeout(resolve, 2000));
        actors = await this.identify(config.ownershipToken);
      }
      if(config.persistence?.leaseAcquireKey && actors.server.length===1) {
        this.active={serverId:actors.server[0].studioId,clients:actors.clients,ownershipToken:config.ownershipToken};
        return {...readiness,ok:true,attempted:true,leaseBarrierAdmission:true,process:this.processIdentity,...this.active};
      }
      if (actors.server.length !== 1 || actors.clients.length !== players) throw new Error('MULTIPLAYER_ACTORS_NOT_REGISTERED_AT_START_RESPONSE');
      if (new Set(actors.clients.map(actor => actor.userId)).size !== players) throw new Error('DUPLICATE_CLIENT_IDENTITY');
      // A client viewport can register before its LocalPlayer exists (a test
      // window still booting, or a dead window left by an earlier run). Admit
      // only a stable set: exactly one window per player, each with a live
      // LocalPlayer identity, re-observed until it holds.
      const stableDeadline = Date.now() + (Number.isInteger(config.clientIdentityTimeoutMs) ? config.clientIdentityTimeoutMs : 60000);
      const stableIdentity = () =>
        actors.clients.length === players && actors.clients.every(actor => !!actor.userId);
      while (!stableIdentity() && Date.now() < stableDeadline && !this.lifecycle.closing) {
        await new Promise(resolve => setTimeout(resolve, 2000));
        actors = await this.identify(config.ownershipToken);
      }
      if (!stableIdentity() || new Set(actors.clients.map(actor => actor.userId)).size !== players) {
        throw new Error(`CLIENT_IDENTITY_NOT_STABLE: clients=${JSON.stringify(actors.clients.map(actor => actor.userId))}`);
      }
      this.active = { serverId: actors.server[0].studioId, clients: actors.clients, ownershipToken: config.ownershipToken };
      return { ...readiness, ok: true, attempted: true, process: this.processIdentity, ...this.active };
    } catch (error) {
      this.lifecycle.fail('session-admission', error.message);
      return { ...readiness, ok: false, attempted: !!this.processIdentity, blockers: [error.message] };
    }
  }

  async identify(token) {
    const result = { edit: [], server: [], clients: [] };
    for (const id of await this.inventory()) {
      if (this.baseline.includes(id)) continue;
      // A studio with no open place has no datamodel and can never be the owned editor, whose
      // ownership is proven below by the ForgeQAOwner token and placeId. request() returns the
      // terminal no-place sentinel instead of throwing, so this skips the id; every other
      // state failure propagates with its studio id so a disconnect, deadline or auth error
      // is never silently ignored.
      let state;
      try {
        state = await this.request('identify-state', () => this.transport.call('get_studio_state', { studio_id: id }));
      } catch (error) {
        throw new Error(`identify-state ${id}: ${String((error && error.message) || error)}`);
      }
      if (state === NO_PLACE) continue;
      const text = JSON.stringify(state);
      const model = text.includes('Focused DataModel in the viewport: Client') ? 'Client' : text.includes('Focused DataModel in the viewport: Server') ? 'Server' : text.includes('Current Studio Mode: Edit') ? 'Edit' : null;
      if (!model) continue;
      const identity = decode(await this.request('identify-owner', () => this.transport.call('execute_luau', {
        studio_id: id, datamodel_type: model,
        code: "local p=game:GetService('Players').LocalPlayer;return game:GetService('HttpService'):JSONEncode({token=game:GetService('ReplicatedStorage'):GetAttribute('ForgeQAOwner'),placeId=game.PlaceId,userId=p and tostring(p.UserId)})",
      })));
      if (identity.token !== token || identity.placeId !== 0) continue;
      result[model === 'Edit' ? 'edit' : model === 'Server' ? 'server' : 'clients'].push({ studioId: id, userId: identity.userId });
    }
    return result;
  }

  async reconcile() {
    if (!this.baseline) throw new Error('SESSION_BASELINE_REQUIRED');
    try {
      const connected = await this.inventory();
      return {
        settled: false,
        connected,
        unclaimed: connected.filter(id => !this.baseline.includes(id)),
        missing: this.baseline.filter(id => !connected.includes(id)),
        blocker: 'INVENTORY_IS_NOT_ALLOCATION_OWNERSHIP_OR_EXIT_PROOF',
      };
    } catch {
      return { settled: false, blocker: 'RECONCILIATION_TRANSPORT_UNAVAILABLE' };
    }
  }

  async endOwnedTest({ serverId, ownershipToken }) {
    if (!this.discovery || this.discovery.blockers.length) throw new Error('SESSION_DISCOVERY_REQUIRED');
    if (typeof serverId !== 'string' || !serverId || typeof ownershipToken !== 'string' || !/^[a-zA-Z0-9-]+$/.test(ownershipToken)) throw new Error('INVALID_SESSION_IDENTITY');
    // EndTest targets this owned multiplayer test, not an arbitrary client or
    // every Studio process. A response is a stop request, never exit proof.
    const response = await this.request('end-owned-test', () => this.transport.call('execute_luau', {
      studio_id: serverId,
      datamodel_type: 'Server',
      code: `assert(game.PlaceId==0,'FOREIGN_PLACE');assert(game:GetService('ReplicatedStorage'):GetAttribute('ForgeQAOwner')==${JSON.stringify(ownershipToken)},'FOREIGN_SESSION');task.defer(function() game:GetService('StudioTestService'):EndTest(0) end);return game:GetService('HttpService'):JSONEncode({stopRequested=true})`,
    }));
    const value = decode(response);
    if (value.stopRequested !== true) throw new Error('END_TEST_NOT_ACKNOWLEDGED');
    return { stopRequested: true, released: false, evidence: { responseSha256: digest(response) }, blocker: 'OWNED_TEST_EXIT_PROOF_REQUIRED' };
  }

  async crashAtBarrier({ key, requestId, phase, trigger, buildIdentity, namespace }) {
    if (!this.active || !this.controller) throw new Error('OWNED_SESSION_REQUIRED');
    const execute = code => this.request('durable-barrier', () => this.transport.call('execute_luau', {
      studio_id: this.active.serverId, datamodel_type: 'Server', code,
    })).then(decode);
    const armed = await execute(`local p=game:GetService('ServerStorage'):FindFirstChild('ForgePersistence');assert(p,'PERSISTENCE_TELEMETRY_UNAVAILABLE')
local h=game:GetService('ServerScriptService').ForgeBuildIdentity.Handshake:Invoke();assert(h.buildIdentity==${JSON.stringify(buildIdentity)},'BUILD_MISMATCH')
local m=Instance.new('StringValue');m.Name='ForgeCrashBarrier';m.Parent=p
local connection=p.BarrierReached.Event:Connect(function(event) m.Value=game:GetService('HttpService'):JSONEncode(event) end)
m.Destroying:Once(function() connection:Disconnect() end)
local armed=p.armBarrier:Invoke(${JSON.stringify(key)},${JSON.stringify(requestId)},${JSON.stringify(phase)})
assert(armed.identity.namespace==${JSON.stringify(namespace)},'NAMESPACE_MISMATCH')
return game:GetService('HttpService'):JSONEncode({ticket=armed.ticket,identity=armed.identity,runtime=h})`);
    try {
      await trigger(); // Dispatch acknowledgement only, never blocked commit ACK.
      const status = await execute(`local p=game:GetService('ServerStorage').ForgePersistence;local m=p.ForgeCrashBarrier
if m.Value=='' then
 local thread=coroutine.running();local waiting=true
 local c=m.Changed:Connect(function() if waiting and m.Value~='' then waiting=false;task.spawn(thread) end end)
 local timer=task.delay(30,function() if waiting then waiting=false;task.spawn(thread) end end)
 if m.Value=='' and waiting then coroutine.yield() end
 c:Disconnect();if coroutine.status(timer)=='suspended' then task.cancel(timer) end
end
assert(m.Value~='','BARRIER_EVENT_TIMEOUT')
local event=game:GetService('HttpService'):JSONDecode(m.Value);assert(event.ticket==${JSON.stringify(armed.ticket)},'BARRIER_TICKET_MISMATCH')
local status=p.barrierStatus:Invoke(event.ticket)
assert(status.held and status.ackState=='held' and status.expiresAtMs-DateTime.now().UnixTimestampMillis>30000,'BARRIER_NOT_HELD_FOR_CRASH')
return game:GetService('HttpService'):JSONEncode(status)`);
      if (status.identity.namespace!==namespace || status.requestId!==requestId || status.phase!==phase || status.record?.key!==key) throw new Error('BARRIER_RUNTIME_BINDING_MISMATCH');
      // This authority is read from the owned runtime; no caller JSON ticket is
      // accepted. Expiry raises before ACK in RuntimeBackend, never auto-success.
      const proof = await this.controller.close();
      if (!proof.released) throw new Error('OWNED_CRASH_EXIT_UNPROVEN');
      return { ...proof, barrier: status, runtime: armed.runtime, process: this.processIdentity };
    } catch (error) {
      this.lifecycle.fail('durable-crash', error.message);
      throw error;
    }
  }

  async crashLeaseRenewal({key,actorId,buildIdentity,namespace}) {
    if(!this.active?.clients.some(client=>client.userId===actorId))throw new Error('OWNED_LEASE_ACTOR_REQUIRED');
    try { return await this.crashAtBarrier({key,requestId:'owned-renewal',phase:'LEASE_RENEWED',buildIdentity,namespace,
      trigger:()=>this.request('lease-refresh-dispatch',()=>this.transport.call('execute_luau',{
        studio_id:this.active.serverId,datamodel_type:'Server',
        code:`local holder=Instance.new('Folder');holder.Name='ForgeLeaseRefresh';holder.Parent=game:GetService('ServerStorage')
local worker;local c;local timer;local done
holder.Destroying:Connect(function() if c then c:Disconnect() end;if timer and coroutine.status(timer)=='suspended' then task.cancel(timer) end;if worker and coroutine.status(worker)=='suspended' then task.cancel(worker) end;if done then done:Destroy() end end)
worker=task.defer(function()
local p=game:GetService('ServerStorage').ForgePersistence
local state=p.snapshot:Invoke();local expires
for _,record in state.records do if record.key==${JSON.stringify(key)} then local value=game:GetService('HttpService'):JSONDecode(record.serialized);expires=value.lease and value.lease.expiresAt end end
assert(expires,'OBSERVED_LEASE_REQUIRED')
-- Cross one authoritative integer second via an engine event, not a fixed sleep.
local second=math.max(math.floor(DateTime.now().UnixTimestampMillis/1000),expires-120)
done=Instance.new('BindableEvent');local expired=false
c=game:GetService('RunService').Heartbeat:Connect(function() if math.floor(DateTime.now().UnixTimestampMillis/1000)>second then done:Fire() end end)
timer=task.delay(5,function() expired=true;done:Fire() end)
done.Event:Wait();c:Disconnect();if coroutine.status(timer)=='suspended' then task.cancel(timer) end;done:Destroy();assert(not expired,'LEASE_CLOCK_TIMEOUT')
game:GetService('ServerStorage').ForgeQA.snapshot:Invoke('survival-coop',${JSON.stringify(actorId)})
end);return game:GetService('HttpService'):JSONEncode({dispatched=true})`,
      }))});
    } finally {
      if(!this.lifecycle.resources.some(row=>row.id==='owned-editor' && row.cleanup==='released')) {
        await this.request('lease-refresh-cleanup',()=>this.transport.call('execute_luau',{studio_id:this.active.serverId,datamodel_type:'Server',code:"local h=game:GetService('ServerStorage'):FindFirstChild('ForgeLeaseRefresh');if h then h:Destroy() end;return 'LEASE_REFRESH_DISPOSED'"}));
      }
    }
  }

  async crashStartupLease({key,namespace}) {
    if(!this.active||!this.controller)throw new Error('OWNED_SESSION_REQUIRED');
    // The startup lease barrier is armed and published by the server's own bootstrap, which
    // can still be running when the editor registers with the bridge. Wait for the actual
    // object and marker under one bounded deadline instead of reading a member that does not
    // exist yet (observed: the LEASE_ACQUIRED restart read failed COLLECTION_FAILED with
    // 'ForgePersistence is not a valid member of ServerStorage').
    const value=decode(await this.request('startup-lease-held',()=>this.transport.call('execute_luau',{
      studio_id:this.active.serverId,datamodel_type:'Server',
      code:`${objectReadiness({service:'ServerStorage',object:'ForgePersistence',child:'StartupLeaseReached',childClass:'StringValue',childCondition:'nonempty'})}
local p=game:GetService('ServerStorage').ForgePersistence;local m=p.StartupLeaseReached;assert(m.Value~='','STARTUP_LEASE_NOT_OBSERVED');local event=game:GetService('HttpService'):JSONDecode(m.Value);local status=p.barrierStatus:Invoke(event.ticket);assert(status.held and status.ackState=='held' and status.expiresAtMs-DateTime.now().UnixTimestampMillis>30000,'LEASE_NOT_HELD');return game:GetService('HttpService'):JSONEncode(status)`,
    })));
    if(value.phase!=='LEASE_ACQUIRED'||value.record?.key!==key||value.identity?.namespace!==namespace)throw new Error('STARTUP_LEASE_BINDING_MISMATCH');
    const proof=await this.controller.close();
    if(!proof.released)throw new Error('OWNED_CRASH_EXIT_UNPROVEN');
    return {...proof,barrier:value,process:this.processIdentity};
  }

  async crashTransfer({ actorId, key, phase, input, buildIdentity, namespace }) {
    const actor=this.active?.clients.find(client=>client.userId===actorId);
    if(!actor)throw new Error('OWNED_TRANSFER_ACTOR_REQUIRED');
    const execute=code=>this.request('transfer-predispatch',()=>this.transport.call('execute_luau',{studio_id:actor.studioId,datamodel_type:'Client',code})).then(decode);
    await execute(`local p=game:GetService('Players').LocalPlayer;assert(not p:FindFirstChild('ForgeOwnedDispatchGate'),'dispatch gate exists')
local gate=Instance.new('BindableFunction');gate.Name='ForgeOwnedDispatchGate';gate.Parent=p
local request=Instance.new('StringValue');request.Name='Request';request.Parent=gate
local release=Instance.new('BindableEvent');release.Name='Release';release.Parent=gate
gate.OnInvoke=function(packet)
 assert(request.Value=='','multiple dispatches refused')
 local thread=coroutine.running();local waiting=true;local allowed=false
 local c=release.Event:Connect(function() if waiting then allowed=true;waiting=false;task.spawn(thread) end end)
 local timer=task.delay(30,function() if waiting then waiting=false;task.spawn(thread) end end)
 request.Value=game:GetService('HttpService'):JSONEncode(packet)
 if waiting then coroutine.yield() end
 c:Disconnect();if coroutine.status(timer)=='suspended' then task.cancel(timer) end
 return allowed
end
return game:GetService('HttpService'):JSONEncode({subscribed=true})`);
    try {
      await input(); // Real product input only; no request envelope accepted.
      const request=await execute(`local m=game:GetService('Players').LocalPlayer.ForgeOwnedDispatchGate.Request
if m.Value=='' then local t=coroutine.running();local waiting=true;local c=m.Changed:Connect(function() if waiting then waiting=false;task.spawn(t) end end);local timeout=task.delay(10,function() if waiting then waiting=false;task.spawn(t) end end);if waiting then coroutine.yield() end;c:Disconnect();if coroutine.status(timeout)=='suspended' then task.cancel(timeout) end end
assert(m.Value~='','TRANSFER_REQUEST_NOT_OBSERVED');return m.Value`);
      if(request.actorId!==actorId || !['survival-coop:transfer-deposit','survival-coop:transfer-withdraw'].includes(request.action))throw new Error('TRANSFER_REQUEST_IDENTITY_MISMATCH');
      const originalCommand=observedTransferCommand(request,actorId,namespace);
      const proof=await this.crashAtBarrier({key,requestId:request.requestId,phase,buildIdentity,namespace,trigger:()=>execute("game:GetService('Players').LocalPlayer.ForgeOwnedDispatchGate.Release:Fire();return game:GetService('HttpService'):JSONEncode({released=true})")});
      return {...proof,originalCommand};
    } finally {
      if(!this.lifecycle.resources.some(row=>row.id==='owned-editor' && row.cleanup==='released')) {
        await execute("local g=game:GetService('Players').LocalPlayer:FindFirstChild('ForgeOwnedDispatchGate');if g then g:Destroy() end;return game:GetService('HttpService'):JSONEncode({clean=true})");
      }
    }
  }

  async fetchPersistenceSnapshot(label, serverId) {
    // ExecuteLuauTool truncates a single result near 100k chars and
    // StringValue.Value caps at 200k; the rejoin snapshot (~280k encoded)
    // exceeds both. Store it as 90k parts in a folder, read raw pieces.
    const arm = decode(await this.request(`${label}-arm`, () => this.transport.call('execute_luau', {
      studio_id: serverId, datamodel_type: 'Server',
      code: "local s=game:GetService('ServerStorage');local p=s:FindFirstChild('ForgePersistence');assert(p,'PERSISTENCE_TELEMETRY_UNAVAILABLE');local value=p.snapshot:Invoke();value.configConsumed=s:FindFirstChild('ForgeOwnedPersistenceConfig')==nil;local enc=game:GetService('HttpService'):JSONEncode(value);local old=s:FindFirstChild('ForgeQASnapshot');if old then old:Destroy() end;local folder=Instance.new('Folder');folder.Name='ForgeQASnapshot';folder.Parent=s;local size=90000;local count=math.ceil(#enc/size);for i=1,count do local part=Instance.new('StringValue');part.Name='p'..i;part.Value=enc:sub((i-1)*size+1,i*size);part.Parent=folder end;return game:GetService('HttpService'):JSONEncode({parts=count,bytes=#enc})",
    })));
    const parts = [];
    for (let index = 1; index <= arm.parts; index++) {
      const result = await this.request(`${label}-chunk-${index}`, () => this.transport.call('execute_luau', {
        studio_id: serverId, datamodel_type: 'Server',
        code: `local folder=game:GetService('ServerStorage'):FindFirstChild('ForgeQASnapshot');assert(folder,'QA_SNAPSHOT_SLOT_MISSING');local part=folder:FindFirstChild('p${index}');assert(part,'QA_SNAPSHOT_PART_MISSING');return part.Value`,
      }));
      const text = (result.content || []).filter(part => part.type === 'text').map(part => part.text).join('\n');
      parts.push(text);
    }
    await this.request(`${label}-clear`, () => this.transport.call('execute_luau', {
      studio_id: serverId, datamodel_type: 'Server',
      code: "local folder=game:GetService('ServerStorage'):FindFirstChild('ForgeQASnapshot');if folder then folder:Destroy() end;return game:GetService('HttpService'):JSONEncode({cleared=true})",
    }));
    try {
      return JSON.parse(parts.join(''));
    } catch (error) {
      throw new Error(`${(error && error.message) || error} | SNAPSHOT_CHUNKED len=${parts.join('').length} parts=${arm.parts} expected=${arm.bytes}`);
    }
  }

  async restart(config, players, openFresh) {
    if (!this.active || !this.controller) throw new Error('OWNED_SESSION_REQUIRED');
    const before = await this.fetchPersistenceSnapshot('rejoin-persistence', this.active.serverId);
    if (before.overflow || !['studio-local','studio-datastore'].includes(before.identity?.mode)) throw new Error('PERSISTENT_REJOIN_BACKEND_REQUIRED');
    const oldActors = this.active.clients;
    await this.endOwnedTest(this.active);
    const closeEvidence = await this.controller.close();
    const closedAt=performance.now();
    if (!closeEvidence.released) throw new Error('REJOIN_OLD_TREE_EXIT_UNPROVEN');
    // A Studio test stop does not prove the old server released its fenced leases, and a fresh
    // server that acquires a still-leased record refuses with "locked" before ForgeQA binds. The
    // pre-stop snapshot is not enough: the old server keeps renewing until it stops (fcr33: camp-v1
    // renewed past the snapshot's latest expiry). Every lease it could have renewed expires within
    // one lease length of the stop, so wait for that bound (the backend caps it at 125 s).
    const LEASE_SECONDS = 120;
    const held = before.records.some(record => { try { return JSON.parse(record.serialized)?.lease?.expiresAt !== undefined; } catch { return false; } });
    const waitLeaseExpiry = held ? Math.ceil(Date.now() / 1000) + LEASE_SECONDS + 1 : undefined;
    const launchConfig = waitLeaseExpiry !== undefined && config.persistence
      ? { ...config, persistence: { ...config.persistence, waitLeaseExpiry } } : config;
    const fresh = await openFresh();
    const admission = await fresh.session.launch(launchConfig, players);
    if (!admission.ok) throw new Error(admission.blockers.join(';'));
    if (oldActors.some(actor => !admission.clients.some(next => next.userId===actor.userId && next.studioId!==actor.studioId))) throw new Error('REJOIN_ACTOR_REPLACEMENT_MISMATCH');
    admission.clients=oldActors.map(actor=>admission.clients.find(next=>next.userId===actor.userId));
    fresh.session.active.clients=admission.clients;
    // Profile bindings are committed asynchronously after the rejoin join;
    // wait (bounded, condition-based) until every rejoining actor's profile
    // appears in the backend record log before running the invariants.
    const after = await fresh.session.fetchPersistenceSnapshot('rejoin-load', admission.serverId);
    for (const key of ['mode','namespace','storeName','universeId']) if (after.identity?.[key]!==before.identity[key]) throw new Error('REJOIN_BACKEND_IDENTITY_MISMATCH');
    if(config.persistence?.instanceId) {
      before.identity.instanceId=config.persistence.instanceId;
      after.identity.instanceId=config.persistence.instanceId;
    }
    if (after.identity.epoch===before.identity.epoch || after.overflow) throw new Error('REJOIN_FRESH_LOAD_UNPROVEN');
    // Durable loads are observed later (observeRejoinLoads): members only load
    // their profiles when the scenario's re-join steps run after this returns.
    return { fresh, admission, before, after, loads: [], closeEvidence, closedAt, oldActors,oldInstallation:this.installation,newInstallation:fresh.session.installation };
  }

  async observeRejoinLoads(before, oldActors, serverId, instanceId) {
    const actorObserved = snapshot => oldActors.every(actor => snapshot.records.some(record => record.key === 'player-' + actor.userId || record.key.endsWith(':' + actor.userId)));
    let after = await this.fetchPersistenceSnapshot('rejoin-load', serverId);
    const deadline = Date.now() + 60000;
    while (!actorObserved(after) && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 3000));
      after = await this.fetchPersistenceSnapshot('rejoin-load', serverId);
    }
    if (instanceId) {
      before.identity.instanceId = instanceId;
      after.identity.instanceId = instanceId;
    }
    const latest = new Map(before.records.map(record=>[record.key,record]));
    const loads=[];
    for (const record of after.records) {
      const committed=latest.get(record.key);
      if (!committed) continue;
      const old=JSON.parse(committed.serialized),loaded=JSON.parse(record.previousSerialized);
      if (!loaded || loaded.revision<old.revision) throw new Error('REJOIN_DURABLE_REVISION_REGRESSED');
      const ordered=value=>Array.isArray(value)?value.map(ordered):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(key=>[key,ordered(value[key])])):value;
      // The world keeps running between the pre-stop snapshot and the stop, so a later committed
      // revision (fcr37: a wild hit and the respawn landed in that window) is newer durable state, not
      // a lost write; the revision check above already refuses a regression. Equal revisions must be
      // byte-identical data.
      if(loaded.revision===old.revision && JSON.stringify(ordered(loaded.data))!==JSON.stringify(ordered(old.data))) {
        // Name the record and the first differing paths so a failure is diagnosable from the error alone.
        const diffs=[];
        const walk=(x,y,path)=>{
          if(diffs.length>=6)return;
          if(x&&y&&typeof x==='object'&&typeof y==='object'){for(const k of new Set([...Object.keys(x),...Object.keys(y)]))walk(x[k],y[k],path+'.'+k);return;}
          if(JSON.stringify(x)!==JSON.stringify(y))diffs.push(path+': '+JSON.stringify(x)?.slice(0,80)+' -> '+JSON.stringify(y)?.slice(0,80));
        };
        walk(old.data,loaded.data,'data');
        throw new Error(`REJOIN_DURABLE_DATA_CHANGED key=${record.key} committedRevision=${old.revision} loadedRevision=${loaded.revision} ${diffs.join(' | ')}`);
      }
      loads.push({profileKey:record.key,committed,loaded:record});
      latest.delete(record.key);
    }
    if (!loads.length || oldActors.some(actor=>!loads.some(load=>load.profileKey==='player-'+actor.userId || load.profileKey.endsWith(':'+actor.userId)))) throw new Error(`REJOIN_ACTOR_BACKEND_LOAD_NOT_OBSERVED | actors=${JSON.stringify(oldActors.map(actor=>actor.userId))} beforeKeys=${JSON.stringify(before.records.map(record=>record.key))} afterKeys=${JSON.stringify(after.records.map(record=>record.key))} beforeCount=${before.records.length} afterCount=${after.records.length}`);
    return { after, loads };
  }
}
