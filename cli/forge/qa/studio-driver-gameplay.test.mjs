import {test,expect} from 'bun:test';
import {readFileSync} from 'node:fs';
import {gameplay,resolveReferences,remainingSeconds} from './studio-driver-gameplay.mjs';

// Behavioral model of the real client plus the correlation marker, driven only by the driver's
// own emitted instructions. The client keeps one request identity until it settles the request,
// which cli/forge/fixtures/gathering-client/correlation.luau proves against the real module, so
// this model computes what a live run delivers instead of returning a canned packet. It also
// honours the blind per-attempt clears by their emitted shape, so re-introducing them fails.
function liveGatherClient(nodeId, script) {
  const marker = { Value: '', attrs: {} };
  const resets = [];
  let attempt = -1, identity = 0;
  const deliver = packet => {
    marker.attrs.Packets = (marker.attrs.Packets || 0) + 1;
    const current = marker.attrs.RequestId;
    if (packet.nodeId !== nodeId || marker.attrs.Input !== true || typeof current !== 'string'
        || packet.requestId !== current) return;
    marker.attrs.Relevant = (marker.attrs.Relevant || 0) + 1;
    if (marker.attrs.Captured !== false && marker.attrs.Captured !== packet.requestId) marker.Value = 'INVALID';
    else { marker.attrs.Captured = packet.requestId; marker.Value = JSON.stringify(packet); }
  };
  const execute = async (_id, _model, code) => {
    if (code.includes('ForgeQACorrelation.install')) {
      Object.assign(marker.attrs, { Input: false, RequestId: false, Captured: false, Packets: 0, Relevant: 0, Attempt: 0 });
      marker.Value = '';
      return { subscribed: true };
    }
    if (code.includes('ForgeQAReset.reset')) {
      attempt += 1;
      resets.push(code);
      const flags = /ForgeQAReset\.reset\(m,(\w+),(\w+)\)/.exec(code) || [];
      // The receipt's blind per-attempt clear, detected by the shape it was emitted with.
      const blind = /m\.Value=''/.test(code) || /m:SetAttribute\('Input',false\)/.test(code);
      if (blind || flags[1] === 'true' || marker.Value === 'INVALID') marker.Value = '';
      if (blind || flags[2] === 'true') { marker.attrs.RequestId = false; marker.attrs.Captured = false; }
      if (blind) marker.attrs.Input = false;
      // A late result for the request the client still holds arrives while this attempt is being
      // prepared, i.e. after the reset has run, so the reset decides whether it can be correlated.
      if (script.late?.[attempt]) deliver(script.late[attempt]);
      return { ready: true };
    }
    if (code.includes('JSONDecode(m.Value)')) {
      if (script.wait?.[attempt]) deliver(script.wait[attempt]);
      if (marker.Value === '' || marker.Value === 'INVALID') throw new Error('WORKLOAD_EVENT_TIMEOUT');
      return JSON.parse(marker.Value);
    }
    return { clean: true };
  };
  const call = async (_name, args) => {
    if (args.actions[0].action !== 'keyDown') return;
    marker.attrs.Input = true;
    // Only the attempts the script marks reach the prompt; a dropped activation publishes no
    // identity, exactly as a prompt that never triggered does on the live client.
    if (script.dispatch?.[attempt]) { identity += 1; marker.attrs.RequestId = `r-${identity}`; }
  };
  return { marker, resets, execute, call };
}
const gatherStep = nodeId => ({ op: 'activate_prompt', target: `Workspace.DevelopmentIsland.${nodeId}.ForgeGatherAnchor.ForgeGather`, nodeId, timeout_seconds: 15 });
const moduleSource = name => readFileSync(new URL(name, import.meta.url), 'utf8');

test('bindings resolve machine scalar only and reject absent or extra keys',()=>{
 expect(resolveReferences([{ref:'job'}],new Map([['job','runtime:job']]))).toEqual(['runtime:job']);
 expect(()=>resolveReferences([{ref:'missing'}],new Map())).toThrow();
 expect(()=>resolveReferences({ref:'job',code:'bad'},new Map([['job','x']]))).toThrow();
});
for(const [name,packet] of Object.entries({valid:{nodeId:'fiber',requestId:'r',result:{ok:true,data:{status:'confirmed'}}},wrongNode:{nodeId:'other',requestId:'r',result:{ok:true}},refused:{nodeId:'fiber',requestId:'r',result:{ok:false}}})) {
 test(`prompt ${name} requires real subscription before input and releases E`,async()=>{
  const calls=[];let subscribed=false;
  const execute=async(_id,_model,code)=>{calls.push(code);if(code.includes('relay.Event:Connect')){subscribed=true;expect(code).toContain("target.Parent:IsA('Attachment')");return {subscribed:true};}if(code.includes('JSONDecode(m.Value)')){expect(code).toContain('if value.result and value.result.ok then');return packet;}return {clean:true};};
  const call=async(_name,args)=>{if(args.actions[0].action==='keyDown')expect(subscribed).toBe(true);calls.push(args.actions[0].action);};
  const pending=gameplay({op:'activate_prompt',target:'Workspace.Node.ForgeGather',nodeId:'fiber',timeout_seconds:5},{studioId:'owned'},execute,call);
  if(name==='valid')expect((await pending).kind).toBe('gameplay-prompt');else await expect(pending).rejects.toThrow();
  expect(calls).toContain('keyUp');
 });
}
test('movement uses observed event and releases held key on failure',async()=>{
 const keys=[];
 let observed=false;
 const execute=async(_id,_model,code)=>{if(code.includes('local delta=')){observed=true;return {distance:12,keys:['W'],position:[0,0,0]};}if(code.includes('movement subscription missing'))throw new Error('movement timeout');return {clean:true};};
 await expect(gameplay({op:'walk_to',target:'Workspace.Node',withinStuds:6,timeout_seconds:5},{studioId:'owned'},execute,async(_name,args)=>keys.push(args.actions[0]))).rejects.toThrow('movement timeout');
 expect(keys).toEqual([{action:'keyDown',key_code:'W'},{action:'keyUp',key_code:'W'}]);
 expect(observed).toBe(true);
});

test('pending gather retries actual input with same request before confirmed outcome',async()=>{
 const inputs=[];let results=0;
 const execute=async(_id,_model,code)=>{
  if(code.includes('JSONDecode(m.Value)')) return {nodeId:'fiber',requestId:'same',result:++results===1?{ok:false,data:{status:'pending'}}:{ok:true,data:{status:'confirmed'}}};
  return {subscribed:true};
 };
 const call=async(_name,args)=>{inputs.push(args.actions[0].action);};
 const result=await gameplay({op:'activate_prompt',target:'Workspace.Node.Anchor.ForgeGather',nodeId:'fiber'},{studioId:'c'},execute,call);
 expect(result.requestId).toBe('same');expect(results).toBe(2);
 expect(inputs).toEqual(['keyDown','keyUp','keyDown','keyUp','keyUp']);
});

test('walk_to subscribes to the character lifecycle and fails when the root never returns',async()=>{
 const calls=[];
 const execute=async(_id,_model,code)=>{calls.push(code);if(code.includes('character root missing'))throw new Error('character root missing');return {clean:true};};
 await expect(gameplay({op:'walk_to',target:'Workspace.Node',withinStuds:6,timeout_seconds:5},{studioId:'owned'},execute,async()=>{})).rejects.toThrow('character root missing');
 const readiness=calls.findIndex(code=>code.includes('character root missing'));
 expect(readiness).toBeGreaterThanOrEqual(0);
 const code=calls[readiness];
 expect(code).toContain('CharacterAdded');
 expect(code).toContain('AncestryChanged');
 expect(code).toContain('DescendantAdded');
 expect(code).toContain('if not settled then parked=true end');
 expect(code).toContain('if parked then coroutine.yield() end');
 expect(code).toContain('local function wake() if parked then parked=false;task.spawn(thread) end end');
 expect(code.indexOf('for _,connection in connections do connection:Disconnect() end'))
  .toBeLessThan(code.indexOf("assert(root,'character root missing')"));
 expect(code).toContain("if coroutine.status(timer)=='suspended' then task.cancel(timer) end");
});

test('a respawn between movement segments is re-established per segment',async()=>{
 let readiness=0;
 const keys=[];
 const execute=async(_id,_model,code)=>{
  if(code.includes('character root missing')){readiness+=1;if(readiness===2)throw new Error('character root missing');return {ready:true};}
  if(code.includes('local delta='))return {distance:12,keys:['W'],position:[0,0,0]};
  if(code.includes('movement subscription missing'))return {input:true,distance:6,position:[0,0,0]};
  return {clean:true};};
 await expect(gameplay({op:'walk_to',target:'Workspace.Node',withinStuds:6,timeout_seconds:5},{studioId:'owned'},execute,async(_name,args)=>keys.push(args.actions[0]))).rejects.toThrow('character root missing');
 expect(readiness).toBe(2);
 expect(keys).toEqual([{action:'keyDown',key_code:'W'},{action:'keyUp',key_code:'W'}]);
});

test('an exhausted step budget never extends the wait and fails',async()=>{
 expect(remainingSeconds(Date.now()-1000,10)).toBe(0);
 expect(remainingSeconds(Date.now()+60000,10)).toBe(10);
 expect(remainingSeconds(Infinity,10)).toBe(10);
 expect(remainingSeconds(Date.now()+4000,10)).toBeLessThanOrEqual(4);
 const calls=[];
 const execute=async(_id,_model,code)=>{calls.push(code);return {ready:true};};
 await expect(gameplay({op:'walk_to',target:'Workspace.Node',withinStuds:6,timeout_seconds:0},{studioId:'owned'},execute,async()=>{})).rejects.toThrow('walk_to deadline');
 const bounded=await (async()=>{const seen=[];const boundedExecute=async(_id,_model,code)=>{seen.push(code);throw new Error('character root missing');};
  try{await gameplay({op:'walk_to',target:'Workspace.Node',withinStuds:6,timeout_seconds:5},{studioId:'owned'},boundedExecute,async()=>{});}catch{}
  return Number(seen[0].match(/task\.delay\(([\d.]+)/)[1]);})();
 expect(bounded).toBeLessThanOrEqual(5);
});

test('prompt proof correlates the injected input with the client dispatch, not the service trigger',async()=>{
 const calls=[];
 const execute=async(_id,_model,code)=>{calls.push(code);
  if(code.includes('relay.Event:Connect'))return {subscribed:true};
  if(code.includes('JSONDecode(m.Value)'))return {nodeId:'fiber',requestId:'r',result:{ok:true,data:{status:'confirmed'}}};
  return {clean:true};};
 await gameplay({op:'activate_prompt',target:'Workspace.Node.Anchor.ForgeGather',nodeId:'fiber',timeout_seconds:5},{studioId:'c'},execute,async()=>{});
 const prepare=calls.find(code=>code.includes('relay.Event:Connect'));
 expect(prepare).toContain("p:FindFirstChild('ForgeGatherRequested')");
 expect(prepare).toContain("ForgeQACorrelation.install({input=game:GetService('UserInputService')");
 expect(prepare).toContain('m:SetAttribute("InputAt", ctx.now())');
 expect(prepare).toContain('m:GetAttribute("Input") == true');
 expect(prepare).toContain('packet.requestId == requestId');
 expect(prepare).toContain('m:SetAttribute("DispatchAt", packet.serverTime)');
 expect(prepare).toContain('m:SetAttribute("Triggered", true)');
 expect(prepare).not.toContain('and triggered then');
 // The reset is per dispatch, not per attempt: the first attempt has consumed nothing and
 // settled nothing, so it may not clear the captured identity or a value a late result from
 // the request the client still holds may already have written.
 const reset=calls.find(code=>code.includes('ForgeQAReset.reset'));
 expect(reset).toBeDefined();
 expect(reset).toContain('ForgeQAReset.reset(m,false,false)');
 expect(reset).toContain('m:SetAttribute("Attempt", (m:GetAttribute("Attempt") or 0) + 1)');
 expect(reset).toContain('if clearValue or m.Value == "INVALID" then');
 expect(reset).toContain('if clearIdentity then');
 expect(reset).toContain('m:SetAttribute("Captured", false)');
 expect(reset).not.toContain("m:SetAttribute('Input',false)");
});

test('a gather step looks at its own node before pressing E and gives the camera back afterwards',async()=>{
 // Neighbouring nodes share E; the engine gives the key to the prompt the camera faces.
 const calls=[];
 const execute=async(_id,_model,code)=>{calls.push(code);
  if(code.includes('relay.Event:Connect'))return {subscribed:true};
  if(code.includes('JSONDecode(m.Value)'))return {nodeId:'fiber',requestId:'r',result:{ok:true,data:{status:'confirmed'}}};
  return {clean:true};};
 const keys=[];
 await gameplay({op:'activate_prompt',target:'Workspace.Node.Anchor.ForgeGather',nodeId:'fiber',timeout_seconds:5},{studioId:'c'},execute,async(name,args)=>{if(name==='user_keyboard_input')keys.push([args.actions[0].action,calls.length]);});
 const subscribe=calls.findIndex(code=>code.includes('relay.Event:Connect'));
 const aim=calls.findIndex(code=>code.includes('camera.CFrame=CFrame.lookAt'));
 const firstPress=keys.find(([kind])=>kind==='keyDown');
 expect(subscribe).toBeGreaterThanOrEqual(0);
 expect(aim).toBeGreaterThan(subscribe);
 expect(firstPress[1]).toBeGreaterThan(aim);
 expect(calls.findIndex(code=>code.includes("p:SetAttribute('ForgeQACameraType',nil)"))).toBeGreaterThan(aim);
 // The gather prompt's parent is an Attachment: its Position is local, so the aim must use the world point.
 expect(calls[aim]).toContain("target.Parent:IsA('Attachment') then target.Parent.WorldPosition");
});

test('the emitted client code embeds the real correlation modules and neither needs a suppression',async()=>{
 const calls=[];
 const execute=async(_id,_model,code)=>{calls.push(code);
  if(code.includes('ForgeQACorrelation.install'))return {subscribed:true};
  if(code.includes('ForgeQAReset.reset'))return {ready:true};
  if(code.includes('JSONDecode(m.Value)'))return {nodeId:'fiber',requestId:'r',result:{ok:true,data:{status:'confirmed'}}};
  return {clean:true};};
 await gameplay(gatherStep('fiber'),{studioId:'c'},execute,async()=>{});
 const correlation=moduleSource('./gathering-correlation.luau');
 const reset=moduleSource('./gathering-reset.luau');
 // The emitted client code contains each module verbatim, and the fixture requires the same file,
 // so there is no copy to drift and no fragment that has to be excluded from analysis.
 expect(calls.find(code=>code.includes('ForgeQACorrelation.install'))).toContain(correlation);
 expect(calls.find(code=>code.includes('ForgeQAReset.reset'))).toContain(reset);
 for(const source of [correlation,reset]) {
  expect(source.startsWith('--!strict')).toBe(true);
  expect(source).not.toContain('--!nocheck');
  expect(source).not.toContain('selene: allow');
 }
});

test('a late result for the request the client still holds is correlated after an attempt reset',async()=>{
 const nodeId='fallen-tree-01';
 const confirmed={nodeId,requestId:'r-1',result:{ok:true,data:{status:'confirmed'}}};
 // Attempt 0's injected key reaches the prompt and dispatches r-1, whose result is slower than
 // the attempt's bounded wait. Attempt 1's key does not reach the prompt (the prompt never
 // triggered on the live run), so no new identity is published and the client still holds r-1;
 // its result arrives while attempt 1 is being prepared. The receipt failed here because the
 // per-attempt reset had cleared the identity, the capture and the value.
 const model=liveGatherClient(nodeId,{dispatch:[true,false],late:[null,confirmed]});
 const result=await gameplay(gatherStep(nodeId),{studioId:'c'},model.execute,model.call);
 expect(result.requestId).toBe('r-1');
 expect(result.result.data.status).toBe('confirmed');
 expect(model.marker.attrs.Relevant).toBe(1);
 expect(model.resets[1]).toContain('ForgeQAReset.reset(m,false,false)');
});

test('a settled stale refusal clears the captured identity for the fresh one the client allocates',async()=>{
 const nodeId='fiber-bush-01';
 const model=liveGatherClient(nodeId,{dispatch:[true,true],wait:[
  {nodeId,requestId:'r-1',result:{ok:false,reason:'STALE_VERSION',data:{status:'rejected'}}},
  {nodeId,requestId:'r-2',result:{ok:true,data:{status:'confirmed'}}},
 ]});
 const result=await gameplay(gatherStep(nodeId),{studioId:'c'},model.execute,model.call);
 expect(result.requestId).toBe('r-2');
 expect(model.marker.attrs.Relevant).toBe(2);
 // The attempt after the settled refusal clears the identity; the attempt before it does not.
 expect(model.resets[0]).toContain('ForgeQAReset.reset(m,false,false)');
 expect(model.resets[1]).toContain('ForgeQAReset.reset(m,true,true)');
});

test('a settled stale refusal lets the client re-read and allocate a new identity',async()=>{
 const calls=[];let results=0;
 const execute=async(_id,_model,code)=>{calls.push(code);
  if(code.includes('relay.Event:Connect'))return {subscribed:true};
  if(code.includes('JSONDecode(m.Value)')){results+=1;
   return results===1?{nodeId:'fiber',requestId:'first',result:{ok:false,reason:'STALE_VERSION',data:{status:'rejected'}}}:{nodeId:'fiber',requestId:'second',result:{ok:true,data:{status:'confirmed'}}};}
  return {clean:true};};
 const value=await gameplay({op:'activate_prompt',target:'Workspace.Node.Anchor.ForgeGather',nodeId:'fiber',timeout_seconds:5},{studioId:'c'},execute,async()=>{});
 expect(value.requestId).toBe('second');
 expect(results).toBe(2);
 expect(calls.some(code=>code.includes('ForgeQAGameplayProof')&&code.includes('m:Destroy()'))).toBe(true);
});

test('an unresolved refusal replays the identical request identity',async()=>{
 let results=0;
 const execute=async(_id,_model,code)=>{
  if(code.includes('relay.Event:Connect'))return {subscribed:true};
  if(code.includes('JSONDecode(m.Value)')){results+=1;
   return results===1?{nodeId:'fiber',requestId:'same',result:{ok:false,reason:'SOURCE_BUSY',data:{status:'recovering'}}}:{nodeId:'fiber',requestId:'same',result:{ok:true,data:{status:'confirmed'}}};}
  return {clean:true};};
 const value=await gameplay({op:'activate_prompt',target:'Workspace.Node.Anchor.ForgeGather',nodeId:'fiber',timeout_seconds:5},{studioId:'c'},execute,async()=>{});
 expect(value.requestId).toBe('same');
 expect(results).toBe(2);
});

test('an identity change while the request is unresolved fails the step',async()=>{
 let results=0;
 const execute=async(_id,_model,code)=>{
  if(code.includes('relay.Event:Connect'))return {subscribed:true};
  if(code.includes('JSONDecode(m.Value)')){results+=1;
   if(results===1)return {nodeId:'fiber',requestId:'first',result:{ok:false,reason:'SOURCE_BUSY',data:{status:'recovering'}}};
   return {nodeId:'fiber',requestId:'second',result:{ok:true,data:{status:'confirmed'}}};}
  return {clean:true};};
 await expect(gameplay({op:'activate_prompt',target:'Workspace.Node.Anchor.ForgeGather',nodeId:'fiber',timeout_seconds:5},{studioId:'c'},execute,async()=>{})).rejects.toThrow('request identity changed while unresolved');
});

// The retained step-22 failure reported `blockedBy: "LeftUpperArm"` - a bare name that cannot say
// whose limb was hit - so the attribution the operator reads has to carry the full path and the owner
// class, and the line-of-sight raycast has to be labelled as an inference rather than presented as
// the engine's own verdict (ProximityPrompt exposes no such query).
test('the prompt failure carries the attributed blocker and labels the line-of-sight raycast',async()=>{
 const execute=async(_id,_model,code)=>{
  if(code.includes('local blocked,blockedKind,lineOfSightRaycast'))return {why:'attempt 1',blockedBy:'Workspace.Guest.LeftUpperArm',blockedKind:'other-character',lineOfSight:true,lineOfSightRaycast:false,lineOfSightRaycastKind:'inferred-raycast'};
  if(code.includes('relay.Event:Connect'))return {subscribed:true};
  if(code.includes('JSONDecode(m.Value)'))throw new Error('exact predicate/input timeout');
  return {clean:true};
 };
 const failure=await gameplay({op:'activate_prompt',target:'Workspace.DevelopmentIsland.fallen-tree-01.ForgeGatherAnchor.ForgeGather',nodeId:'fallen-tree-01',timeout_seconds:2},{studioId:'c'},execute,async()=>{}).catch(error=>error);
 const message=String(failure && failure.message);
 expect(message).toContain('gather result wait failed');
 // What the operator reads, asserted on the failure itself rather than on the emitted source.
 expect(message).toContain('"blockedBy":"Workspace.Guest.LeftUpperArm"');
 expect(message).toContain('"blockedKind":"other-character"');
 expect(message).toContain('"lineOfSight":true');
 expect(message).toContain('"lineOfSightRaycast":false');
 expect(message).toContain('"lineOfSightRaycastKind":"inferred-raycast"');
 // A bare name is exactly what made the retained evidence unattributable.
 expect(message).not.toContain('"blockedBy":"LeftUpperArm"');
});

// A walk may name several candidate targets and walks to the nearest: a teamless actor
// spawns in whichever of a two-team pack's bases Roblox picks, and a fixed far target
// stalled against the actor's own base's vault crate. The resolved path travels back in
// the walk's evidence, so the server-side reach check measures the same instance.
test('a walk that names several targets resolves the nearest and reports it',async()=>{
 const calls=[];
 let preparedCalls=0;
 const targets=['Workspace.World.BlueBase.Incubator1.Base','Workspace.World.RedBase.Incubator1.Base'];
 const execute=async(_id,_model,code)=>{calls.push(code);
  if(code.includes('local delta=')){preparedCalls+=1;return preparedCalls===1?{distance:30,keys:['W'],position:[0,0,0],target:targets[1]}:{distance:2,keys:['W'],position:[0,0,0],target:targets[1]};}
  if(code.includes('movement subscription missing'))return {input:true,distance:6,position:[0,0,0]};
  return {clean:true};};
 const result=await gameplay({op:'walk_to',targets,withinStuds:3,timeout_seconds:5},{studioId:'owned'},execute,async()=>{});
 const prepared=calls.find(code=>code.includes('local delta='));
 for(const target of targets) expect(prepared).toContain(`string.gmatch(${JSON.stringify(target)},'[^.]+')`);
 expect(prepared).toContain('local candidates={');
 expect(prepared).toContain("assert(#candidates>0,'walk target missing')");
 expect(prepared).toContain('if node==nil then return nil end');
 expect(prepared).toContain('local target=candidates[1]');
 expect(prepared).toContain('for index=2,#candidates do local distance=(candidates[index].Position-root0.Position).Magnitude;if distance<best then target,best=candidates[index],distance end end');
 expect(prepared).toContain('target=target:GetFullName()');
 expect(result.arrival.target).toBe(targets[1]);
});

// The prompt step's camera must stand where a player's camera stands: behind the actor on
// the side it walked in from. Aimed from beyond the node, the node's own sign and board sat
// between the camera and the character and hid the character and most of the scene in every
// thin-genre capture.
test('the prompt step aims the camera from the approach side, never from beyond the node',async()=>{
 const calls=[];
 const execute=async(_id,_model,code)=>{calls.push(code);
  if(code.includes("assert(target:IsA('ProximityPrompt'),'prompt required')"))return {specNode:true,control:'grow-harvest:seed-shop',nodeId:'seed-crate'};
  if(code.includes('aimed=true'))return {aimed:true};
  if(code.includes('JSONDecode(proof.Value)'))return {control:'grow-harvest:seed-shop',result:{ok:true}};
  return {clean:true};};
 const result=await gameplay({op:'activate_prompt',target:'Workspace.World.Node-seed-crate.grow-harvest:seed-shop',nodeId:'seed-crate',key:'E',timeout_seconds:5,expect:'ok'},{studioId:'c'},execute,async()=>{});
 expect(result.kind).toBe('gameplay-prompt');
 const aim=calls.find(code=>code.includes('aimed=true'));
 expect(aim).toBeDefined();
 expect(aim).toContain('local eye=root.Position-unit*11+right*4+Vector3.new(0,6,0)');
 expect(aim).toContain('camera.CFrame=CFrame.lookAt(eye,at+Vector3.new(0,1.5,0))');
 expect(aim).not.toContain('at+(at-root.Position).Unit*Vector3.new(1,0,1)*12');
});

// A stall is the only evidence of where the actor actually was and what stopped it, so the emitted
// payload must carry the desired key, whether the injected key was observed, the target, and the
// instance the movement ray hits. The ray excludes the actor and the target, so any hit names a
// third party: static geometry or the pursuer rig.
test('the emitted stall payload carries the discriminating movement evidence',async()=>{
 const calls=[];
 let preparedCalls=0;
 const execute=async(_id,_model,code)=>{calls.push(code);
  if(code.includes('local delta=')){preparedCalls+=1;return preparedCalls===1?{distance:12,keys:['W'],position:[0,0,0]}:{distance:2,keys:['W'],position:[0,0,0]};}
  if(code.includes('movement subscription missing'))return {input:true,distance:6,position:[0,0,0]};
  return {clean:true};};
 await gameplay({op:'walk_to',target:'Workspace.Node',withinStuds:6,timeout_seconds:5},{studioId:'owned'},execute,async()=>{});
 const prepared=calls.find(code=>code.includes('stall=true'));
 expect(prepared).toBeDefined();
 expect(prepared).toContain('keys=keys');
 expect(prepared).toContain('input=input');
 expect(prepared).toContain('target=target:GetFullName()');
 expect(prepared).toContain('targetPosition={target.Position.X,target.Position.Y,target.Position.Z}');
 expect(prepared).toContain('workspace:Raycast(root.Position,Vector3.new(d.X,0,d.Z),params)');
 expect(prepared).toContain('params.FilterDescendantsInstances=ignore');
 expect(prepared).toContain('local ignore={target};if p.Character then table.insert(ignore,p.Character) end');
 expect(prepared).toContain('blockedBy=hit and hit.Instance:GetFullName() or false');
 expect(prepared).toContain('blockedDistance=hit and hit.Distance or false');
});

// Eight consecutive stalls is the driver's give-up point. The failure must keep the bounded log so
// the receipt shows whether the actor oscillated or was pinned, and by what.
test('a repeated stall failure retains a bounded log of positions and the blocking instance',async()=>{
 let step=0;
 const execute=async(_id,_model,code)=>{
  if(code.includes('local delta='))return {distance:12,keys:['W'],position:[0,0,0]};
  if(code.includes('movement subscription missing')){
   const row={stall:true,keys:['W'],input:true,distance:12-step*0.1,position:[step,3,18-step*0.05],target:'Workspace.DevelopmentIsland.fallen-tree-01',targetPosition:[-20,2,14],blockedBy:'Workspace.DevelopmentIsland.flint-outcrop-01',blockedDistance:3.2};
   step+=1;
   return row;}
  return {clean:true};};
 let failure;
 try{await gameplay({op:'walk_to',target:'Workspace.Node',withinStuds:6,timeout_seconds:5},{studioId:'owned'},execute,async()=>{});}
 catch(error){failure=error;}
 expect(failure).toBeDefined();
 expect(failure.message).toContain('walk_to stalled repeatedly against geometry');
 const log=JSON.parse(failure.message.slice(failure.message.indexOf('[')));
 expect(log).toHaveLength(9);
 expect(log[0].blockedBy).toBe('Workspace.DevelopmentIsland.flint-outcrop-01');
 expect(log[0].keys).toEqual(['W']);
 expect(log[0].input).toBe(true);
 expect(log[0].target).toBe('Workspace.DevelopmentIsland.fallen-tree-01');
 expect(new Set(log.map(row=>row.position[0])).size).toBe(9);
});

test('the stall log is bounded even when the geometry never yields',async()=>{
 const execute=async(_id,_model,code)=>{
  if(code.includes('local delta='))return {distance:12,keys:['W'],position:[0,0,0]};
  if(code.includes('movement subscription missing'))return {stall:true,keys:['W'],input:true,distance:11.9,position:[0,3,18],blockedBy:false,blockedDistance:false};
  return {clean:true};};
 let failure;
 try{await gameplay({op:'walk_to',target:'Workspace.Node',withinStuds:6,timeout_seconds:5},{studioId:'owned'},execute,async()=>{});}
 catch(error){failure=error;}
 const log=JSON.parse(failure.message.slice(failure.message.indexOf('[')));
 expect(log.length).toBeLessThanOrEqual(12);
 expect(log[0].blockedBy).toBe(false);
});

// The direction contract: a target off both camera axes needs the axis pair, and a segment counts
// only when it closes distance. Pressing one alternating axis let a segment satisfy its raw
// displacement while the gap stood still, which is how a walk could spend every segment and never
// arrive.
test('the emitted walk_to presses the camera axis pair and requires closing distance',async()=>{
 const calls=[];
 let preparedCalls=0;
 const execute=async(_id,_model,code)=>{calls.push(code);
  if(code.includes('local delta=')){preparedCalls+=1;return preparedCalls===1?{distance:30,keys:['W'],position:[0,0,0]}:{distance:2,keys:['W'],position:[0,0,0]};}
  if(code.includes('movement subscription missing'))return {input:true,distance:6,position:[0,0,0]};
  return {clean:true};};
 await gameplay({op:'walk_to',target:'Workspace.Node',withinStuds:3,timeout_seconds:5},{studioId:'owned'},execute,async()=>{});
 const prepared=calls.find(code=>code.includes('local delta='));
 expect(prepared).toContain("local alongF=math.abs(f)>=0.2*magnitude");
 expect(prepared).toContain("elseif alongF and alongR then {if f>=0 then 'W' else 'S',if r>=0 then 'D' else 'A'}");
 expect(prepared).toContain('value.keys=keys');
 expect(prepared).toContain('delta.Magnitude-d.Magnitude>=math.min(2,delta.Magnitude-3)');
 expect(prepared).not.toContain('(root.Position-start).Magnitude>=');
 expect(prepared).not.toContain('value.key=code');
});

// The pair is real keyboard input through the existing multi-action call: both keys go down before
// the segment and both are released in the finally, whatever the outcome.
test('a diagonal target presses and releases both camera keys',async()=>{
 const actions=[];
 let preparedCalls=0;
 const execute=async(_id,_model,code)=>{
  if(code.includes('local delta=')){preparedCalls+=1;return preparedCalls===1?{distance:30,keys:['W','D'],position:[0,0,0]}:{distance:2,keys:['W','D'],position:[0,0,0]};}
  if(code.includes('movement subscription missing'))return {input:true,distance:26,position:[1,3,1]};
  return {clean:true};};
 const result=await gameplay({op:'walk_to',target:'Workspace.Node',withinStuds:3,timeout_seconds:5},{studioId:'owned'},execute,async(_name,args)=>{actions.push(...args.actions);});
 expect(result.kind).toBe('gameplay-movement');
 expect(actions).toEqual([{action:'keyDown',key_code:'W'},{action:'keyDown',key_code:'D'},{action:'keyUp',key_code:'W'},{action:'keyUp',key_code:'D'}]);
});

// A segment that never closes the distance is a stall, not a consumed segment: the walk must fail
// closed after the bounded stall allowance instead of spending its whole budget standing still.
test('a segment that never closes the distance stalls instead of consuming the budget',async()=>{
 let preparedCalls=0;
 const execute=async(_id,_model,code)=>{
  if(code.includes('local delta=')){preparedCalls+=1;return {distance:30,keys:['W','D'],position:[0,0,0]};}
  if(code.includes('movement subscription missing'))return {stall:true,keys:['W','D'],input:true,distance:30,position:[0,3,18],target:'Workspace.Node',targetPosition:[-20,2,14],blockedBy:false,blockedDistance:false};
  return {clean:true};};
 let failure;
 try{await gameplay({op:'walk_to',target:'Workspace.Node',withinStuds:3,timeout_seconds:60},{studioId:'owned'},execute,async()=>{});}
 catch(error){failure=error;}
 expect(failure.message).toContain('walk_to stalled repeatedly against geometry');
 const log=JSON.parse(failure.message.slice(failure.message.indexOf('[')));
 expect(log).toHaveLength(9);
 expect(log.every(row=>row.distance===30&&row.keys.join('')==='WD')).toBe(true);
 expect(preparedCalls).toBe(9);
});

test('an own-team walk restricts the candidates to the acting player team',async()=>{
  const calls=[];
  const execute=async(_id,_model,code)=>{
    calls.push(code);
    if(code.includes('liveRoot')) return {ready:true};
    return {distance:1,keys:['W'],position:[0,0,0],target:'Workspace.BlueBase.Incubator1.Base'};
  };
  await expect(gameplay({
    op:'walk_to',
    targets:['Workspace.CollectRaidSweepWorld.BlueBase.Incubator1.Base','Workspace.CollectRaidSweepWorld.RedBase.Incubator1.Base'],
    ownTeam:true,withinStuds:8,timeout_seconds:5,
  },{studioId:'owned'},execute,async()=>{})).rejects.toThrow();
  const prepared=calls.find(code=>code.includes('walk target must be BasePart'));
  expect(prepared).toBeDefined();
  // The filter reads the acting player's own team and refuses a walk with no own-team candidate, so an
  // actor can never walk to the other team's incubator (which would hatch nothing).
  expect(prepared).toContain("game:GetService('Players').LocalPlayer.Team");
  expect(prepared).toContain('if true then');
  expect(prepared).toContain('own-team walk found no candidate');
});

test('a walk without ownTeam keeps every named candidate',async()=>{
  const calls=[];
  const execute=async(_id,_model,code)=>{
    calls.push(code);
    if(code.includes('liveRoot')) return {ready:true};
    return {distance:1,keys:['W'],position:[0,0,0],target:'Workspace.BlueBase.Incubator1.Base'};
  };
  await expect(gameplay({
    op:'walk_to',targets:['Workspace.A','Workspace.B'],withinStuds:8,timeout_seconds:5,
  },{studioId:'owned'},execute,async()=>{})).rejects.toThrow();
  const prepared=calls.find(code=>code.includes('walk target must be BasePart'));
  // Without ownTeam the filter is present but disabled, so every named candidate stays eligible.
  expect(prepared).toContain('if false then');
});
