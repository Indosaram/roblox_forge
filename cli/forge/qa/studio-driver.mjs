import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdir, writeFile } from 'node:fs/promises';
import { gameplay, resolveReferences } from './studio-driver-gameplay.mjs';
import { inputStep } from './studio-driver-input.mjs';
import { attachSupplement, runDigest } from './studio-driver-artifacts.mjs';
import {deviceStep,restoreDeviceCode,motionStep,obstacleStep,turnCamera,collectDeviceDiagnostics,captureGeometry,validateGeometry,decodeRaster,decodeRasterLuma} from './studio-driver-surface.mjs';
import { assertVisualContent } from './studio-driver-content.mjs';
import {wildlifeTrace,conservation,wildlifeTraceCode,retainWildlifeTrace} from './studio-driver-wildlife.mjs';
import { StudioLifecycle } from './studio-driver-lifecycle.mjs';
import { StudioSession, openOwnedPersistence } from './studio-driver-session.mjs';
import { parallelPrompt } from './studio-driver-contention.mjs';
import { writeRejoin } from './studio-driver-rejoin.mjs';
import { registerClientSource } from './studio-driver-registration.mjs';
import { openCapture, buildSourceReceipt } from '../lib/qualityav-capture.mjs';
import { layersOf, withLayers } from './studio-driver-layers.mjs';
import { resolve, relative, isAbsolute } from 'node:path';

const hash = value => createHash('sha256').update(value).digest('hex');

// Only observations produced by the completed owned run can prove capability.
export function observedDiscovery(outcome) {
  const calls = outcome.calls || [];
  const runtime = outcome.runtime;
  const clients = runtime?.clients || [];
  const cleanup = outcome.lifecycle;
  const clean = outcome.ok === true && cleanup?.ok === true
    && Array.isArray(cleanup.residuals) && cleanup.residuals.length === 0;
  const admitted = clean && runtime?.server?.schemaVersion === 1
    && typeof runtime.server.sessionId === 'string'
    && clients.length >= 2
    && new Set(clients.map(client => client.actorId)).size === clients.length
    && new Set(clients.map(client => client.studio_id)).size === clients.length
    && clients.every(client => client.schemaVersion === 1
      && typeof client.actorId === 'string' && typeof client.studio_id === 'string'
      && client.sessionId === runtime.server.sessionId
      && client.buildIdentity === runtime.server.buildIdentity
      && client.serverBuildIdentity === runtime.server.buildIdentity);
  const observedCall = name => calls.some(call => call.name === name
    && typeof call.args_sha256 === 'string' && typeof call.result_sha256 === 'string');
  const input = admitted && observedCall('user_keyboard_input')
    && clients.every(client => (outcome.inputs || []).some(row =>
      row.studio_id === client.studio_id && row.key === 'F8'));
  const capture = admitted && observedCall('screen_capture')
    && clients.every(client => (outcome.captures || []).some(row =>
      row.studio_id === client.studio_id && row.actor === client.actorId
      && row.sessionId === client.sessionId && row.originalValidated === true));
  const capability = (available, invocation, blocker) =>
    available ? { available: true, invocation } : { available: false, blocker };
  const capabilities = {
    studio_connected: capability(admitted && observedCall('list_roblox_studios'),
      'list_roblox_studios({})', 'OWNED_RUNTIME_HANDSHAKES_NOT_PROVEN'),
    second_client: capability(admitted,
      'execute_luau: recorded ForgeBuildIdentity.Handshake observations for distinct clients',
      'TWO_OWNED_CLIENTS_NOT_PROVEN'),
    input_injection: capability(input,
      'user_keyboard_input: recorded calls followed by both clients InputBegan F8 observations',
      'SUBSCRIBED_CLIENT_INPUT_NOT_PROVEN'),
    screen_capture: capability(capture,
      'screen_capture: recorded calls with original decoded bytes and validated geometry',
      'VALIDATED_ORIGINAL_CLIENT_CAPTURES_NOT_PROVEN'),
  };
  return { schemaVersion: 1,
    status: Object.values(capabilities).every(row => row.available) ? 'OBSERVED' : 'BLOCKED',
    observedAt: new Date().toISOString(), capabilities, runtime: runtime || null,
    calls, captures: outcome.captures || [], inputs: outcome.inputs || [],
    cleanup: cleanup || { observed: false }, blockers: outcome.blockers || [] };
}
const eventWait = `local function observe(signal,action,required,timeoutSeconds,acceptEvent)
 local observed;local ok,result,extra;local completed=false;local expired=false
 local gate=Instance.new('BindableEvent');local waiter=coroutine.running();local waiting=false
 local wake=gate.Event:Connect(function() if waiting then waiting=false;task.spawn(waiter) end end)
 local function ready() return completed and (not ok or not required(result) or observed~=nil) end
 local connection=signal:Connect(function(value) if acceptEvent and not acceptEvent(value) then return end;observed=if value==nil then true else value;if ready() then gate:Fire() end end)
 local timer=task.delay(timeoutSeconds or 5,function() expired=true;gate:Fire() end)
 local worker=task.defer(function() ok,result,extra=pcall(action);completed=true;if ready() then gate:Fire() end end)
 if not ready() and not expired then waiting=true;coroutine.yield() end
 connection:Disconnect()
 wake:Disconnect();gate:Destroy()
 -- Only a suspended thread may be cancelled: resuming from inside the timer's or the
 -- worker's own call stack leaves that coroutine 'normal', where task.cancel throws
 -- 'cannot cancel thread'. Such a thread is already running or finished, so nothing
 -- remains to cancel.
 if coroutine.status(timer)=='suspended' then task.cancel(timer) end
 if coroutine.status(worker)=='suspended' then task.cancel(worker) end
 assert(not expired,'action or state signal timeout')
 assert(ok,result)
 if required(result) then assert(observed~=nil,'state signal timeout') end
 return result,observed,extra
end`;
const literal = value => {
  if (value === null || value === undefined) return 'nil';
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value !== 'object') return String(value);
  return `{${Object.entries(value).map(([key, item]) => `[${Array.isArray(value) ? Number(key) + 1 : literal(key)}]=${literal(item)}`).join(',')}}`;
};
// The genre snapshot carries per-player state; co-op shared sections (warehouse, settlement,
// gathering) live beside it in the session snapshot. A field whose head is absent from the genre
// snapshot is read from the shared section that owns it.
const SHARED_SNAPSHOTS = ['survivalSettlement', 'survivalGathering'];
const sharedSnapshot = (genre, userId, field) => {
  const head = Array.isArray(field) ? field[0] : String(field).split('.')[0];
  return `local q=game:GetService('ServerStorage').ForgeQA;local value=q.snapshot:Invoke(${literal(genre)},${literal(userId)})
if type(value)=='table' and value[${literal(head)}]==nil then for _,name in ${literal(SHARED_SNAPSHOTS)} do local shared=q.snapshot:Invoke(name,${literal(userId)});if type(shared)=='table' and shared[${literal(head)}]~=nil then value=shared;break end end end`;
};

export class StdioMcp {
  constructor(command, args, timeoutMs, lifecycle = new StudioLifecycle()) {
    this.lifecycle = lifecycle;
    const owned = lifecycle.attempt('process', 'mcp-transport', async () => {
      if (!this.child) return { released: true, evidence: { spawnNotStarted: true } };
      this.fail(new Error('MCP transport closed'));
      this.lines?.close();
      this.child.stdin?.end();
      if (this.child.exitCode === null && this.child.signalCode === null && this.child.pid) this.child.kill();
      const exit = await this.exited;
      return { released: true, evidence: exit };
    });
    this.child = spawn(command, args, { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    // Register exit observation before initialization or a cleanup stop request.
    this.exited = new Promise(resolve => {
      this.child.once('close', (code, signal) => resolve({ code, signal, pid: this.child.pid ?? null }));
    });
    this.child.once('spawn', () => {
      if (!lifecycle.closing) lifecycle.acquire(owned, { pid: this.child.pid });
    });
    this.pending = new Map();
    this.sequence = 0;
    this.timeoutMs = timeoutMs;
    this.deadline = Date.now() + timeoutMs;
    this.stderr = '';
    this.child.stderr.on('data', data => { this.stderr += data; });
    this.lines = createInterface({ input: this.child.stdout });
    this.lines.on('line', line => {
      try {
        const message = JSON.parse(line);
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        clearTimeout(pending.timer);
        if (message.error) pending.reject(new Error(JSON.stringify(message.error)));
        else pending.resolve(message.result);
      } catch (error) {
        this.fail(error);
      }
    });
    this.child.on('error', error => this.fail(error));
    this.child.on('exit', code => this.fail(new Error(`MCP exited ${code}: ${this.stderr}`)));
  }
  fail(error) {
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
  }
  request(method, params) {
    if (Date.now() >= this.deadline) return Promise.reject(new Error(`MCP deadline: ${method}`));
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`MCP timeout: ${method}`)); }, Math.min(this.timeoutMs, this.deadline - Date.now()));
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
    });
  }
  async initialize() {
    await this.request('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'forge-studio-qa', version: '1' } });
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`);
  }
  async call(name, args) {
    const result = await this.request('tools/call', { name, arguments: args });
    if (result.isError) throw new Error(`${name}: ${JSON.stringify(result)}`);
    return result;
  }
  close() { return this.lifecycle.close(); }
}

// Production admission is separate from the capture executor: preexisting
// configured IDs do not establish launch ownership or a recoverable session.
export async function runOwnedStudio(scenario, config, transport, lifecycle, artifactWriter) {
  if (config.capture?.probe === true) {
    const capture = config.capture;
    if (scenario.name !== 'owned-av-probe' || scenario.kind !== 'studio'
        || scenario.audiovisualSources !== undefined || typeof capture.player !== 'string'
        || !Array.isArray(scenario.players) || scenario.players.filter(player => player === capture.player).length !== 1
        || capture.actorId !== undefined || capture.mode !== 'owned-process-loopback') {
      throw new Error('OWNED_AV_PROBE_CONFIG_INVALID');
    }
    const manifest = relative(process.cwd(), resolve(config.artifactDirectory, 'av-probe-manifest.json')).replaceAll('\\', '/');
    if (isAbsolute(manifest) || manifest.startsWith('../')) throw new Error('CAPTURE_PROBE_OUTSIDE_ROOT');
    scenario = { ...scenario, audiovisualSources: { [manifest]: { purpose: 'owned-av-probe' } } };
  }
  if(config.persistence) {
    const ready=await openOwnedPersistence(config.persistence,lifecycle);
    config={...config,persistence:{...config.persistence,instanceId:ready.instanceId,hostReady:ready}};
  }
  const session = new StudioSession(transport, lifecycle);
  const admission = await session.launch(config, scenario.players?.length);
  if (!admission.ok) return { ok: false, kind: 'studio', scenario: scenario.name, status: 'BLOCKED',
    blockers: admission.blockers, session: admission, clients: [], steps: [], captures: [], cleanup: [] };
  let outcome;
  let currentSession=session;
  try {
    const rejoin=async()=>{
      const replacement=await currentSession.restart(config,scenario.players.length,async()=>{
        const nextLifecycle=new StudioLifecycle();
        const row=lifecycle.attempt('replacement-session',`replacement-${Date.now()}`,async()=>{
          const proof=await nextLifecycle.close();
          return {released:proof.ok,evidence:proof};
        });
        const nextTransport=new StdioMcp(config.command,config.args,scenario.timeout_seconds*1000,nextLifecycle);
        await nextTransport.initialize();
        lifecycle.acquire(row,{transport:true});
        return {transport:nextTransport,session:new StudioSession(nextTransport,nextLifecycle)};
      });
      currentSession=replacement.fresh.session;
      return replacement;
    };
    const prepareCapture = scenario.audiovisualSources ? async (runtime, ownedProcess, clients, activeTransport) => {
      const actor=config.capture?.probe===true
        ? clients[scenario.players.indexOf(config.capture.player)]
        : clients.find(client=>client.userId===config.capture?.actorId);
      const loaded=runtime.clients.find(client=>client.actorId===actor?.userId && client.studio_id===actor?.studioId);
      if(!loaded || loaded.sessionId!==runtime.server.sessionId)throw new Error('SOURCE_ACTOR_PROCESS_UNPROVEN');
      if(config.capture?.mode && config.capture.mode!=='owned-process-loopback')throw new Error('CAPTURE_ISOLATION_UNPROVEN');
      const source=await registerClientSource({logical:{sessionId:loaded.sessionId,buildIdentity:loaded.buildIdentity,actorId:loaded.actorId,studioId:loaded.studio_id},ownedProcess,artifactDirectory:config.artifactDirectory,transport:activeTransport,lifecycle});
      if(source.registrationObserved!==true || source.role!=='game-client' || !source.registrationEvidence || typeof source.registrationEvidence!=='object' || !/^[a-f0-9]{64}$/.test(source.registrationEvidence.sha256) || typeof source.registrationEvidence.path!=='string')throw new Error('SOURCE_ACTOR_PROCESS_UNPROVEN');
      const capture=openCapture({sources:scenario.audiovisualSources,process:{pid:source.pid,identity:source.processIdentity},clients,
        ownershipToken:config.ownershipToken+'-capture-'+loaded.sessionId,artifactDirectory:resolve(config.artifactDirectory,'av-original-'+source.registrationDigest.slice(-16)),lifecycle,
        window:{hwnd:source.hwnd,pid:source.pid,identity:source.processIdentity},mode:'owned-process-loopback',root:process.cwd()});
      capture.actorSource=source;
      return capture;
    } : undefined;
    outcome = await runStudio(scenario, { ...config, serverId: admission.serverId, clients: admission.clients, processIdentity:admission.process, rejoin, capture:undefined, prepareCapture, capturePolicy:config.capture?.policy }, transport, artifactWriter);
    outcome.session = admission;
    if(config.capture?.probe===true) {
      outcome.purpose='owned-av-probe';
      outcome.releaseApproval=false;
    }
    return outcome;
  } finally {
    try { await currentSession.endOwnedTest(currentSession.active); }
    catch { if (outcome) outcome.stopRequest = 'TRANSPORT_LOST_OWNED_JOB_CLEANUP_REQUIRED'; }
    // The caller's finally closes the job even when EndTest loses transport.
  }
}

function jsonResult(result) {
  const text = (result.content || []).filter(item => item.type === 'text').map(item => item.text).join('\n');
  const marker = text.match(/FORGE_QA_JSON:([^\r\n]+)/);
  return JSON.parse(marker ? marker[1] : text);
}

function compare(actual, step) {
  if ('is_nil' in step) return (actual === undefined || actual === null) === step.is_nil;
  if ('equals' in step) return JSON.stringify(actual) === JSON.stringify(step.equals);
  if ('not_equals' in step) return JSON.stringify(actual) !== JSON.stringify(step.not_equals);
  if ('at_least' in step) return typeof actual === 'number' && actual >= step.at_least;
  if ('at_most' in step) return typeof actual === 'number' && actual <= step.at_most;
  return false;
}

export function pathSequence(records, npcId, outcome) {
  const states = new Map();
  for (const record of records) {
    if (record.npcId !== npcId || !Number.isSafeInteger(record.serial) || !Number.isFinite(record.atMillis)) continue;
    let state = states.get(record.serial);
    if (record.phase === 'requested') { states.set(record.serial, { phase: 'requested', at: record.atMillis }); continue; }
    if (!state || record.atMillis < state.at) continue;
    if (record.phase === 'result' && state.phase === 'requested' && ['NoPath','ComputeError','Blocked','MoveFailed'].includes(record.status)) state = { phase: 'failed', status: record.status, at: record.atMillis };
    else if (record.phase === 'consumed' && state.phase === 'failed' && record.status === state.status) state = { ...state, phase: 'consumed', at: record.atMillis };
    else if (record.phase === outcome && state.phase === 'consumed' && record.status === (outcome === 'recovered' ? 'Success' : state.status)) return true;
    states.set(record.serial, state);
  }
  return false;
}

export async function runStudio(scenario, config, transport, artifactWriter) {
  const outcome = { ok: false, kind: 'studio', scenario: scenario.name, blockers: [], clients: [], steps: [], captures: [], inputs: [], calls: [], cleanup: [] };
  const installed = [];
  const pathMarkers = [];
  const started=performance.now();
  const deadline = Date.now() + scenario.timeout_seconds * 1000;
  // A freshly started client registers with the MCP host before its Luau bridge is
  // ready, so the first calls can report a transient reachability failure. Retry only
  // that specific transient inside the scenario deadline; every other error propagates.
  // The MCP hub on localhost is owned by whichever StudioMCP process started first; when that
  // process exits (a rejoin closes the old transport, or another tool's session ends) every Studio
  // reconnects to the next hub within a few seconds. Calls in that window report no connected
  // instance, which is the same transient as a bridge that is still loading.
  const transientReachability = error => /Target is not reachable|createExecuteLuauBridge|Place is not open|No Roblox Studio instances are connected|is not connected/i.test(String(error && error.message ? error.message : error));
  const call = async (name, args) => {
    if (Date.now() >= deadline) throw new Error('scenario deadline exceeded');
    let result;
    for (let attempt = 0; ; attempt++) {
      try { result = await transport.call(name, args); break; }
      catch (error) {
        if (!transientReachability(error) || attempt >= 30 || Date.now() >= deadline) throw error;
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    }
    outcome.calls.push({ name, args_sha256: hash(JSON.stringify(args)), result_sha256: hash(JSON.stringify(result)) });
    return result;
  };
  let stepLabel='pre-step';
  const execute = async (id, model, code) => {
    try {
      return jsonResult(await call('execute_luau', {
        studio_id: id, datamodel_type: model,
        code: `${eventWait}\n${code}\nreturn game:GetService('HttpService'):JSONEncode(value)`,
      }));
    } catch (error) {
      throw new Error(`${stepLabel}: ${(error && error.message) || error}`);
    }
  };
  try {
    if (scenario.kind !== 'studio' || !Array.isArray(scenario.steps)) throw new Error('parsed kind: studio scenario required');
    if (!config.ownershipToken || !config.serverId || !Array.isArray(config.clients) || config.clients.length !== scenario.players.length || config.clients.length < 2) throw new Error('owned server and at least two mapped clients required');
    if (scenario.steps.some(step=>step.op==='touch')) throw new Error('TOUCH_INPUT_UNAVAILABLE: no verified product touch injection schema; mouse and keyboard are not touch');
    if (new Set([config.serverId, ...config.clients.map(client => client.studioId)]).size !== config.clients.length + 1) throw new Error('distinct owned server/client IDs required');
    const supported = ['join', 'dispatch', 'command', 'expect_result', 'expect_snapshot', 'expect_members', 'capture', 'advance_to', 'begin_clock', 'advance_elapsed', 'save', 'restore', 'server_command', 'walk_to', 'activate_prompt', 'bind_result', 'bind_snapshot', 'keyboard', 'click', 'equip', 'wait_for', 'rejoin'];
    supported.push('device','motion_begin','motion_end','obstacle','parallel_prompt','path_begin','path_end');
    for (const step of scenario.steps) if (!supported.includes(step.op) || step.scope === 'session' || step.expect_suspended) throw new Error(`unsupported live operation: ${step.op}`);
    if (scenario.fixtures?.length || Object.keys(scenario.data || {}).length) throw new Error('native fixtures/data cannot initialize a live Studio run');
    const schemas = await transport.request('tools/list', {});
    const requiredParameters = { list_roblox_studios: [], get_studio_state: ['studio_id'], execute_luau: ['code', 'datamodel_type', 'studio_id'], screen_capture: ['capture_id', 'studio_id'], user_keyboard_input: ['actions', 'datamodel_type', 'studio_id'] };
    for (const name of ['list_roblox_studios', 'get_studio_state', 'execute_luau', 'screen_capture', 'user_keyboard_input']) {
      const schema = schemas.tools.find(tool => tool.name === name);
      if (!schema) throw new Error(`missing MCP capability: ${name}`);
      for (const parameter of requiredParameters[name]) if (!schema.inputSchema?.properties?.[parameter]) throw new Error(`unsupported MCP schema: ${name}.${parameter}`);
      outcome.calls.push({ schema: name, sha256: hash(JSON.stringify(schema)) });
    }
    if (scenario.steps.some(step=>step.op==='click')) {
      const schema=schemas.tools.find(tool=>tool.name==='user_mouse_input');
      for(const key of ['actions','studio_id','datamodel_type']) if(!schema?.inputSchema?.properties?.[key]) throw new Error(`unsupported MCP schema: user_mouse_input.${key}`);
      outcome.calls.push({schema:'user_mouse_input',sha256:hash(JSON.stringify(schema))});
    }
    const studios = jsonResult(await call('list_roblox_studios', {})).studios;
    for (const [id, model] of [[config.serverId, 'Server'], ...config.clients.map(client => [client.studioId, 'Client'])]) {
      if (!studios.some(studio => studio.id === id)) throw new Error(`owned instance not connected: ${id}`);
      const state = await call('get_studio_state', { studio_id: id });
      if (!JSON.stringify(state).includes(model)) throw new Error(`missing ${model} datamodel: ${id}`);
      const identity = await execute(id, model, `local value={placeId=game.PlaceId,token=game:GetService('ReplicatedStorage'):GetAttribute('ForgeQAOwner'),player=game:GetService('Players').LocalPlayer and tostring(game:GetService('Players').LocalPlayer.UserId)}`);
      if (identity.placeId !== 0 || identity.token !== config.ownershipToken) throw new Error(`ownership mismatch: ${id}`);
      const client = config.clients.find(item => item.studioId === id);
      if (client && identity.player !== client.userId) throw new Error(`client identity mismatch: ${id}`);
      if(client) outcome.clients.push({studio_id:id,actor:identity.player});
    }
    const players = new Map(scenario.players.map((player, index) => [String(player), config.clients[index]]));
    if(!/^sha256:[a-f0-9]{64}$/.test(config.buildIdentity?.id || '')) throw new Error('BUILD_IDENTITY_INPUT_REQUIRED');
    outcome.runtime={server:null,clients:[]};
    for(const [id,model] of [[config.serverId,'Server'],...config.clients.map(c=>[c.studioId,'Client'])]) {
      const handshake=await execute(id,model,`local container=${model==='Server'?"game:GetService('ServerScriptService')":`((function()
local players=game:GetService('Players')
local lp=players.LocalPlayer or players:FindFirstChild('LocalPlayer')
local samples={}
for tick=1,90 do
  if not lp then lp=players.LocalPlayer or players:FindFirstChild('LocalPlayer') end
  table.insert(samples,tick..'/'..#players:GetPlayers()..'/'..(lp and 'Y' or 'n'))
  if lp then break end
  task.wait(1)
end
if not lp then error('BUILD_HANDSHAKE_UNAVAILABLE: no LocalPlayer after 90s; samples='..table.concat(samples,',')) end
return lp
end)():WaitForChild('PlayerScripts',90) or error('BUILD_HANDSHAKE_UNAVAILABLE: no PlayerScripts after 90s'))`}
assert(container,'BUILD_HANDSHAKE_UNAVAILABLE: container missing')
local scriptObject=container:WaitForChild('ForgeBuildIdentity',20);assert(scriptObject,'BUILD_HANDSHAKE_UNAVAILABLE: ForgeBuildIdentity script missing after 20s')
local fn=scriptObject:WaitForChild('Handshake',20);assert(fn and fn:IsA('BindableFunction'),'BUILD_HANDSHAKE_UNAVAILABLE: Handshake missing after 20s; script children='..#scriptObject:GetChildren())
local value=fn:Invoke()
value.ownedQaToken=game:GetService('ReplicatedStorage'):GetAttribute('ForgeQAOwner')
value.placeId=game.PlaceId`);
      if(handshake.ownedQaToken!==config.ownershipToken || handshake.placeId!==0) throw new Error('LOADED_OWNERSHIP_MISMATCH');
      if(handshake.schemaVersion!==1 || handshake.buildIdentity!==config.buildIdentity.id || handshake.role!==model.toLowerCase() || !handshake.sessionId) throw new Error('LOADED_IDENTITY_MISMATCH');
      handshake.studio_id=id;
      if(model==='Server')outcome.runtime.server=handshake;
      else {
        if(handshake.serverBuildIdentity!==config.buildIdentity.id || handshake.sessionId!==outcome.runtime.server.sessionId || handshake.actorId!==config.clients.find(c=>c.studioId===id).userId)throw new Error('CLIENT_RUNTIME_MISMATCH');
        outcome.runtime.clients.push(handshake);
      }
    }
    // Admission is complete before any source registration or capture allocation.
    // A replacement epoch calls the same callback with its newly loaded actors.
    const prepareCapture = async runtime => {
      if(!config.prepareCapture)return;
      config.capture=await config.prepareCapture(runtime,config.processIdentity,config.clients,transport);
      const source=config.capture.actorSource;
      outcome.registrations??={};
      outcome.registrations[source.studioId]=source.registrationDigest;
    };
    await prepareCapture(outcome.runtime);
    const initialClock=await execute(config.serverId,'Server','local value={runtimeMillis=DateTime.now().UnixTimestampMillis}');
    let clockAnchor={runtimeMillis:initialClock.runtimeMillis,elapsedSeconds:(performance.now()-started)/1000};
    const revision=async()=>{
      const value=await execute(config.serverId,'Server',"local value=game:GetService('ServerStorage').ForgeQA.revision:Invoke()");
      if(!Number.isSafeInteger(value) || value<0)throw new Error('RUNTIME_REVISION_UNAVAILABLE');
      return value;
    };
    // Install named input subscriptions before injecting any input. The callback
    // disconnects itself, so cleanup does not depend on polling or a later request.
    for (const client of config.clients) {
      await execute(client.studioId, 'Client', `local p=game:GetService('Players').LocalPlayer
assert(not p:FindFirstChild('ForgeQAInputProof'),'input proof already exists')
local marker=Instance.new('StringValue');marker.Name='ForgeQAInputProof';marker.Parent=p
local connection
connection=game:GetService('UserInputService').InputBegan:Connect(function(input)
 if input.KeyCode==Enum.KeyCode.F8 then marker.Value='F8';connection:Disconnect() end
end)
marker.Destroying:Once(function() connection:Disconnect() end)
task.delay(10,function() connection:Disconnect() end)
local value={subscribed='InputBegan',player=tostring(p.UserId)}`);
      installed.push(client);
      await call('user_keyboard_input', { studio_id: client.studioId, datamodel_type: 'Client', actions: [{ action: 'keyPress', key_code: 'F8' }] });
      const input = await execute(client.studioId, 'Client', `local m=game:GetService('Players').LocalPlayer:FindFirstChild('ForgeQAInputProof')
assert(m,'missing input subscription')
if m.Value~='F8' then
 local thread=coroutine.running();local done=false;local connection
 connection=m.Changed:Connect(function() if m.Value=='F8' and not done then done=true;connection:Disconnect();task.spawn(thread) end end)
 task.delay(5,function() if not done then done=true;connection:Disconnect();task.spawn(thread) end end)
 if m.Value~='F8' then coroutine.yield() end
end
assert(m.Value=='F8','InputBegan timeout');local value={key=m.Value}`);
      outcome.inputs.push({ studio_id: client.studioId, ...input });
    }
    const results = new Map(), saves = new Map();
    const preflightProbe = await execute(config.serverId,'Server',`local http=game:GetService('HttpService');local rs=game:GetService('ReplicatedStorage');local ss=game:GetService('ServerStorage');local value={httpEnabled=http.HttpEnabled,forgeState=rs:FindFirstChild('ForgeState')~=nil,persistence=ss:FindFirstChild('ForgePersistence')~=nil,qa=ss:FindFirstChild('ForgeQA')~=nil}`);
    for (const client of config.clients) {
      await execute(client.studioId, 'Client', `local rs=game:GetService('ReplicatedStorage')
local event=rs:FindFirstChild('ForgeState');assert(event,'ForgeState missing; server='..${literal(JSON.stringify(preflightProbe))})
local result,state=observe(event.OnClientEvent,function() return rs.ForgeAction:InvokeServer() end,function(r) return r.ok end)
assert(result.ok,'profile not ready');assert(state.snapshots,'snapshots missing');local value={revision=state.revision}`);
    }
    const bindings=new Map();
    const devices=new Map();
    if(config.capture) {
      const source=config.capture.actorSource;
      const client=outcome.runtime.clients.find(value=>value.actorId===source?.actorId && value.studio_id===source.studioId);
      if(!client || source.sessionId!==client.sessionId || source.buildIdentity!==config.buildIdentity.id)throw new Error('SOURCE_ACTOR_PROCESS_UNPROVEN');
      const before=(performance.now()-started)/1000;
      outcome.captureStart=await config.capture.start();
      outcome.captureStartBracket={before,after:(performance.now()-started)/1000};
    }
    for (const [index, original] of scenario.steps.entries()) {
      const startedSeconds=(performance.now()-started)/1000;
      stepLabel=`step ${index+1}:${original.op}`;
      const revisionBefore=await revision();
      const step={...original,args:resolveReferences(original.args,bindings),field:resolveReferences(original.field,bindings),target:resolveReferences(original.target,bindings)};
      if(step.args) step.args=step.args.map(value=>{
        if(value && typeof value==='object' && 'player' in value) {
          if(Object.keys(value).length!==1 || !players.has(value.player)) throw new Error('unknown actor reference');
          return players.get(value.player).userId;
        }
        return value;
      });
      if(original.predicate) step.predicate={...original.predicate,field:resolveReferences(original.predicate.field,bindings),...Object.fromEntries(['at_least','at_most','equals','not_equals'].filter(key=>key in original.predicate).map(key=>[key,resolveReferences(original.predicate[key],bindings)]))};
      if(original.untilState) step.untilState={...original.untilState,field:resolveReferences(original.untilState.field,bindings)};
      let client = players.get(String(step.player));
      let value;
      if(step.op==='device') {
        try {value=await deviceStep(step,client,execute);devices.set(client.studioId,{id:value.device,surface:step.surface,width:step.width,height:step.height});}
        finally {
          outcome.deviceDiagnostics ??= [];
          try {
            const diagnostic=await collectDeviceDiagnostics(client,execute);
            outcome.deviceDiagnostics.push({step:index+1,actor:client.userId,studio_id:client.studioId,...diagnostic});
            await execute(client.studioId,'Client',"local f=game:GetService('Players').LocalPlayer:FindFirstChild('ForgeQADeviceDiagnostic');if f then f:Destroy() end;local value={clean=true}");
          } catch(error) {outcome.blockers.push('device diagnostic collection: '+String(error.message || error));}
        }
      }
      else if(step.op==='motion_begin' || step.op==='motion_end') value=step.home || step.observations ? await wildlifeTrace(step,config.serverId,execute) : await motionStep(step,client,execute);
      else if(step.op==='obstacle') value=await obstacleStep(step,client,config.serverId,execute);
      else if (['keyboard','click','equip','wait_for'].includes(step.op)) {
        try {
          value=await inputStep(step,client,config.serverId,scenario.genre,execute,call);
        } catch(error) {
          // COMMAND_PENDING is the server's transient "another command of yours is still settling"
          // answer. The HUD keeps that request and offers its own Retry button, which is what a
          // player presses; the driver presses the same button (same request identity) a bounded
          // number of times instead of failing on a transient the product already handles.
          // A key press retries the same way: pressing the key again resends the kept request.
          if(!['click','keyboard'].includes(step.op) || !step.resultAction || !String(error?.message).includes('"COMMAND_PENDING"')) throw error;
          const retryStep=step.op==='keyboard' ? step : {...step,target:'Players.LocalPlayer.PlayerGui.ForgeSurvivalHUD.SafeArea.SurvivalSheet.Content.Retry'};
          let lastError=error;
          value=undefined;
          for(let retry=0;retry<4 && value===undefined;retry++) {
            await new Promise(resolve=>setTimeout(resolve,1000));
            try { value=await inputStep(retryStep,client,config.serverId,scenario.genre,execute,call); value.retriedPending=retry+1; }
            catch(retryError) { lastError=retryError; if(!String(retryError?.message).includes('"COMMAND_PENDING"')) throw retryError; }
          }
          if(value===undefined) throw lastError;
        }
        if(value.result) results.set(String(step.player),value.result);
        outcome.inputs.push({studio_id:client.studioId,op:step.op,value});
      } else if(step.op==='path_begin') {
        const marker='ForgeQAPath-'+step.label;
        pathMarkers.push(marker);
        value=await execute(config.serverId,'Server',`local storage=game:GetService('ServerStorage');local event=storage:FindFirstChild('ForgeWildlifePathObserved');assert(event and event:IsA('BindableEvent'),'PATH_TELEMETRY_UNAVAILABLE')
local target=game;for part in string.gmatch(${literal(step.target)},'[^.]+') do target=target:FindFirstChild(part);assert(target,'path target missing') end
local id=target:GetAttribute('ForgeWildlifeId');assert(id,'wildlife identity missing')
assert(not storage:FindFirstChild(${literal(marker)}),'path label already subscribed')
local m=Instance.new('StringValue');m.Name=${literal(marker)};m.Value='[]';m:SetAttribute('NpcId',id);m.Parent=storage
local records={};local connection=event.Event:Connect(function(record) if record.npcId==id then table.insert(records,record);m.Value=game:GetService('HttpService'):JSONEncode(records) end end)
m.Destroying:Once(function() connection:Disconnect() end)
local value={npcId=id,subscribed=true}`);
      } else if(step.op==='path_end') {
        value=await execute(config.serverId,'Server',`local m=game:GetService('ServerStorage'):FindFirstChild(${literal('ForgeQAPath-'+step.label)});assert(m,'path subscription missing')
local http=game:GetService('HttpService')
local function complete()
 local requested={};local failures={};local consumed={}
 for _,record in http:JSONDecode(m.Value) do
  if record.npcId~=m:GetAttribute('NpcId') then continue end
  local serial=record.serial
  if record.phase=='requested' then requested[serial]=record.atMillis end
  if record.phase=='result' and requested[serial] and record.atMillis>=requested[serial] and (record.status=='NoPath' or record.status=='ComputeError' or record.status=='Blocked' or record.status=='MoveFailed') then failures[serial]=record end
  if record.phase=='consumed' and failures[serial] and record.status==failures[serial].status and record.atMillis>=failures[serial].atMillis then consumed[serial]=record.atMillis end
  if record.phase==${literal(step.outcome)} and consumed[serial] and record.atMillis>=consumed[serial] and ((${literal(step.outcome)}=='recovered' and record.status=='Success') or record.status==failures[serial].status) then return true end
 end
 return false
end
if not complete() then observe(m.Changed,function() return true end,function() return not complete() end,${literal(step.timeout_seconds)},complete) end
assert(complete(),'PATH_FAILURE_CONSUMPTION_OUTCOME_UNPROVEN');local value={npcId=m:GetAttribute('NpcId'),records=http:JSONDecode(m.Value),outcome=${literal(step.outcome)}};m:Destroy()`);
        if(!pathSequence(value.records,value.npcId,step.outcome))throw new Error('PATH_SEQUENCE_INVALID');
      } else if(step.op==='parallel_prompt') {
        const actors=step.players.map(player=>players.get(String(player)));
        if(actors.some(actor=>!actor))throw new Error('CONTENTION_ACTOR_UNAVAILABLE');
        value=await parallelPrompt(step,actors,config.serverId,scenario.genre,execute,call);
      } else if(step.op==='rejoin') {
        if(typeof config.rejoin!=='function')throw new Error('physical rejoin unavailable: owned restart adapter required');
        if(config.capture) {
          const original=await config.capture.finalize('before-owned-rejoin');
          outcome.retiredAudiovisualEpochs??=[];
          outcome.retiredAudiovisualEpochs.push({runtime:outcome.runtime,original,registration:config.capture.actorSource});
          config.capture=undefined;
        }
        const oldRuntime=outcome.runtime;
        const oldProcess=config.processIdentity;
        const endedSeconds=(performance.now()-started)/1000;
        const replaced=await config.rejoin();
        transport=replaced.fresh.transport;
        config.serverId=replaced.admission.serverId;config.clients=replaced.admission.clients;
        // The genre server binds ForgeQA asynchronously while its boot scripts
        // run; wait for it before the replacement server's first QA probe.
        {
          const qaDeadline=Date.now()+180000;
          let qaReady=false;
          while(!qaReady) {
            const probe=await execute(config.serverId,'Server',`local rs=game:GetService('ReplicatedStorage');local sss=game:GetService('ServerScriptService');local ss=game:GetService('ServerStorage')
local value={qa=ss:FindFirstChild('ForgeQA')~=nil,players=#game:GetService('Players'):GetPlayers(),isStudio=game:GetService('RunService'):IsStudio(),placeId=game.PlaceId,rs={},sss={},ss={},ws={},logCount=0,errors={}}
for _,c in rs:GetChildren() do table.insert(value.rs,c.Name) end
for _,c in sss:GetChildren() do table.insert(value.sss,c.Name) end
for _,c in ss:GetChildren() do table.insert(value.ss,c.Name) end
for _,c in workspace:GetChildren() do table.insert(value.ws,c.Name) end
local ok,logs=pcall(function() return game:GetService('LogService'):GetLogOutput() end)
if ok and type(logs)=='table' then value.logCount=#logs;for _,line in logs do if string.find(line,'Error',1,true) then table.insert(value.errors,line) end end end
while #value.errors>8 do table.remove(value.errors,1) end`);
            if(probe && probe.qa){qaReady=true;break;}
            if(Date.now()>=qaDeadline)throw new Error(`FRESH_SERVER_FORGEQA_MISSING after 180s: ${JSON.stringify(probe)}`);
            await new Promise(resolve=>setTimeout(resolve,1000));
          }
        }
        for(const [index,player] of scenario.players.entries())players.set(String(player),config.clients[index]);
        client=players.get(String(step.player));
        installed.length=0;pathMarkers.length=0;
        devices.clear();results.clear();
        const runtime={server:null,clients:[]};
        for(const [id,model] of [[config.serverId,'Server'],...config.clients.map(actor=>[actor.studioId,'Client'])]) {
          let h;
          try {
            if(model==='Client') {
              let lastProbe=null;
              const lpDeadline=Date.now()+90000;
              for(;;) {
                lastProbe=await execute(id,'Client',`local plr=game:GetService('Players').LocalPlayer
local value={hasPlayer=plr~=nil,userId=plr and tostring(plr.UserId),others=#game:GetService('Players'):GetPlayers(),placeId=game.PlaceId}
if plr then
  local ps=plr:WaitForChild('PlayerScripts',5)
  local s=ps and ps:WaitForChild('ForgeBuildIdentity',5)
  local f=s and s:WaitForChild('Handshake',15)
  if f then value.handshake=f:Invoke() end
end`);
                if(lastProbe && lastProbe.handshake){ h=lastProbe.handshake; break; }
                if(Date.now()>=lpDeadline) throw new Error(`CLIENT_IDENTITY_TIMEOUT after 90s: ${JSON.stringify(lastProbe)}`);
                await new Promise(resolve=>setTimeout(resolve,2000));
              }
            } else {
              h = await execute(id,'Server',`local container=game:GetService('ServerScriptService');local s=container:WaitForChild('ForgeBuildIdentity',5);assert(s,'identity missing');local f=s:WaitForChild('Handshake',15);assert(f,'handshake missing');local value=f:Invoke()`);
            }
          } catch (error) {
            let diag='';
            try {
              const probe=await execute(config.serverId,'Server',`local ss=game:GetService('ServerStorage');local list={};for _,p in game:GetService('Players'):GetPlayers() do table.insert(list,tostring(p.UserId)) end;local value={players=list,lastKick=ss:GetAttribute('ForgeLastKick')}`);
              diag=` | server=${JSON.stringify(probe)}`;
            } catch (probeError) { diag=` | serverProbe=${probeError.message||probeError}`; }
            try {
              const state=await call('get_studio_state', { studio_id: id });
              const stext=(state.content||[]).filter(x=>x.type==='text').map(x=>x.text).join(' ');
              diag+=` | state=${stext.replace(/\s+/g,' ').slice(0,300)}`;
            } catch (stateError) { diag+=` | stateProbe=${stateError.message||stateError}`; }
            diag+=` | serverId=${config.serverId} configClients=${JSON.stringify((config.clients||[]).map(c=>`${c.studioId}:${c.userId}`))}`;
            try {
              const listing=jsonResult(await call('list_roblox_studios', {}));
              diag+=` | studios=${JSON.stringify((listing.studios||[]).map(s=>({id:s.id,name:s.name}))).slice(0,600)}`;
            } catch (listError) { diag+=` | studiosProbe=${listError.message||listError}`; }
            throw new Error(`REJOIN_IDENTITY_FETCH ${model}/${id}: ${(error&&error.message)||error}${diag}`);
          }
          if(h.schemaVersion!==1 || h.buildIdentity!==config.buildIdentity.id || h.role!==model.toLowerCase() || h.sessionId===oldRuntime.server.sessionId)throw new Error('REJOIN_LOADED_IDENTITY_MISMATCH');
          h.studio_id=id;
          if(model==='Server')runtime.server=h;
          else {
            if(h.sessionId!==runtime.server.sessionId || h.serverBuildIdentity!==config.buildIdentity.id || h.actorId!==config.clients.find(actor=>actor.studioId===id).userId)throw new Error('REJOIN_CLIENT_IDENTITY_MISMATCH');
            runtime.clients.push(h);
          }
        }
        const mappings=(runtime,process)=>runtime.clients.map(actor=>({actor:actor.actorId,studio_id:actor.studio_id,clientSessionId:actor.studio_id,processIdentity:`${process.pid}:${process.creationTime}`}));
        outcome.epochs??=[{epoch:1,runtime:oldRuntime,actorMappings:mappings(oldRuntime,oldProcess),clockAnchor,startedSeconds:0,endedSeconds}];
        outcome.epochs.at(-1).endedSeconds=endedSeconds;
        outcome.epochs.at(-1).backendObservation=replaced.before;
        outcome.epochs.at(-1).installation=replaced.oldInstallation;
        outcome.epochs.at(-1).hostReady=config.persistence.hostReady;
        config.processIdentity=replaced.admission.process;
        await prepareCapture(runtime);
        if(config.capture) {
          const before=(performance.now()-started)/1000;
          outcome.captureStart=await config.capture.start();
          outcome.captureStartBracket={before,after:(performance.now()-started)/1000};
        }
        const nextClock=await execute(config.serverId,'Server','local value={runtimeMillis=DateTime.now().UnixTimestampMillis}');
        clockAnchor={runtimeMillis:nextClock.runtimeMillis,elapsedSeconds:(performance.now()-started)/1000};
        const epoch=outcome.epochs.length+1;
        outcome.epochs.push({epoch,runtime,actorMappings:mappings(runtime,config.processIdentity),backendObservation:replaced.after,clockAnchor,installation:replaced.newInstallation,hostReady:config.persistence.hostReady,startedSeconds:(replaced.closedAt-started)/1000});
        outcome.transitions??=[];
        for(const actor of replaced.oldActors)outcome.transitions.push({fromEpoch:epoch-1,toEpoch:epoch,actor:actor.userId,oldClientSessionId:actor.studioId,newClientSessionId:config.clients.find(next=>next.userId===actor.userId).studioId,backendIdentity:replaced.after.identity,closedSeconds:(replaced.closedAt-started)/1000,closeEvidence:replaced.closeEvidence,loadEvidence:[]});
        // Durable loads only appear once the scenario's re-join steps run; the
        // proof is collected at scenario end, before writeRejoin.
        outcome.rejoinPending=replaced;
        outcome.runtime=runtime;
        value={epoch,physicalReplacement:true};
      } else if (step.op === 'walk_to' || step.op === 'activate_prompt') {
        let beforeGather,beforeNode,clientPrompt;
        // The prompt's parent decides the contract. A spec-node prompt sits directly on
        // its node part - the placement the world builder baked - while the survival
        // gather prompt hangs from a client-created Attachment under the node, so its
        // target chain only resolves in the acting actor's datamodel. Only the gather
        // path has a correlated relay and node charges to verify.
        let specNode=false;
        if(step.op==='activate_prompt') {
          const shape=await execute(client.studioId,'Client',`local target=game;for part in string.gmatch(${literal(step.target)},'[^.]+') do target=target:FindFirstChild(part);assert(target,'prompt target missing') end
assert(target:IsA('ProximityPrompt'),'prompt required');local value={specNode=target.Parent:IsA('BasePart')}`);
          specNode=shape.specNode===true;
        }
        // The gather path's node path is derived from the prompt's own target; a walk
        // that names a list of candidates has no single target, and neither the gather
        // snapshot nor the reach probe is on its path.
        const promptTarget=typeof step.target==='string'?step.target:null;
        const nodePath=promptTarget===null?null:promptTarget.split('.').slice(0, specNode ? -1 : -2).join('.');
        const promptSnapshot=()=>execute(client.studioId,'Client',`local target=game;for part in string.gmatch(${literal(step.target)},'[^.]+') do target=target:FindFirstChild(part);assert(target,'gather target missing') end
assert(target:IsA('ProximityPrompt'),'gather prompt required');local node=target.Parent.Parent
assert(node:GetAttribute('ForgeNodeId')==${literal(step.nodeId)},'gather node mismatch')
local value={promptId=node:GetAttribute('ForgeNodeId'),promptAction=target.ActionText}`);
        const nodeSnapshot=()=>execute(config.serverId,'Server',`local target=game;for part in string.gmatch(${literal(nodePath)},'[^.]+') do target=target:FindFirstChild(part);assert(target,'gather node missing') end
local value={nodeId=target:GetAttribute('ForgeNodeId'),version=target:GetAttribute('ForgeNodeVersion'),charges=target:GetAttribute('ForgeNodeCount'),depleted=target:GetAttribute('ForgeNodeDepleted')}`);
        if(step.op==='activate_prompt'&&!specNode)beforeNode=await nodeSnapshot();
        if(step.op==='activate_prompt'&&!specNode)clientPrompt=await promptSnapshot();
        if(step.op==='activate_prompt') beforeGather=await execute(config.serverId,'Server',`local value=game:GetService('ServerStorage').ForgeQA.snapshot:Invoke(${literal(scenario.genre)},${literal(client.userId)})`);
        const reachProbe=async () => {
          try {
            const server=await execute(config.serverId,'Server',`local actor=game:GetService('Players'):GetPlayerByUserId(${literal(Number(client.userId))})
local root=actor and actor.Character and actor.Character:FindFirstChild('HumanoidRootPart')
local target=game;for part in string.gmatch(${literal(nodePath)},'[^.]+') do target=target:FindFirstChild(part) end
local value={nodeFound=target~=nil,hasRoot=root~=nil}
if root and target then value.distance=(target.Position-root.Position).Magnitude end
if root and target then local params=RaycastParams.new();params.FilterType=Enum.RaycastFilterType.Exclude;params.FilterDescendantsInstances={actor.Character};params.RespectCanCollide=true
local hit=workspace:Raycast(root.Position,target.Position-root.Position,params);local hitNode=hit and (hit.Instance==target or hit.Instance:IsDescendantOf(target)) or false;value.hitNode=hitNode
-- Hitting the node itself is reachability, not blockage; reporting it as blocked inverted the meaning.
value.blocked=(hit and not hitNode) and hit.Instance:GetFullName() or false end`);
            return JSON.stringify(server);
          } catch(error) {
            // Only what this probe measured is reported. The previous form also probed a hardcoded
            // harness HTTP endpoint unrelated to the gather step, so its ConnectFail could be read as
            // the cause of the action failure.
            return 'reach probe failed: '+String(error && error.message); }
        };
        try {
          value=await gameplay(step,client,execute,call);
        } catch(error) {
          if(step.op==='activate_prompt') throw new Error(String(error && error.message)+' | serverReach='+(await reachProbe()));
          throw error;
        }
        if(step.op==='activate_prompt' && !specNode && value && typeof value==='object') value.clientPrompt=clientPrompt;
        if(step.op==='walk_to') {
          // The walk's own evidence carries the target it resolved: a step may name
          // several candidates and the client walks to the nearest, so the server
          // reach check measures the instance the actor actually walked to.
          const resolvedTarget=typeof value?.arrival?.target==='string'?value.arrival.target:step.target;
          const spatial=await execute(config.serverId,'Server',`local actor=game:GetService('Players'):GetPlayerByUserId(${literal(Number(client.userId))});assert(actor and actor.Character,'server character missing')
local target=game;for name in string.gmatch(${literal(resolvedTarget)},'[^.]+') do if name~='game' then target=target:FindFirstChild(name);assert(target,'server target missing')end end
local function ready()local root=actor.Character:FindFirstChild('HumanoidRootPart');local delta=root and root.Position-target.Position;return delta and Vector3.new(delta.X,0,delta.Z).Magnitude<=${literal(step.withinStuds)} and ${step.verticalToleranceStuds===undefined?'true':`math.abs(delta.Y)<=${literal(step.verticalToleranceStuds)}`} end
if not ready()then
local thread=coroutine.running();local done=false;local connection
connection=game:GetService('RunService').Heartbeat:Connect(function()if ready() and not done then done=true;connection:Disconnect();task.spawn(thread)end end)
task.delay(5,function()if not done then done=true;connection:Disconnect();task.spawn(thread)end end);coroutine.yield();connection:Disconnect()
end
assert(ready(),'movement not replicated inside server reach');local value={serverDistance=(actor.Character.HumanoidRootPart.Position-target.Position).Magnitude}`);
          value.serverSpatial=spatial;
        }
        if(step.op==='activate_prompt') {
          const afterGather=await execute(config.serverId,'Server',`local value=game:GetService('ServerStorage').ForgeQA.snapshot:Invoke(${literal(scenario.genre)},${literal(client.userId)})`);
          const ordered=items=>Array.isArray(items)?items.map(ordered):items&&typeof items==='object'?Object.fromEntries(Object.keys(items).sort().map(key=>[key,ordered(items[key])])):items;
          if(specNode) {
            // A spec node drives whatever action its control names, so its contract is
            // the committed snapshot change the server published - not a gather
            // inventory gain, which only the survival gather has.
            const changed=JSON.stringify(ordered(beforeGather))!==JSON.stringify(ordered(afterGather));
            if(step.expect==='refused') { if(changed) throw new Error('refused prompt changed the genre snapshot'); }
            else {
              if(!changed) throw new Error('prompt result has no committed snapshot change');
              // The player-facing world path must be activated by real key input on a prompt the
              // engine actually showed the player. The prompt-hold API is a labelled diagnostic
              // and a hidden or irrelevant prompt cannot satisfy this gate.
              if(value.activation!=='key') throw new Error('world-path prompt was not activated by real key input: '+String(value.activation));
              // A key press can only trigger the prompt the engine currently considers active, so the
              // engine's own PromptTriggered (or PromptShown) for the target is the relevance proof. The
              // API hold fallback bypasses that test and is refused above; a hidden or irrelevant prompt
              // never produces either signal.
              if(value.engineTriggered!==true && value.engineShown!==true) throw new Error('world-path prompt was never shown to the player by the engine');
            }
            value.persistedBefore=beforeGather;value.persistedAfter=afterGather;
          } else {
          const beforeItems=beforeGather?.inventory?.bag?.items,afterItems=afterGather?.inventory?.bag?.items;
          if(!beforeItems || !afterItems) throw new Error('gather inventory unavailable');
          if(step.expect==='refused') {
            if(JSON.stringify(ordered(beforeItems))!==JSON.stringify(ordered(afterItems)))throw new Error('refused gather changed inventory');
            const afterNode=await nodeSnapshot();
            if(!Number.isFinite(beforeNode.version)||!Number.isFinite(beforeNode.charges)||JSON.stringify(ordered(beforeNode))!==JSON.stringify(ordered(afterNode)))throw new Error('refused gather changed authoritative node');
            value.nodeBefore=beforeNode;value.nodeAfter=afterNode;
          } else if(!Object.entries(afterItems).some(([key,item])=>item.quantity>(beforeItems[key]?.quantity || 0))) throw new Error('gather result has no persisted inventory gain');
          value.persistedBefore=beforeGather;value.persistedAfter=afterGather;
          }
          results.set(String(step.player),value.result);
        }
      } else if(step.op==='bind_result' || step.op==='bind_snapshot') {
        value=step.op==='bind_result'?results.get(String(step.player)):await execute(config.serverId,'Server',sharedSnapshot(scenario.genre,client.userId,step.field));
        for(const field of Array.isArray(step.field)?step.field:step.field.split('.')) value=value?.[field];
        if(step.select) {
          // Starter grants and gathered output are separate stacks with the same
          // catalogId, so a select is a list of conditions that must all hold; object
          // values (stack attributes) compare by JSON structure, primitives by value.
          const conditions=Array.isArray(step.select)?step.select:[step.select];
          const matchesCondition=(item,condition)=>{
            const actual=item?.[condition.field];
            if(condition.empty===true) {
              if(Array.isArray(actual)) return actual.length===0;
              return actual!==null && typeof actual==='object' && Object.keys(actual).length===0;
            }
            if(condition.equals!==null && typeof condition.equals==='object') return JSON.stringify(actual)===JSON.stringify(condition.equals);
            return actual===condition.equals;
          };
          const matches=Object.entries(value || {}).filter(([,item])=>conditions.every(condition=>matchesCondition(item,condition)));
          if(matches.length!==1) throw new Error('snapshot selector requires exactly one matching key; select='+JSON.stringify(step.select)+' matches='+JSON.stringify(matches.map(([key])=>key))+' items='+JSON.stringify(value).slice(0,1200));
          value=matches[0][0];
        }
        if(value===undefined || value===null || !['string','number','boolean'].includes(typeof value)) throw new Error('binding must extract existing scalar result');
        if(bindings.has(step.label)) throw new Error('duplicate binding');
        bindings.set(step.label,value);
      } else if(step.op==='server_command') {
        // Lune YAML coerces numeric-looking UserIds even when quoted.
        if(step.action==='survival-coop:settlement-invite' && typeof step.args?.[0]==='number') step.args[0]=String(step.args[0]);
        value=await execute(config.serverId,'Server',`local qa=game:GetService('ServerStorage').ForgeQA;local fn=qa:FindFirstChild('commandServer');assert(fn and fn:IsA('BindableFunction'),'commandServer missing')
local result,revision=observe(qa.StateChanged.Event,function() return fn:Invoke(${literal(client.userId)},${literal(step.requestId)},${literal(step.action)},${literal(step.args || [])}) end,function(r) return r.ok end)
local value={result=result,revision=revision}`);
        results.set(String(step.player),value.result);
        if(step.expect && value.result.ok!==(step.expect==='ok')) throw new Error(`unexpected server command result: ${JSON.stringify(value.result)}`);
      } else if (step.op === 'join') {
        // Membership lands asynchronously after a physical replacement (profile
        // loads); retry the readiness probe instead of a single 5s shot.
        const joinDeadline = Date.now() + 90000;
        let joinError = null;
        for (;;) {
          try {
            value = await execute(client.studioId, 'Client', `local rs=game:GetService('ReplicatedStorage');local event=rs:FindFirstChild('ForgeState');assert(event,'ForgeState missing')
local result,received=observe(event.OnClientEvent,function() return rs:FindFirstChild('ForgeAction'):InvokeServer() end,function(r) return r.ok end)
assert(result.ok,'profile not ready: '..tostring(result.reason));local value=received`);
            joinError = null;
            break;
          } catch (error) {
            joinError = error;
            if (Date.now() >= joinDeadline) break;
            await new Promise(resolve => setTimeout(resolve, 2000));
          }
        }
        if (joinError) {
          let serverState = 'probe-failed';
          try {
            serverState = await execute(config.serverId, 'Server', `local players=game:GetService('Players');local list={};for _,p in players:GetPlayers() do table.insert(list,tostring(p.UserId)) end;local value={list=list}`);
          } catch (probeError) {
            serverState = String(probeError.message || probeError);
          }
          throw new Error(`join retry exhausted after 90s: ${joinError.message} | server=${JSON.stringify(serverState)}`);
        }
      } else if (step.op === 'dispatch' || step.op === 'command') {
        const conserved=async()=>execute(config.serverId,'Server',`local qa=game:GetService('ServerStorage').ForgeQA;local snapshot=qa.snapshot:Invoke(${literal(scenario.genre)},${literal(client.userId)})
local npc=workspace.ForgeWildlife:FindFirstChild(${literal(step.args?.[0])});assert(npc,'conservation target missing');local value={inventory=snapshot.inventory,healthMilli=npc:GetAttribute('ForgeWildlifeHealthMilli')}`);
        const before=step.conserveAttack?await conserved():null;
        value = await execute(client.studioId, 'Client', `local rs=game:GetService('ReplicatedStorage');local step=${literal(step)}
local function action()
 if step.op=='command' then
  local epoch=step.sessionEpoch
  if epoch=='current' then local ready=rs.ForgeAction:InvokeServer();assert(ready.ok);epoch=ready.durable.epochs[step.action] end
  return rs.ForgeAction:InvokeServer('command',{requestId=step.requestId,sessionEpoch=epoch,action=step.action,args=step.args or {}})
 end
 return rs.ForgeAction:InvokeServer(step.action,step.args or {})
end
local result,received=observe(rs.ForgeState.OnClientEvent,function() local r;for _=1,(step.times or 1) do r=action() end;return r end,function(r) return r.ok end)
local value={result=result,revision=received and received.revision}`);
        results.set(String(step.player), value.result);
        if(step.conserveAttack) {const after=await conserved();conservation(before,after);value.conservation={before,after};}
        if (step.expect && value.result.ok !== (step.expect === 'ok')) throw new Error(`step ${index + 1}: unexpected dispatch result`);
      } else if (step.op === 'expect_snapshot') {
        value = await execute(config.serverId, 'Server', sharedSnapshot(step.genre, client.userId, step.field));
      } else if (step.op === 'expect_result') value = results.get(String(step.player));
      else if (step.op === 'expect_members') {
        value = await execute(config.serverId, 'Server', `local value={};for _,p in game:GetService('Players'):GetPlayers() do table.insert(value,tostring(p.UserId)) end;table.sort(value)`);
        const expected = step.members.map(player => players.get(String(player)).userId).sort();
        if (JSON.stringify(value) !== JSON.stringify(expected)) throw new Error(`step ${index + 1}: members differ`);
      } else if (step.op === 'capture') {
        const layers=layersOf(step);
        for(let angle=0;angle<(step.angles || 1);angle++) {
        if(angle>0) for(const captureClient of config.clients) {
          for(let turn=0;turn<2;turn++) await turnCamera(captureClient,execute,call);
        }
        for (const captureClient of config.clients) {
          const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonical(value[k])])):value;
          const owned=value=>canonical({criticalUI:value.criticalUI,chat:value.chat});
          // `settle: true` waits, bounded, for the owned UI to stop changing before the screenshot.
          // The step before a capture is often what changes the HUD (an equipping prompt creates a
          // cell), and the state packet that carries it lands a frame or two later; without this the
          // strict before/after comparison below would report a change the capture never showed.
          let geometry=await captureGeometry(captureClient,execute);
          if(step.settle===true) {
            // Require a SUSTAINED quiet window, not just one agreeing pair: a state packet lands a
            // frame or two after the action, so two consecutive samples can agree and still be
            // followed by the render. Three agreeing samples at 400ms spacing is ~0.8s of quiet.
            let agreeing=0;
            for(let attempt=0;attempt<24;attempt++) {
              const again=await captureGeometry(captureClient,execute);
              agreeing = JSON.stringify(owned(geometry))===JSON.stringify(owned(again)) ? agreeing+1 : 0;
              geometry=again;
              if(agreeing>=3) break;
              await new Promise(resolve=>setTimeout(resolve,400));
            }
          }
          validateGeometry(geometry,devices.get(captureClient.studioId));
          // Only the screenshot runs with a layer hidden: the geometry samples around it measure the
          // owned UI and must see it exactly as the player does.
          const response = await withLayers(layers, captureClient, execute, () => call('screen_capture', { studio_id: captureClient.studioId, capture_id: `ForgeQA_${index + 1}_${config.clients.indexOf(captureClient) + 1}` }));
          const image = response.content?.find(item => item.type === 'image' && item.data);
          if (!image) throw new Error('screen_capture returned no image bytes');
          const bytes = Buffer.from(image.data, 'base64');
          if (bytes.length < 32) throw new Error('screen_capture returned empty image');
          const path = await artifactWriter(`capture-${index + 1}-${config.clients.indexOf(captureClient) + 1}-${angle}.${image.mimeType === 'image/png' ? 'png' : image.mimeType === 'image/jpeg' ? 'jpg' : 'bin'}`, bytes);
          const decoded=decodeRasterLuma(bytes);
          const raster={format:decoded.format,width:decoded.width,height:decoded.height};
          if(image.mimeType!==`image/${raster.format}`)throw new Error('CAPTURE_MIME_MISMATCH');
          const after=await captureGeometry(captureClient,execute);
          validateGeometry(after,devices.get(captureClient.studioId));
          // Compare the OWNED UI and the reserved chat region across the two samples: those are what a
          // capture's evidence is about. `device`/`logical` are validated on each sample independently
          // by validateGeometry, and re-sampling them adds nothing. A pair that disagrees fails closed.
          if(JSON.stringify(owned(geometry))!==JSON.stringify(owned(after))){
            const beforeMap=new Map((geometry.criticalUI||[]).map(c=>[c.id,JSON.stringify(c)]));
            const nowMap=new Map((after.criticalUI||[]).map(c=>[c.id,JSON.stringify(c)]));
            const moved=[];
            for(const [id,entry] of beforeMap) if(nowMap.get(id)!==entry) moved.push(id+' was='+entry+' now='+(nowMap.get(id)||'absent'));
            for(const [id,entry] of nowMap) if(!beforeMap.has(id)) moved.push(id+' appeared='+entry);
            const chatMoved=JSON.stringify(geometry.chat)!==JSON.stringify(after.chat);
            throw new Error('CAPTURE_GEOMETRY_CHANGED controls='+JSON.stringify(moved.slice(0,6))+(chatMoved?' chat='+JSON.stringify(geometry.chat)+'->'+JSON.stringify(after.chat):''));
          }
          // The pixels the HUD does not own must show a world. Geometry gates cannot see a
          // place that rendered as a flat white screen; this one measures the frame itself.
          const contentScaleX=raster.width/geometry.logical.full.width,contentScaleY=raster.height/geometry.logical.full.height;
          const excluded=geometry.criticalUI.map(rect=>({x:rect.x*contentScaleX,y:rect.y*contentScaleY,width:rect.width*contentScaleX,height:rect.height*contentScaleY}));
          if(geometry.chat)excluded.push({x:geometry.chat.x*contentScaleX,y:geometry.chat.y*contentScaleY,width:geometry.chat.width*contentScaleX,height:geometry.chat.height*contentScaleY});
          // A frame with the world hidden is flat by construction, so the world-content gate cannot
          // judge it and must not fail it; the record says why instead of claiming a verdict.
          const visualContent=layers==='ui'?{verdict:'not-applicable',reason:'world layer hidden'}:assertVisualContent({luma:decoded.luma,excludeRects:excluded,label:path});
          // A skipped visual-content verdict means the HUD covered nearly the whole frame, so
          // the world region could not be judged. That is not evidence the world rendered: it is
          // recorded as inconclusive and carried on the run, so a consumer cannot read it as a
          // green visual pass.
          if(visualContent.verdict==='inconclusive' || visualContent.verdict==='skipped') {
            outcome.inconclusive ??= [];
            outcome.inconclusive.push({step:index+1,studio_id:captureClient.studioId,actor:captureClient.userId,reason:visualContent.reason||'visual content not judgeable'});
          }
          const logicalToRaster={origin:'full-screen',scaleX:raster.width/geometry.logical.full.width,scaleY:raster.height/geometry.logical.full.height,offsetX:0,offsetY:0};
          outcome.captures.push({ schemaVersion:2,originalValidated:true,layers,epoch:outcome.epochs?.length || 1,sessionId:outcome.runtime.server.sessionId,buildIdentity:config.buildIdentity.id,...geometry,raster,visualContent:{...visualContent,verdict:visualContent.verdict==='skipped'?'inconclusive':visualContent.verdict},logicalToRaster,studio_id: captureClient.studioId, actor:captureClient.userId, target: step.target, path, sha256: hash(bytes),step:index+1,elapsedSeconds:(performance.now()-started)/1000 });
        }
        }
      } else {
        const operation = { advance_to: 'advanceTo', advance_elapsed: 'advanceElapsed', begin_clock: 'beginClock', save: 'save', restore: 'restore' }[step.op];
        const args = step.op === 'save' ? [client.userId] : step.op === 'restore' ? [client.userId, saves.get(step.from)] : step.op === 'begin_clock' ? [] : [step.seconds];
        if (step.op === 'restore' && args[1] === undefined) throw new Error('restore references missing save');
        value = await execute(config.serverId, 'Server', `local qa=game:GetService('ServerStorage').ForgeQA
local result,observed,saved=observe(qa.StateChanged.Event,function() return qa[${literal(operation)}]:Invoke(table.unpack(${literal(args)})) end,function(r) return ${literal(['advance_to', 'advance_elapsed', 'restore'].includes(step.op))} and (type(r)~='table' or r.ok) end)
local value={result=result,saved=saved,revision=observed}`);
        if (step.op === 'save') { if (!value.result.ok || !value.saved) throw new Error('save failed'); saves.set(step.label || String(step.player), value.saved); }
        if (step.op === 'restore' && !value.result.ok) throw new Error('restore failed');
      }
      if (step.op === 'expect_snapshot' || step.op === 'expect_result') {
        let actual = value;
        for (const field of Array.isArray(step.field)?step.field:step.field.split('.')) actual = actual?.[field];
        if (!compare(actual, step)) throw new Error(`step ${index + 1}: ${step.field} assertion failed: ${JSON.stringify(actual)}`);
      }
      const actor=client || config.clients[0];
      outcome.steps.push({ index: index + 1, epoch:outcome.epochs?.length || 1, op: step.op, value, actor:actor.userId,studio_id:actor.studioId,sessionId:outcome.runtime.server.sessionId,revisionBefore,revisionAfter:await revision(),shortcut:['advance_to','advance_elapsed','begin_clock','restore','server_command','dispatch','command','obstacle'].includes(step.op),startedSeconds,elapsedSeconds:(performance.now()-started)/1000 });
    }
    stepLabel='post-steps';
    if (outcome.captures.length < config.clients.length) throw new Error('two-client captures missing');
    if(config.capture) {
      const before=(performance.now()-started)/1000;
      outcome.audiovisualCapture=await config.capture.finalize('scenario-complete');
      outcome.captureEndBracket={before,after:(performance.now()-started)/1000};
    }
    outcome.actionEvidence=await artifactWriter('actions.json',Buffer.from(JSON.stringify({runtime:outcome.runtime,clients:outcome.clients,steps:outcome.steps})));
    outcome.ok = true;
    if(outcome.epochs) {
      outcome.epochs.at(-1).endedSeconds=(performance.now()-started)/1000;
      if(outcome.rejoinPending) {
        const pending=outcome.rejoinPending;
        delete outcome.rejoinPending;
        const observed=await pending.fresh.session.observeRejoinLoads(pending.before,pending.oldActors,pending.admission.serverId,config.persistence?.instanceId);
        outcome.epochs.at(-1).backendObservation=observed.after;
        for(const transition of outcome.transitions||[]) transition.loadEvidence=observed.loads;
      }
      outcome.rejoinEvidence=await writeRejoin(outcome,config.buildIdentity.id,artifactWriter);
    }
  } catch (error) { outcome.ok=false;outcome.blockers.push(String(error.message || error));delete outcome.rejoinPending;if(error.registrationFailure)outcome.registrationFailure=error.registrationFailure;if(error.wildlifeTrace)outcome.wildlifeDiagnosis=error.wildlifeTrace; }
  finally {
    // Cleanup gets its own bounded budget after the scenario deadline.
    transport.deadline = Date.now() + 10000;
    for(const marker of pathMarkers) {
      try { await transport.call('execute_luau',{studio_id:config.serverId,datamodel_type:'Server',code:`local m=game:GetService('ServerStorage'):FindFirstChild(${literal(marker)});if m then m:Destroy() end`}); }
      catch { outcome.ok=false;outcome.blockers.push('PATH_SUBSCRIPTION_CLEANUP_UNRESOLVED'); }
    }
    if(outcome.steps.some(step=>step.op==='motion_begin')) {
      // Retain the trace instead of destroying it unread: when a step cannot proceed, the samples are
      // the only record of where every NPC and actor actually was, and telling a static obstruction
      // apart from the pursuer is exactly what a stall diagnosis needs. The read is bounded and the
      // same call still destroys the folder.
      try {
        // The failure text carries only the essentials; the sample window is read back here, which is
        // also what destroys the folder a failed motion_end retained for this read.
        const trace=await execute(config.serverId,'Server',wildlifeTraceCode());
        if(trace?.present===true) outcome.wildlifeTrace=retainWildlifeTrace(trace);
      }
      catch(error){outcome.ok=false;outcome.blockers.push(`wildlife trace cleanup: ${error.message}`);}
    }
    for (const client of installed) {
      try {
        const result = await transport.call('execute_luau', { studio_id: client.studioId, datamodel_type: 'Client', code: "local p=game:GetService('Players').LocalPlayer;local m=p:FindFirstChild('ForgeQAInputProof');if m then m:Destroy() end;local motion=p:FindFirstChild('ForgeQAMotion');if motion then motion:Destroy() end\n"+restoreDeviceCode });
        outcome.cleanup.push({ studio_id: client.studioId, sha256: hash(JSON.stringify(result)) });
      } catch (error) { outcome.ok = false; outcome.blockers.push(`cleanup: ${error.message}`); }
    }
    if(outcome.steps.some(step=>step.op==='obstacle')) {
      try {await transport.call('execute_luau',{studio_id:config.serverId,datamodel_type:'Server',code:"local wall=workspace:FindFirstChild('ForgeQAObstacle');if wall then wall:Destroy() end"});}
      catch(error){outcome.ok=false;outcome.blockers.push(`obstacle cleanup: ${error.message}`);}
    }
  }
  outcome.runSha256=runDigest(outcome);
  if(config.capture && outcome.ok) {
    try {
      const finalized=outcome.audiovisualCapture;
      const source=config.capture.actorSource;
      const nativeClock=finalized.clock || finalized.clockAnchor;
      const frequency=Number(nativeClock.qpcFrequency), qpcStart=Number(nativeClock.qpcStart), qpcEnd=Number(nativeClock.qpcEnd);
      if(!Number.isSafeInteger(frequency) || frequency<=0 || !Number.isSafeInteger(qpcStart) || !Number.isSafeInteger(qpcEnd) || qpcEnd<=qpcStart)throw new Error('CAPTURE_FINAL_CLOCK_UNPROVEN');
      const first=outcome.captureStartBracket,last=outcome.captureEndBracket;
      const a=(first.before+first.after)/2,b=(last.before+last.after)/2, duration=(qpcEnd-qpcStart)/frequency;
      const uncertainty=Math.max(first.after-first.before,last.after-last.before)/2;
      const policy=config.capturePolicy;
      if(!policy || !Array.isArray(policy.intervals) || uncertainty>policy.maxClockErrorSeconds)throw new Error('CAPTURE_CLOCK_POLICY_UNPROVEN');
      const clock={offsetSeconds:a,rate:(b-a)/duration,uncertaintySeconds:uncertainty,driftSeconds:Math.abs((b-a)-duration),anchors:[{ptsSeconds:0,actionSeconds:a},{ptsSeconds:duration,actionSeconds:b}]};
      const loaded=outcome.runtime.clients.find(client=>client.actorId===source.actorId && client.studio_id===source.studioId);
      if(!loaded || source.sessionId!==loaded.sessionId || source.buildIdentity!==config.buildIdentity.id)throw new Error('SOURCE_ACTOR_PROCESS_UNPROVEN');
      const receipt=buildSourceReceipt({handle:config.capture,finalized,expected:{sessionId:loaded.sessionId,actorId:source.actorId,studioId:source.studioId,buildIdentity:config.buildIdentity.id,runSha256:outcome.runSha256,processIdentity:source.processIdentity,clock},policy});
      // Mirrors qualityreceipt canonical: numeric/string key types remain distinct.
      const canonical=value=>{
        if(value===null || typeof value!=='object')return JSON.stringify(value);
        const entries=Array.isArray(value)?value.map((v,i)=>[i+1,v]):Object.entries(value);
        entries.sort(([a],[b])=>{const x=typeof a+String(a),y=typeof b+String(b);return x<y?-1:x>y?1:0;});
        return '{'+entries.map(([k,v])=>canonical(k)+':'+canonical(v)).join(',')+'}';
      };
      receipt.policyDigest='sha256:'+hash(canonical(policy));
      receipt.coveragePolicySha256=hash(JSON.stringify(policy));
      receipt.registrationEvidence=source.registrationEvidence;
      receipt.registrationCompletedQpc=source.registrationCompletedQpc;
      receipt.captureStartQpc=String(qpcStart);
      if(String(frequency)!==source.registrationFrequency || BigInt(receipt.captureStartQpc)<=BigInt(source.registrationCompletedQpc))throw new Error('REGISTRATION_CAPTURE_CLOCK_ORDER');
      receipt.clockEvidence={native:nativeClock,startBracket:first,endBracket:last};
      const originalPath=relative(process.cwd(),finalized.originalPath).replaceAll('\\','/');
      if(isAbsolute(originalPath) || originalPath.startsWith('../'))throw new Error('CAPTURE_ORIGINAL_OUTSIDE_ROOT');
      receipt.original.path=originalPath;
      outcome.audiovisualSourceReceipt=await artifactWriter('av-source.json',Buffer.from(JSON.stringify(receipt)));
      outcome.audiovisualSources={};
      for(const path of Object.keys(scenario.audiovisualSources))outcome.audiovisualSources[path]='sha256:'+hash(canonical(receipt));
      outcome.audiovisualArtifacts=[originalPath,outcome.audiovisualSourceReceipt,...source.registrationArtifacts];
    } catch(error) {outcome.ok=false;outcome.blockers.push(error.message);}
  }
  return outcome;
}

if (import.meta.main) {
  let transport;
  let output;
  const lifecycle = new StudioLifecycle();
  const cancel = () => { lifecycle.fail('cancel', 'CANCELLED'); void transport?.close(); };
  process.once('SIGINT', cancel);
  process.once('SIGTERM', cancel);
  try {
    let input;
    if(process.argv[2]==='--input' || process.argv[2]==='--attach-supplement') input=JSON.parse(await Bun.file(process.argv[3]).text());
    else {
      const chunks = [];
      for await (const chunk of process.stdin) chunks.push(Buffer.from(chunk));
      input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    }
    if(process.argv[2]==='--attach-supplement') {
      const document=input.document;
      if(document?.mode!=='studio' || !document.outcome) throw new Error('existing Studio evidence document required');
      const outcome=await attachSupplement(document.outcome,input.supplement,async path=>{
        if(typeof path!=='string' || path.includes('..') || /^[\\/]|^[A-Za-z]:/.test(path)) throw new Error('relative artifact path required');
        return new Uint8Array(await Bun.file(path).arrayBuffer());
      });
      output = {...document,outcome};
    } else {
    const config = input.config;
    // Lune's JSON encoder cannot express an empty array, so an authored `args: []`
    // reaches this driver as `{}`. Accept only that exact ambiguity; a non-empty
    // object or any other shape is still refused.
    const commandArgs = Array.isArray(config.args)
      ? config.args
      : (config.args && typeof config.args === 'object' && Object.keys(config.args).length === 0 ? [] : null);
    if (typeof config.command !== 'string' || commandArgs === null) throw new Error('driver command and args required');
    transport = new StdioMcp(config.command, commandArgs, input.scenario.timeout_seconds * 1000, lifecycle);
    await transport.initialize();
    output = await runOwnedStudio(input.scenario, config, transport, lifecycle, async (name, bytes) => {
      await mkdir(config.artifactDirectory, { recursive: true });
      const path = `${config.artifactDirectory}/${name}`;
      await writeFile(path, bytes);
      return path;
    });
    }
  } catch (error) {
    lifecycle.fail('driver', 'DRIVER_FAILED');
  console.error('DRIVER_ERROR:', (error && (error.stack || error.message)) || String(error));
    output = { ok: false, kind: 'studio', blockers: [error.message === 'driver command and args required' ? error.message : 'STUDIO_DRIVER_FAILED'] };
  } finally {
    const cleanup = await lifecycle.close();
    process.removeListener('SIGINT', cancel);
    process.removeListener('SIGTERM', cancel);
    output ??= { ok: false, kind: 'studio', blockers: ['CANCELLED'] };
    const outcome = output.outcome || output;
    outcome.lifecycle = cleanup;
    if (!cleanup.ok) {
      outcome.ok = false;
      outcome.blockers ??= [];
      if (cleanup.residuals.length) outcome.blockers.push('OWNED_RESOURCE_UNRESOLVED');
    }
    process.exitCode = outcome.ok === true ? 0 : 1;
    if (!output.outcome) outcome.discovery = observedDiscovery(outcome);
    console.log(JSON.stringify(output));
  }
}
