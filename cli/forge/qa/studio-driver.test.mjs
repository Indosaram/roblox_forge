import { test, expect } from 'bun:test';
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { StdioMcp, runStudio, runOwnedStudio, pathSequence, observedDiscovery } from './studio-driver.mjs';
import { StudioLifecycle } from './studio-driver-lifecycle.mjs';

test('path evidence requires ordered matching request failure consumption and outcome', () => {
  const phases=['requested','result','consumed','recovered'];
  const records=phases.map((phase,index)=>({npcId:'npc',serial:4,phase,atMillis:index,status:index===0?'Pending':index===3?'Success':'NoPath'}));
  const observed=[];
  for(const record of records) {
    observed.push(record);
    expect(pathSequence(observed,'npc','recovered')).toBe(observed.length===4);
  }
  expect(pathSequence(records.slice(1),'npc','recovered')).toBe(false);
  expect(pathSequence([records[0],records[2],records[1],records[3]],'npc','recovered')).toBe(false);
  expect(pathSequence(records.map((row,index)=>index===2?{...row,serial:5}:row),'npc','recovered')).toBe(false);
  expect(pathSequence(records.map((row,index)=>index===2?{...row,npcId:'other'}:row),'npc','recovered')).toBe(false);
});
import { decodeRaster, validateGeometry, captureGeometry } from './studio-driver-surface.mjs';
import { deflateSync } from 'node:zlib';

// Genuine deterministic encoded images, not a header-only fake, and a VARIED
// field rather than a flat one: the capture path now refuses a structure-free
// world region (see studio-driver-content.mjs), so a fixture must be a frame a
// rendered scene could produce. JPEG is a baseline one-component image whose
// per-block DC term follows a smooth gradient and whose blocks each carry four
// nonzero AC coefficients, so the detail grid the gate measures is populated.
function jpeg(width,height) {
  const segment=(tag,data)=>Buffer.concat([Buffer.from([255,tag,(data.length+2)>>8,(data.length+2)&255]),Buffer.from(data)]);
  const cols=Math.ceil(width/8),rows=Math.ceil(height/8);
  const bits=[];const push=(value,count)=>{for(let i=count-1;i>=0;i--)bits.push((value>>i)&1);};
  let previous=0;
  for(let row=0;row<rows;row++)for(let col=0;col<cols;col++){
    // The block's average luminance (pred/8 + 128) sweeps a wide range, so the
    // decoded grid has a real spread instead of one flat value.
    const average=Math.round(128+100*Math.sin(col/3)+20*Math.cos(row/5));
    const target=(Math.max(10,Math.min(245,average))-128)*8;
    const diff=target-previous;previous=target;
    const magnitude=Math.abs(diff),size=magnitude===0?0:Math.floor(Math.log2(magnitude))+1;
    push(size,4);                                   // DC Huffman code for category `size`
    if(size>0)push(diff<0?diff+(1<<size)-1:diff,size);
    // Four nonzero AC coefficients, then end-of-block. Codes: 2-bit 00->size1,
    // 01->size2; 3-bit 100->size3, 101->EOB. The table never fills a code length
    // completely, which the decoder refuses.
    push(0b00,2);push(1,1);   // run0/size1
    push(0b01,2);push(1,2);   // run0/size2
    push(0b00,2);push(0,1);   // run0/size1
    push(0b100,3);push(3,3);  // run0/size3
    push(0b101,3);            // end-of-block
  }
  while(bits.length%8!==0)bits.push(1);            // JPEG pads the last byte with 1s
  const entropy=[];for(let i=0;i<bits.length;i+=8){const byte=parseInt(bits.slice(i,i+8).join(''),2);entropy.push(byte);if(byte===255)entropy.push(0);}
  const dcCounts=[0,0,0,12,0,0,0,0,0,0,0,0,0,0,0,0];  // twelve 4-bit codes: categories 0..11
  const dcSymbols=[0,1,2,3,4,5,6,7,8,9,10,11];
  const acCounts=[0,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0];  // two 2-bit and two 3-bit codes
  const acSymbols=[0x01,0x02,0x03,0x00];             // 00->size1, 01->size2, 100->size3, 101->EOB
  return Buffer.concat([Buffer.from([255,216]),segment(219,[0,...Array(64).fill(1)]),segment(192,[8,height>>8,height&255,width>>8,width&255,1,1,17,0]),segment(196,[0,...dcCounts,...dcSymbols,16,...acCounts,...acSymbols]),segment(218,[1,1,0,0,63,0]),Buffer.from(entropy),Buffer.from([255,217])]);
}
function png(width,height) {
  const chunk=(kind,data)=>{const body=Buffer.concat([Buffer.from(kind),data]);let crc=0xffffffff;for(const b of body){crc^=b;for(let k=0;k<8;k++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}const header=Buffer.alloc(4),tail=Buffer.alloc(4);header.writeUInt32BE(data.length);tail.writeUInt32BE((crc^0xffffffff)>>>0);return Buffer.concat([header,body,tail]);};
  const header=Buffer.alloc(13);header.writeUInt32BE(width);header.writeUInt32BE(height,4);header[8]=8;header[9]=2;
  // A varied RGB field, so the world region is a frame rather than one colour.
  const raw=Buffer.alloc(height*(width*3+1));
  for(let y=0;y<height;y++){const start=y*(width*3+1);raw[start]=0;for(let x=0;x<width;x++){const o=start+1+x*3;raw[o]=(x*7+y*3)&255;raw[o+1]=(x*3+y*11)&255;raw[o+2]=(x*13+y*5)&255;}}
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header),chunk('IDAT',deflateSync(raw)),chunk('IEND',Buffer.alloc(0))]);
}
const deviceSteps=[{op:'device',player:'first',surface:'desktop',width:1280,height:720,timeout_seconds:5},{op:'device',player:'second',surface:'mobile',width:390,height:844,timeout_seconds:5}];
function geometry(mobile) {
  const width=mobile?390.3999938964844:1280,height=mobile?844:720,top=mobile?44:0,safeHeight=mobile?763:720;
  return {device:{id:mobile?'phone':'desktop',surface:mobile?'mobile':'desktop',width:mobile?390:1280,height:mobile?844:720,form:mobile?'Phone':'Desktop',orientation:mobile?'Portrait':'LandscapeLeft',scaling:'ActualResolution'},logical:{full:{x:0,y:0,width,height},viewport:{x:0,y:top,width,height:safeHeight},safeArea:{x:0,y:top,width,height:safeHeight},insets:{left:0,top,right:0,bottom:height-top-safeHeight}},criticalUI:[{id:'action',x:10,y:50,width:100,height:40}]};
}

const scenario = { name: 'owned-studio', kind: 'studio', timeout_seconds: 30, players: ['first', 'second'], steps: [
  ...deviceSteps,
  { op: 'join', player: 'first' },
  { op: 'dispatch', player: 'first', action: 'survival-coop:gather', args: ['wood'], expect: 'ok' },
  { op: 'expect_snapshot', player: 'first', genre: 'survival-coop', field: 'wood', equals: 1 },
  { op: 'expect_members', members: ['first', 'second'] },
  { op: 'capture', target: 'viewport' },
] };
const config = { buildIdentity:{id:'sha256:'+'a'.repeat(64)},ownershipToken: 'owned-test', serverId: 'server', clients: [
  { studioId: 'client1', userId: '-1' }, { studioId: 'client2', userId: '-2' },
] };
const text = value => ({ content: [{ type: 'text', text: JSON.stringify(value) }] });
function fixture(options = {}) {
  const state = { subscriptions: new Set(), cleanup: [], mutated: [], scripts: [], captured: new Set() };
  return { state,
    async request() { return { tools: ['list_roblox_studios', 'get_studio_state', 'execute_luau', 'screen_capture', 'user_keyboard_input'].filter(name => name !== options.missing).map(name => ({ name, inputSchema: { properties: Object.fromEntries(['studio_id', 'code', 'datamodel_type', 'capture_id', 'actions'].map(key => [key, {}])) } })) }; },
    async call(name, args) {
      if (name === 'list_roblox_studios') return text({ studios: ['server', 'client1', 'client2'].map(id => ({ id })) });
      if (name === 'get_studio_state') return text(args.studio_id === 'server' ? 'Server' : 'Client');
      if (name === 'screen_capture') {
        state.captured.add(args.studio_id);const mobile=args.studio_id==='client2';
        const bytes=(options.jpeg?jpeg:png)(mobile?488:1600,mobile?1055:900);
        return options.noImage?text('capture unavailable'):{content:[{type:'image',mimeType:options.jpeg?'image/jpeg':'image/png',data:(options.corrupt?bytes.subarray(0,bytes.length-1):bytes).toString('base64')}]};
      }
      if (name === 'user_keyboard_input') {
        expect(state.subscriptions.has(args.studio_id)).toBe(true);
        state.mutated.push(args.studio_id);
        return text('Success');
      }
      state.scripts.push(args.code);
      if(args.code.includes("ForgeQA.revision:Invoke"))return text(2);
      if(args.code.includes('BUILD_HANDSHAKE_UNAVAILABLE')) {
        if(options.handshakeTimeout)throw new Error('BUILD_HANDSHAKE_UNAVAILABLE');
        return text({schemaVersion:1,role:args.datamodel_type.toLowerCase(),buildIdentity:options.staleIdentity?'sha256:'+'b'.repeat(64):config.buildIdentity.id,serverBuildIdentity:config.buildIdentity.id,sessionId:'fixture-session',actorId:args.studio_id==='client1'?'-1':'-2',ownedQaToken:options.ownerMismatch===args.studio_id?'wrong-owner':config.ownershipToken,placeId:options.placeMismatch===args.studio_id?7:0});
      }
      if(args.code.includes('local controls={}')) {
        const g=geometry(args.studio_id==='client2');
        if(options.geometryChanged&&state.captured.has(args.studio_id))g.criticalUI[0].x+=1;
        if(options.wrongDevice)g.device.width+=1;
        if(options.zeroViewport)g.logical.viewport.width=0;
        if(options.offscreen)g.criticalUI[0].x=g.logical.full.width;
        if(options.overlap)g.criticalUI.push({...g.criticalUI[0],id:'other'});
        return text(g);
      }
      if(args.code.includes('local desired=')){const g=geometry(args.studio_id==='client2');return text({device:g.device.id,width:g.device.width,height:g.device.height,orientation:g.device.orientation});}
      if(args.code.includes("folder:FindFirstChild('"))return text({present:false});
      if (args.code.includes('placeId=game.PlaceId')) return text({ placeId: options.foreign ? 83924867000873 : 0, token: config.ownershipToken, player: args.studio_id === 'client1' ? '-1' : '-2' });
      // A walk's own client code: the character readiness probe, the prepared segment
      // (which carries the resolved target back as evidence), and the movement proof.
      if (args.code.includes('character root missing')) return text({ ready: true, position: [0, 0, 0] });
      if (args.code.includes('local delta=target.Position-root.Position')) {
        state.walkPrepared = (state.walkPrepared || 0) + 1;
        return text(state.walkPrepared === 1
          ? { distance: 30, keys: ['W'], position: [0, 0, 0], target: 'Workspace.World.RedBase.Incubator1.Base' }
          : { distance: 2, keys: ['W'], position: [0, 0, 0], target: 'Workspace.World.RedBase.Incubator1.Base' });
      }
      if (args.code.includes('movement subscription missing')) return text({ input: true, distance: 2, position: [0, 0, 0] });
      if (args.code.includes('movement not replicated inside server reach')) return text({ serverDistance: 2 });
      if (args.code.includes("marker.Name='ForgeQAInputProof'")) { state.subscriptions.add(args.studio_id); return text({ subscribed: 'InputBegan' }); }
      if (args.code.includes('m:Destroy()')) { state.cleanup.push(args.studio_id); return text('clean'); }
      if (args.code.includes("assert(m.Value=='F8'")) { if (options.inputTimeout) throw new Error('InputBegan timeout'); return text({ key: 'F8' }); }
      if (args.code.includes('snapshot:Invoke')) return text({ wood: options.wrongSnapshot ? 0 : 1 });
      if (args.code.includes('GetPlayers()')) return text(['-1', '-2']);
      if (args.code.includes("qa:FindFirstChild('commandServer')")) return text({ result: { ok: true }, revision: 2 });
      if (args.code.includes('local step=')) return text({ result: { ok: true }, revision: 2 });
      return text({ revision: 1 });
    },
  };
}

test('stdio MCP performs initialize, discovery and real framed request/response', async () => {
  const transport = new StdioMcp(process.execPath, ['cli/forge/qa/studio-driver-fixture.mjs'], 2000);
  try {
    await transport.initialize();
    expect((await transport.request('tools/list', {})).tools[0].name).toBe('list_roblox_studios');
    expect(JSON.parse((await transport.call('list_roblox_studios', {})).content[0].text).studios[0].id).toBe('fixture');
  } finally { await transport.close(); }
});

test('scenario steps execute with two client input/capture evidence and cleanup', async () => {
  const transport = fixture();
  const writes = [];
  const result = await runStudio(scenario, config, transport, async (name, bytes) => { writes.push(bytes); return name; });
  expect(result.blockers).toEqual([]);
  expect(result.ok).toBe(true);
  expect(result.runtime.server.ownedQaToken).toBe(config.ownershipToken);
  expect(result.runtime.clients.map(c=>c.ownedQaToken)).toEqual([config.ownershipToken,config.ownershipToken]);
  expect(result.steps.length).toBe(scenario.steps.length);
  expect(result.captures.length).toBe(2);
  expect(result.inputs.length).toBe(2);
  expect(result.clients).toEqual([{studio_id:'client1',actor:'-1'},{studio_id:'client2',actor:'-2'}]);
  expect(result.captures.map(c=>c.actor)).toEqual(['-1','-2']);
  expect(result.captures.map(c=>c.raster)).toEqual([{format:'png',width:1600,height:900},{format:'png',width:488,height:1055}]);
  expect(result.captures[1].schemaVersion).toBe(2);
  expect(writes.length).toBe(3);
  expect(transport.state.cleanup).toEqual(['client1', 'client2']);
  const command = transport.state.scripts.find(code => code.includes('local step='));
  expect(command.indexOf('signal:Connect')).toBeLessThan(command.indexOf('pcall(action)'));
  expect(command).toContain('coroutine.yield()');
});

test('a walk that names several targets completes and reports the resolved one', async () => {
  // The step orchestration must not assume a walk names exactly one target, and the
  // server-side reach check must measure the instance the client resolved: the
  // collect-raid walk to a fixed far incubator threw before the walk even started.
  const transport = fixture();
  const targets = ['Workspace.World.BlueBase.Incubator1.Base', 'Workspace.World.RedBase.Incubator1.Base'];
  const walkScenario = { ...scenario, steps: [
    ...deviceSteps,
    { op: 'join', player: 'first' },
    { op: 'walk_to', player: 'first', targets, withinStuds: 3, timeout_seconds: 10 },
    { op: 'capture', target: 'walk' },
  ] };
  const result = await runStudio(walkScenario, config, transport, async name => name);
  expect(result.blockers).toEqual([]);
  const walk = result.steps.find(step => step.op === 'walk_to');
  expect(walk.value.arrival.target).toBe(targets[1]);
  expect(walk.value.serverSpatial.serverDistance).toBe(2);
  const prepared = transport.state.scripts.find(code => code.includes('local delta='));
  for (const target of targets) expect(prepared).toContain(`string.gmatch(${JSON.stringify(target)},'[^.]+')`);
  const reach = transport.state.scripts.find(code => code.includes('movement not replicated inside server reach'));
  expect(reach).toContain('Workspace.World.RedBase.Incubator1.Base');
});

test('discovery requires producer-validated originals and completed cleanup', async () => {
  // Encoded-image protocol fixture; not live capability proof.
  const result = await runStudio(scenario, config, fixture(), async name => name);
  expect(result.ok).toBe(true);
  expect(result.captures.every(row => row.originalValidated === true)).toBe(true);
  expect(observedDiscovery(result).status).toBe('BLOCKED');
  result.lifecycle = { ok: true, residuals: [] };
  expect(observedDiscovery(result).status).toBe('OBSERVED');
  result.lifecycle = { ok: false, residuals: ['owned-editor'] };
  expect(Object.values(observedDiscovery(result).capabilities).every(row => !row.available)).toBe(true);
});

test('corrupt originals and partial input retain unavailable discovery', async () => {
  for (const options of [{ corrupt: true }, { inputTimeout: true }]) {
    const result = await runStudio(scenario, config, fixture(options), async name => name);
    result.lifecycle = { ok: true, residuals: [] };
    expect(result.ok).toBe(false);
    const discovery = observedDiscovery(result);
    expect(discovery.status).toBe('BLOCKED');
    expect(Object.values(discovery.capabilities).every(row => !row.available)).toBe(true);
    expect(discovery.blockers).toEqual(result.blockers);
  }
});

test('numeric YAML invite UserId reaches the string command contract', async () => {
  const transport = fixture();
  const result = await runStudio({...scenario, steps: [
    ...deviceSteps,
    {op: 'server_command', player: 'first', requestId: 'invite', action: 'survival-coop:settlement-invite', args: [-2, 0, 0], expect: 'ok'},
    {op: 'capture', target: 'viewport'},
  ]}, config, transport, async name => name);
  expect(result.ok).toBe(true);
  const command = transport.state.scripts.find(code => code.includes("qa:FindFirstChild('commandServer')"));
  expect(command).toContain('[1]="-2"');
  expect(command).toContain('[2]=0');
});

// The reach probe reports what it measured about the node and must not carry the stale hardcoded
// harness endpoint probe, whose ConnectFail is unrelated to the gather step and was previously
// presented inside the same serverReach text.
test('the server reach probe reports node reachability and carries no stale harness endpoint probe', async () => {
  const transport = fixture();
  const result = await runStudio({...scenario, steps: [
    ...deviceSteps,
    { op: 'join', player: 'first' },
    { op: 'activate_prompt', player: 'first', target: 'Workspace.DevelopmentIsland.fallen-tree-01.ForgeGatherAnchor.ForgeGather', nodeId: 'fallen-tree-01', key: 'E', timeout_seconds: 5 },
  ]}, config, transport, async name => name);
  expect(result.ok).toBe(false);
  const blockers = result.blockers.join(' ');
  expect(blockers).toContain('serverReach=');
  // The probe ran against the server, and the gathered text is the probe's own measurement.
  expect(transport.state.scripts.some(code => code.includes('nodeFound'))).toBe(true);
  // The stale endpoint and its leaked bearer never appear in what the operator reads.
  expect(blockers).not.toContain('39451');
  expect(blockers).not.toContain('harnessProbe');
  expect(blockers).not.toContain('Bearer ');
});

test('owned source preparation follows actual handshakes and precedes scenario input', async () => {
  const transport=fixture();let called=false;
  const result=await runStudio(scenario,{...config,prepareCapture:async runtime=>{
    called=true;
    expect(runtime.server.sessionId).toBe('fixture-session');
    expect(runtime.clients.map(client=>client.actorId)).toEqual(['-1','-2']);
    expect(transport.state.subscriptions.size).toBe(0);
    expect(transport.state.mutated).toEqual([]);
    throw new Error('UNIT_REGISTRATION_STOP');
  }},transport,async name=>name);
  expect(called).toBe(true);expect(result.ok).toBe(false);
  expect(result.blockers).toContain('UNIT_REGISTRATION_STOP');
});

test('bad loaded identity never invokes source preparation', async () => {
  let called=false;
  const result=await runStudio(scenario,{...config,prepareCapture:async()=>{called=true;throw Error('unexpected');}},fixture({staleIdentity:true}),async name=>name);
  expect(called).toBe(false);expect(result.ok).toBe(false);
});

for (const [label, options] of Object.entries({ 'changed capture geometry':{geometryChanged:true},'wrong device':{wrongDevice:true},'zero viewport':{zeroViewport:true},'offscreen control':{offscreen:true},'overlapping controls':{overlap:true},'corrupt image':{corrupt:true},'wrong snapshot': { wrongSnapshot: true }, 'missing image': { noImage: true }, 'input timeout': { inputTimeout: true }, 'missing capability': { missing: 'screen_capture' }, 'foreign ownership': { foreign: true } })) {
  test(`${label} fails closed and cleans only installed resources`, async () => {
    const transport = fixture(options);
    const result = await runStudio(scenario, config, transport, async name => name);
    expect(result.ok).toBe(false);
    expect(result.blockers.length).toBeGreaterThan(0);
    expect(transport.state.cleanup).toEqual([...transport.state.subscriptions]);
    if (options.foreign || options.missing) expect(transport.state.mutated).toEqual([]);
  });
}

test('unsupported native backend operation fails before tools or input', async () => {
  const transport = fixture();
  const result = await runStudio({ ...scenario, steps: [{ op: 'commit_barrier' }] }, config, transport, async name => name);
  expect(result.ok).toBe(false);
  expect(transport.state.scripts).toEqual([]);
});

for(const id of ['server','client1','client2'])for(const field of ['ownerMismatch','placeMismatch'])test(`measured ${field} on ${id} refuses before input`,async()=>{
  const transport=fixture({[field]:id});
  const result=await runStudio(scenario,config,transport,async name=>name);
  expect(result.ok).toBe(false);
  expect(result.blockers).toContain('LOADED_OWNERSHIP_MISMATCH');
  expect(transport.state.mutated).toEqual([]);
});

for(const options of [{staleIdentity:true},{handshakeTimeout:true}])test('loaded identity admission fails before injected input',async()=>{
  const transport=fixture(options);
  const result=await runStudio(scenario,config,transport,async name=>name);
  expect(result.ok).toBe(false);
  expect(result.blockers.length).toBeGreaterThan(0);
  expect(transport.state.mutated).toEqual([]);
});

test('original JPEG captures preserve fractional geometry and unequal encoded raster',async()=>{
  const writes=[];
  const result=await runStudio(scenario,config,fixture({jpeg:true}),async(name,bytes)=>{writes.push(bytes);return name;});
  expect(result.blockers).toEqual([]);expect(result.ok).toBe(true);
  expect(result.captures.map(c=>c.raster)).toEqual([{format:'jpeg',width:1600,height:900},{format:'jpeg',width:488,height:1055}]);
  expect(result.captures[1].logical.viewport.width).toBe(390.3999938964844);
  expect(writes[1].equals(jpeg(488,1055))).toBe(true);
  expect(result.captures[1].logicalToRaster.scaleX).toBe(488/390.3999938964844);
});

test('raster validation rejects truncated entropy even with a replacement EOI',()=>{
  for(const encode of [png,jpeg]) {
    const bytes=encode(488,1055);expect(decodeRaster(bytes).width).toBe(488);
    expect(()=>decodeRaster(bytes.subarray(0,-1))).toThrow();
    expect(()=>decodeRaster(Buffer.concat([bytes,Buffer.from([0])]))).toThrow();
  }
  const bytes=jpeg(488,1055);
  expect(()=>decodeRaster(Buffer.concat([bytes.subarray(0,-8),Buffer.from([255,217])]))).toThrow();
  const falseSize=Buffer.from(bytes);const frame=falseSize.indexOf(Buffer.from([255,192]));falseSize.writeUInt16BE(2000,frame+7);
  expect(()=>decodeRaster(falseSize)).toThrow();
  const corrupt=png(8,8);corrupt[45]^=1;expect(()=>decodeRaster(corrupt)).toThrow();
});

test('nonfinite logical dimensions cannot be accepted as capture geometry',()=>{
  for(const value of [0,-1,NaN,Infinity]){const g=geometry(true);g.logical.viewport.width=value;expect(()=>validateGeometry(g,geometry(true).device)).toThrow();}
});

test('owned UI laid over the chat window fails the capture',()=>{
  const reserved=geometry(true);reserved.chat={x:0,y:44,width:200,height:200};
  reserved.criticalUI=[{id:'action',x:210,y:50,width:100,height:40}];
  expect(()=>validateGeometry(reserved,reserved.device)).not.toThrow();
  const covered=geometry(true);covered.chat={x:0,y:44,width:200,height:200};
  expect(()=>validateGeometry(covered,covered.device)).toThrow('CRITICAL_UI_CHAT_OVERLAP');
  const outside=geometry(true);outside.chat={x:0,y:0,width:200,height:20};
  expect(()=>validateGeometry(outside,outside.device)).toThrow('CAPTURE_CHAT_GEOMETRY');
  const unmeasured=geometry(true);
  expect(()=>validateGeometry(unmeasured,unmeasured.device)).not.toThrow();
});

test('capture geometry measures the live chat frame it must keep clear',async()=>{
  let code;
  await captureGeometry({studioId:'c'},async(_id,_model,source)=>{code=source;return {};});
  expect(code).toContain("playerGui:FindFirstChild('Chat')");
  expect(code).toContain('chat=chat');
});

test('capture without an explicitly configured scenario device fails closed',async()=>{
  const result=await runStudio({...scenario,steps:[{op:'capture',target:'viewport'}]},config,fixture(),async name=>name);
  expect(result.ok).toBe(false);expect(result.blockers).toContain('DEVICE_CONFIG_MISMATCH');
});

test('physical rejoin never succeeds through handshake or snapshot restoration', async () => {
  const transport=fixture();
  const result=await runStudio({...scenario,steps:[{op:'rejoin',player:'first',timeout_seconds:30}]},config,transport,async name=>name);
  expect(result.ok).toBe(false);
  expect(result.blockers[0]).toContain('physical rejoin unavailable');
  expect(transport.state.cleanup).toEqual(['client1','client2']);
});

test('CLI waits for split stdin chunks before parsing configuration', async () => {
  const child = spawn(process.execPath, ['cli/forge/qa/studio-driver.mjs'], { stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  const exited = new Promise(resolve => child.once('exit', resolve));
  await new Promise((resolve, reject) => child.stdin.write('{"scenario":', error => error ? reject(error) : resolve()));
  child.stdin.end('{"timeout_seconds":10},"config":{}}');
  expect(await exited).toBe(1);
  expect(JSON.parse(stdout).blockers).toEqual(['driver command and args required']);
});

test('AV probe rejects caller-supplied actor identity before allocation', async () => {
  const lifecycle = new StudioLifecycle();
  const probe = {...scenario,name:'owned-av-probe',kind:'studio'};
  await expect(runOwnedStudio(probe,{...config,capture:{probe:true,player:probe.players[0],actorId:'-1',mode:'owned-process-loopback'}},fixture(),lifecycle)).rejects.toThrow('OWNED_AV_PROBE_CONFIG_INVALID');
  expect(lifecycle.receipt().resources).toEqual([]);
  await lifecycle.close();
});

test('production session admission blocks before input without claiming configured instances', async () => {
  const transport = fixture();
  const lifecycle = new StudioLifecycle();
  const outcome = await runOwnedStudio(scenario, config, transport, lifecycle);
  expect(outcome.ok).toBe(false);
  expect(outcome.status).toBe('BLOCKED');
  expect(outcome.blockers.length).toBeGreaterThan(0);
  expect(transport.state.mutated).toEqual([]);
  expect(lifecycle.receipt().resources).toEqual([]);
  await lifecycle.close();
});

// The world path is the player-facing gate, so the driver source must require a real key activation on a
// prompt the engine showed, and must label the API fallback as a diagnostic that cannot satisfy it.
test('the world path requires real key activation on a shown prompt and refuses the API diagnostic', () => {
  const driver = readFileSync(new URL('./studio-driver.mjs', import.meta.url), 'utf8');
  expect(driver).toContain("value.activation!=='key'");
  expect(driver).toContain('value.engineShown!==true');
  const gameplay = readFileSync(new URL('./studio-driver-gameplay.mjs', import.meta.url), 'utf8');
  // The API hold path is labelled a diagnostic, and the engine evidence is read while the proof still exists:
  // the read must appear before the cleanup that destroys the proof object.
  expect(gameplay).toContain("'prompt-hold-diagnostic'");
  const evidenceRead = gameplay.indexOf("proof:GetAttribute('Shown')~=nil");
  const cleanup = gameplay.indexOf('await cleanup(); await restoreCamera();');
  expect(evidenceRead).toBeGreaterThan(-1);
  expect(cleanup).toBeGreaterThan(-1);
  expect(evidenceRead).toBeLessThan(cleanup);
});
