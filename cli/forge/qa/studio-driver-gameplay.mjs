import { readFileSync } from 'node:fs';
const quote = JSON.stringify;
const pathCode = target => `local target=game;for segment in string.gmatch(${quote(target)},'[^.]+') do target=target:FindFirstChild(segment);assert(target,'target missing') end`;
// A walk names one target or several. With several the actor walks to the nearest,
// which is what makes a capture deterministic in a world whose spawn is not fixed:
// the collect-raid pack spawns the actor in one of two team bases, and a walk to the
// far base's incubator stalls against the near base's own vault crate. The choice is
// the client's (the actor's own root is authoritative there) and the resolved path
// travels back in the walk's evidence, so the server-side reach check measures the
// same instance.
const walkTargetCode = step => {
  if (!Array.isArray(step.targets)) return pathCode(step.target);
  // A candidate that has not replicated yet is skipped rather than fatal: the walk still
  // needs one target, and which base a teamless actor spawned in decides which candidates
  // are the near ones.
  const candidates = step.targets.map(target => `(function() local node=game;for segment in string.gmatch(${quote(target)},'[^.]+') do node=node:FindFirstChild(segment);if node==nil then return nil end end return node end)()`);
  // `ownTeam` restricts the candidates to the ones that belong to the acting player's own
  // team: a two-team pack spawns the actor in one base, and an incubator in the other base
  // refuses the hatch (the scaffold requires the player's team to match the base). Naming
  // both bases' incubators and walking to the nearest would let the actor press E at a
  // foreign base and hatch nothing.
  return `local candidates={}
for _,candidate in {${candidates.join(',')}} do if candidate then table.insert(candidates,candidate) end end
assert(#candidates>0,'walk target missing')
if ${step.ownTeam ? 'true' : 'false'} then
 local team=game:GetService('Players').LocalPlayer.Team
 assert(team,'own-team walk requires an assigned team')
 local name=team.Name
 local filtered={}
 for _,candidate in candidates do if string.find(candidate:GetFullName(),name,1,true) then table.insert(filtered,candidate) end end
 assert(#filtered>0,'own-team walk found no candidate for team '..name)
 candidates=filtered
end
local root0=game:GetService('Players').LocalPlayer.Character and game:GetService('Players').LocalPlayer.Character:FindFirstChild('HumanoidRootPart')
assert(root0,'root missing')
local target=candidates[1]
local best=(target.Position-root0.Position).Magnitude
for index=2,#candidates do local distance=(candidates[index].Position-root0.Position).Magnitude;if distance<best then target,best=candidates[index],distance end end`;
};
// The gather correlation and its per-attempt reset are typed Luau modules that this driver embeds
// verbatim and consumes through their returned factory, so the emitted client code, the module the
// Lune fixture requires, and the fixture itself are one artifact rather than a copy that can drift.
const moduleSource = name => readFileSync(new URL(name, import.meta.url), 'utf8');
const correlationModule = moduleSource('./gathering-correlation.luau');
const resetModule = moduleSource('./gathering-reset.luau');
// A respawn transition (the world's respawn command calls LoadCharacterAsync) can
// leave the LocalPlayer without a character, or with a character whose root is
// not yet attached to the world, while a step starts. Subscribe to the exact
// lifecycle signals BEFORE observing, park on a flag, and fail bounded when no
// root ever appears: the wake path only resumes a parked waiter, so a signal
// delivered while this chunk is still running can never resume the running
// thread, and every connection and timer is released before the final assert.
export const characterReadiness = seconds => `local player=game:GetService('Players').LocalPlayer
local function liveRoot()
 local character=player.Character
 local root=character and character:FindFirstChild('HumanoidRootPart')
 if root and root:IsA('BasePart') and root:IsDescendantOf(workspace) then return root end
 return nil
end
local thread=coroutine.running();local parked=false;local settled=false;local connections={}
local function wake() if parked then parked=false;task.spawn(thread) end end
local function check() if liveRoot() then settled=true;wake() end end
local function watchCharacter(character)
 if character then
  table.insert(connections,character.DescendantAdded:Connect(check))
  table.insert(connections,character.AncestryChanged:Connect(check))
 end
 check()
end
table.insert(connections,player.CharacterAdded:Connect(watchCharacter))
table.insert(connections,player:GetPropertyChangedSignal('Character'):Connect(function() watchCharacter(player.Character) end))
watchCharacter(player.Character)
local timer=task.delay(${seconds},function() settled=true;wake() end)
if not settled then parked=true end
if parked then coroutine.yield() end
for _,connection in connections do connection:Disconnect() end
if coroutine.status(timer)=='suspended' then task.cancel(timer) end
local root=liveRoot();assert(root,'character root missing')
local value={ready=true,position={root.Position.X,root.Position.Y,root.Position.Z}}`;
// Every per-attempt wait is bounded by the step's own budget, and an exhausted
// budget returns zero: the bounded wait then fails immediately instead of
// extending the step with a fresh fixed interval.
export const remainingSeconds = (deadline, cap) => Number.isFinite(deadline) ? Math.max(0, Math.min(cap, (deadline - Date.now()) / 1000)) : cap;
export function resolveReferences(value, bindings) {
  if (value && typeof value === 'object' && !Array.isArray(value) && 'ref' in value) {
    if (Object.keys(value).some(key=>!['ref','prefix','offset'].includes(key)) || (value.prefix!==undefined && typeof value.prefix!=='string') || typeof value.ref !== 'string' || !bindings.has(value.ref)) throw new Error('missing or malformed binding');
    if(value.offset!==undefined) {
      const source=bindings.get(value.ref);
      if(typeof source!=='number' || !Number.isFinite(value.offset)) throw new Error('numeric binding offset required');
      return source+value.offset;
    }
    if(value.prefix!==undefined) return value.prefix+String(bindings.get(value.ref));
    return structuredClone(bindings.get(value.ref));
  }
  if (Array.isArray(value)) return value.map(item => resolveReferences(item, bindings));
  return value;
}

// Each movement segment observes physics frames subscribed before keyDown.
// It does not set position, invoke movement remotes, or use a sleep interval.
export async function gameplay(step, client, execute, call) {
  const id=client.studioId;
  const key = async (action,key_code) => call('user_keyboard_input',{studio_id:id,datamodel_type:'Client',actions:[{action,key_code}]});
  const marker='ForgeQAGameplayProof';
  const cleanup = async () => execute(id,'Client',`local m=game:GetService('Players').LocalPlayer:FindFirstChild('${marker}');if m then m:Destroy() end;local value={clean=true}`);
  const deadline=Date.now()+step.timeout_seconds*1000;
  const evidence=[];
  if(step.op==='walk_to') {
    let secondary=false, stalls=0;
    // A stall is the only record of where the actor actually was and what stopped it. Keep a
    // bounded log so a repeated stall reports positions over time plus the blocking instance
    // instead of a bare message; the payload is produced by the client and is never invented here.
    const stallLog=[];
    for(let segment=0;segment<64;segment++) {
      if(Date.now()>=deadline) throw new Error('walk_to deadline');
      // The same respawn transition can occur between two movement segments, so
      // the root is re-established per segment under what is left of the step
      // budget; a root that never returns still fails the step.
      await execute(id,'Client',characterReadiness(remainingSeconds(deadline,10).toFixed(3)));
      let held;
      try {
        const prepared=await execute(id,'Client',`${walkTargetCode(step)}
assert(target:IsA('BasePart'),'walk target must be BasePart')
local p=game:GetService('Players').LocalPlayer;local root=p.Character and p.Character:FindFirstChild('HumanoidRootPart');assert(root,'root missing')
local delta=target.Position-root.Position;local vertical=math.abs(delta.Y);delta=Vector3.new(delta.X,0,delta.Z)
local value={distance=delta.Magnitude,verticalDistance=vertical,position={root.Position.X,root.Position.Y,root.Position.Z},target=target:GetFullName()}
if delta.Magnitude>${step.withinStuds} then
 assert(not p:FindFirstChild('${marker}'),'proof already exists')
 local m=Instance.new('StringValue');m.Name='${marker}';m.Parent=p
 local camera=workspace.CurrentCamera;local forward=Vector3.new(camera.CFrame.LookVector.X,0,camera.CFrame.LookVector.Z).Unit;local right=Vector3.new(camera.CFrame.RightVector.X,0,camera.CFrame.RightVector.Z).Unit
 local f=delta:Dot(forward);local r=delta:Dot(right)
 -- Both camera axes matter for most targets. Pressing the pair moves toward the target instead of
 -- staircasing along one axis, which is what let a segment satisfy its displacement requirement
 -- without ever closing the gap. A near-axis-aligned target keeps the single dominant key, and the
 -- stall escape retries that single key when the pair cannot make progress.
 local magnitude=math.max(math.abs(f),math.abs(r));local alongF=math.abs(f)>=0.2*magnitude;local alongR=math.abs(r)>=0.2*magnitude
 local keys=if ${secondary ? 'true' : 'false'}
  then {if math.abs(f)>=math.abs(r) then (if f>=0 then 'W' else 'S') else (if r>=0 then 'D' else 'A')}
  elseif alongF and alongR then {if f>=0 then 'W' else 'S',if r>=0 then 'D' else 'A'}
  elseif alongF then {if f>=0 then 'W' else 'S'} else {if r>=0 then 'D' else 'A'}
 value.keys=keys;local start=root.Position;local connections={};local input=false
 table.insert(connections,game:GetService('UserInputService').InputBegan:Connect(function(i) for _,k in keys do if i.KeyCode==Enum.KeyCode[k] then input=true end
 task.delay(1.5,function() if m and m.Parent and m.Value=='' then local d=target.Position-root.Position;d=Vector3.new(d.X,0,d.Z)
 local ignore={target};if p.Character then table.insert(ignore,p.Character) end
 local params=RaycastParams.new();params.FilterType=Enum.RaycastFilterType.Exclude;params.FilterDescendantsInstances=ignore
 local hit=workspace:Raycast(root.Position,Vector3.new(d.X,0,d.Z),params)
 m.Value=game:GetService('HttpService'):JSONEncode({stall=true,keys=keys,input=input,distance=d.Magnitude,position={root.Position.X,root.Position.Y,root.Position.Z},target=target:GetFullName(),targetPosition={target.Position.X,target.Position.Y,target.Position.Z},blockedBy=hit and hit.Instance:GetFullName() or false,blockedDistance=hit and hit.Distance or false}) end end)
 end end))
table.insert(connections,game:GetService('RunService').PostSimulation:Connect(function()
  local d=target.Position-root.Position;d=Vector3.new(d.X,0,d.Z)
  -- Segment goal is progress toward the target, not raw displacement: closing the gap by the
  -- required amount is what makes a segment count, so a sideways or blocked segment cannot consume
  -- the budget while the distance stands still.
  if input and (d.Magnitude<=${step.withinStuds} or delta.Magnitude-d.Magnitude>=math.min(2,delta.Magnitude-${step.withinStuds})) then m.Value=game:GetService('HttpService'):JSONEncode({input=true,distance=d.Magnitude,position={root.Position.X,root.Position.Y,root.Position.Z}}) end
 end))
 m.Destroying:Once(function() for _,c in connections do c:Disconnect() end end)
end`);
        if(prepared.distance<=step.withinStuds) {
          if(step.verticalToleranceStuds!==undefined && prepared.verticalDistance>step.verticalToleranceStuds) throw new Error('walk_to vertical arrival not reached; authored ramp route required');
          if(!evidence.length) throw new Error('walk_to produced no movement proof: already in reach '+JSON.stringify(prepared));
          return {kind:'gameplay-movement',segments:evidence,arrival:prepared};
        }
        held=prepared.keys;
        if(!Array.isArray(held)||held.length<1||held.length>2||!held.every(entry=>['W','A','S','D'].includes(entry))) throw new Error('invalid movement key');
        for(const entry of held) await key('keyDown',entry);
        const moved=await execute(id,'Client',`local m=game:GetService('Players').LocalPlayer:FindFirstChild('${marker}');assert(m,'movement subscription missing')
if m.Value=='' then local _,v=observe(m.Changed,function() return true end,function() return m.Value=='' end,${remainingSeconds(deadline,10).toFixed(3)}) end
assert(m.Value~='','movement event timeout');local value=game:GetService('HttpService'):JSONDecode(m.Value)`);
        if(moved.stall===true) {
          if(stallLog.length<12) stallLog.push(moved);
          if(++stalls>8) throw new Error('walk_to stalled repeatedly against geometry '+JSON.stringify(stallLog));
          secondary=!secondary;
          continue;
        }
        if(moved.input!==true) throw new Error('movement missing actual key input');
        stalls=0; secondary=false;
        evidence.push({before:prepared,after:moved});
      } finally { try { if(held) for(const entry of held) await key('keyUp',entry); } finally { await cleanup(); } }
    }
    throw new Error('movement segment limit exceeded');
  }
  // A spec-node prompt is parented directly to the node part the world builder
  // placed, and the server dispatches the control it is named after. It has no
  // gather relay and no node charges, so it is driven and verified through the
  // committed result the server publishes on ForgeState.
  const shape=await execute(id,'Client',`${pathCode(step.target)}
assert(target:IsA('ProximityPrompt'),'prompt required');local value={specNode=target.Parent:IsA('BasePart'),control=target.Name,nodeId=target.Parent:GetAttribute('ForgeNodeId')}`);
  // A player who walks up to a node looks at it before pressing E, and the engine's
  // own prompt relevance test is a line-of-sight ray from the camera, so the step
  // aims the camera at the node first and restores it afterwards. The camera stands
  // where a player's camera stands - behind the character on the side it walked in
  // from, one shoulder off the axis - so the node's own prop can never sit between
  // the camera and the character: aimed from beyond the node, the node's sign and
  // board covered the character and most of the scene in every thin-genre capture.
  const aimCamera=async()=>{
  await execute(id,'Client',`local p=game:GetService('Players').LocalPlayer
local root=p.Character and p.Character:FindFirstChild('HumanoidRootPart');assert(root,'root missing')
local target=game;for part in string.gmatch(${quote(step.target)},'[^.]+') do target=target:FindFirstChild(part);assert(target,'prompt missing') end
local camera=workspace.CurrentCamera
p:SetAttribute('ForgeQACameraType',camera.CameraType.Name)
camera.CameraType=Enum.CameraType.Scriptable
-- A gather prompt sits on an Attachment, whose Position is local to its node; use the world point.
local at=if target.Parent:IsA('Attachment') then target.Parent.WorldPosition else target.Parent.Position
local approach=Vector3.new(at.X-root.Position.X,0,at.Z-root.Position.Z)
local unit=if approach.Magnitude>1e-3 then approach.Unit else Vector3.new(0,0,-1)
local right=Vector3.new(-unit.Z,0,unit.X)
local eye=root.Position-unit*11+right*4+Vector3.new(0,6,0)
camera.CFrame=CFrame.lookAt(eye,at+Vector3.new(0,1.5,0))
root.CFrame=CFrame.lookAt(root.Position,Vector3.new(at.X,root.Position.Y,at.Z))
local value={aimed=true}`);
  };
  const restoreCamera=async()=>{
    try {
      await execute(id,'Client',`local p=game:GetService('Players').LocalPlayer
local name=p:GetAttribute('ForgeQACameraType')
if name then p:SetAttribute('ForgeQACameraType',nil);workspace.CurrentCamera.CameraType=Enum.CameraType[name] end
local value={restored=name}`);
    } catch {}
  };
  if(shape.specNode===true) {
    if(shape.nodeId!==step.nodeId) throw new Error('prompt node mismatch: '+JSON.stringify(shape));
    const control=shape.control;
    // Subscribe BEFORE the camera aim. A prompt that became relevant while the actor walked in has
    // already fired PromptShown, so a subscription installed after that would never observe it; the
    // aim is a fresh relevance change, and the subscription must exist when it happens. Then press E
    // and wait for the committed result the server publishes. The engine's own prompt activation
    // decides whether the press lands, so a press that produced nothing is retried inside the step's
    // budget and a final failure reports what the client saw (was the prompt relevant, did
    // PromptTriggered fire, was the player in range) instead of a bare timeout.
    await execute(id,'Client',`local p=game:GetService('Players').LocalPlayer
local stale=p:FindFirstChild('${marker}');if stale then stale:Destroy() end
local proof=Instance.new('StringValue');proof.Name='${marker}';proof.Value='';proof.Parent=p
local target=game;for part in string.gmatch(${quote(step.target)},'[^.]+') do target=target:FindFirstChild(part);assert(target,'prompt missing') end
local service=game:GetService('ProximityPromptService')
local state=game:GetService('ReplicatedStorage'):WaitForChild('ForgeState')
local connections={}
table.insert(connections,service.PromptShown:Connect(function(prompt) proof:SetAttribute('Shown',prompt:GetFullName());if prompt==target then proof:SetAttribute('Relevant',true) end end))
table.insert(connections,service.PromptHidden:Connect(function(prompt) if prompt==target then proof:SetAttribute('Relevant',false) end end))
table.insert(connections,service.PromptTriggered:Connect(function(prompt) proof:SetAttribute('Fired',prompt:GetFullName());if prompt==target then proof:SetAttribute('Triggered',true) end end))
table.insert(connections,state.OnClientEvent:Connect(function(packet)
 if type(packet)=='table' and packet.control==${quote(control)} and type(packet.result)=='table' then
  proof.Value=game:GetService('HttpService'):JSONEncode({control=packet.control,result=packet.result})
 end
end))
proof.Destroying:Once(function() for _,connection in connections do connection:Disconnect() end end)
local value={subscribed=true,control=${quote(control)}}`);
    await aimCamera();
    const promptDiagnostics=async() => {
      try {
        const value=await execute(id,'Client',`local p=game:GetService('Players').LocalPlayer
local proof=p:FindFirstChild('${marker}')
local target=game;for part in string.gmatch(${quote(step.target)},'[^.]+') do target=target:FindFirstChild(part) end
local root=p.Character and p.Character:FindFirstChild('HumanoidRootPart')
local value={shown=proof and proof:GetAttribute('Shown'),fired=proof and proof:GetAttribute('Fired'),relevant=proof and proof:GetAttribute('Relevant'),triggered=proof and proof:GetAttribute('Triggered'),promptEnabled=target and target.Enabled,serviceEnabled=game:GetService('ProximityPromptService').Enabled,maxDistance=target and target.MaxActivationDistance,requiresLineOfSight=target and target.RequiresLineOfSight,distance=(root and target and (target.Parent.Position-root.Position).Magnitude)}
-- Every prompt the character could activate, so a neighbouring prompt stealing the key is visible rather than inferred.
if root then
 local nearby={}
 for _, descendant in workspace:GetDescendants() do
  if descendant:IsA('ProximityPrompt') and descendant.Parent:IsA('BasePart') then
   local d=(descendant.Parent.Position-root.Position).Magnitude
   if d<=20 then table.insert(nearby,{name=descendant:GetFullName(),distance=d,enabled=descendant.Enabled}) end
  end
 end
 value.nearby=nearby
end`);
        return JSON.stringify(value);
      } catch(error) { return 'diagnostics failed: '+String(error && error.message); }
    };
    let packet=null, diagnostics=null, activation='key', engine=null;
    try {
      for(let attempt=0;attempt<8 && Date.now()<deadline;attempt++) {
        // A real key press is the primary path. The engine shows a prompt only when it
        // considers it relevant, and for a server-owned prompt that decision has been
        // observed to fail on a client that is standing in range; after the key presses
        // have had their budget, the engine's own prompt activation API is used and the
        // step records which path activated it, so the evidence never claims a key press
        // that did not happen. That API path is a DIAGNOSTIC only: it is labelled
        // `prompt-hold-diagnostic` and the world-path gate refuses it, because it does not
        // prove the owner can find and use the prompt with ordinary input.
        const hold=attempt>=3;
        await execute(id,'Client',`local proof=game:GetService('Players').LocalPlayer:FindFirstChild('${marker}');assert(proof,'prompt proof missing');proof.Value='';local value={cleared=true}`);
        if(hold) {
          await execute(id,'Client',`local target=game;for part in string.gmatch(${quote(step.target)},'[^.]+') do target=target:FindFirstChild(part);assert(target,'prompt missing') end
assert(target:IsA('ProximityPrompt'),'prompt required');target:InputHoldBegin();task.wait(0.1);target:InputHoldEnd();local value={holdCompleted=true}`);
        } else {
          await key('keyDown','E');
        }
        try {
          packet=await execute(id,'Client',`local proof=game:GetService('Players').LocalPlayer:FindFirstChild('${marker}');assert(proof,'prompt proof missing')
if proof.Value=='' then observe(proof.Changed,function() return true end,function() return proof.Value=='' end,${remainingSeconds(deadline,6).toFixed(3)}) end
assert(proof.Value~='','prompt result timeout');local value=game:GetService('HttpService'):JSONDecode(proof.Value)`);
          activation=hold ? 'prompt-hold-diagnostic' : 'key';
          // The Shown/Triggered evidence is read HERE, while the proof object still exists:
          // cleanup destroys it, so a read after cleanup reported false even after a genuine
          // successful activation.
          engine=await execute(id,'Client',`local proof=game:GetService('Players').LocalPlayer:FindFirstChild('${marker}')
local value={shown=proof and proof:GetAttribute('Shown')~=nil,triggered=proof and proof:GetAttribute('Triggered')==true,relevant=proof and proof:GetAttribute('Relevant')==true}`);
        } catch(error) {
          diagnostics=await promptDiagnostics();
          // Attribute the failure on the client: the world-feedback layer wears the
          // spec's declared outfit when the snapshot says it is equipped, so the
          // accessory's presence tells a prompt that never triggered apart from a
          // result relay that never arrived.
          try {
            const effect=await execute(id,'Client',`local p=game:GetService('Players').LocalPlayer
local character=p.Character
local worn={}
if character then for _, child in character:GetChildren() do if child.Name:sub(1,12)=='ForgeOutfit-' then table.insert(worn,child.Name) end end end
local value={worn=worn,hasCharacter=character~=nil,humanoid=(character and character:FindFirstChildOfClass('Humanoid')~=nil)}`);
            diagnostics=JSON.stringify({client:JSON.parse(diagnostics),worldEffect:effect}).slice(0,4000);
          } catch(probeError) { diagnostics=String(diagnostics)+' | effect probe failed: '+String(probeError&&probeError.message); }
        } finally { if(!hold) await key('keyUp','E'); }
        if(packet!==null) break;
        await new Promise(resolve=>setTimeout(resolve,1000));
      }
    } finally { await cleanup(); await restoreCamera(); }
    if(packet===null) throw new Error('prompt result missing after retries: '+String(diagnostics));
    if(packet.control!==control) throw new Error('wrong control result: '+JSON.stringify(packet));
    if(packet.result.ok !== (step.expect!=='refused')) throw new Error('unexpected prompt result: '+JSON.stringify(packet));
    // Which engine path activated the prompt is evidence, not a detail: a run that only
    // succeeded through the prompt hold API is not the same proof as one where the engine
    // showed the prompt to the player and the key press triggered it. `activation` carries
    // `key` for a real key press and `prompt-hold-diagnostic` for the API fallback, which
    // the world-path gate refuses.
    return {kind:'gameplay-prompt',specNode:true,nodeId:step.nodeId,control:packet.control,activation:activation,engineShown:engine?engine.shown===true:false,engineTriggered:engine?engine.triggered===true:false,engineRelevant:engine?engine.relevant===true:false,result:packet.result};
  }
  try {
    await execute(id,'Client',`${pathCode(step.target)}
assert(target:IsA('ProximityPrompt') and target.Name=='ForgeGather','wrong gather prompt')
local node=target.Parent.Parent;assert(target.Parent:IsA('Attachment') and node:IsA('BasePart'),'wrong anchor')
assert(node:GetAttribute('ForgeNodeId')==${quote(step.nodeId)},'wrong node')
local p=game:GetService('Players').LocalPlayer;local relay=p:FindFirstChild('ForgeGatherResult');assert(relay and relay:IsA('BindableEvent'),'gather relay missing')
assert(not p:FindFirstChild('${marker}'),'proof already exists')
local m=Instance.new('StringValue');m.Name='${marker}';m.Parent=p
local version=node:GetAttribute('ForgeNodeVersion');assert(type(version)=='number','confirmed node version missing');m:SetAttribute('BeforeVersion',version)
local requested=p:FindFirstChild('ForgeGatherRequested');assert(requested and requested:IsA('BindableEvent'),'gather request telemetry missing')
local connections={}
local ForgeQACorrelation=(function()
${correlationModule}
end)()
ForgeQACorrelation.install({input=game:GetService('UserInputService'),prompt=game:GetService('ProximityPromptService'),keyE=Enum.KeyCode.E,now=function() return workspace:GetServerTimeNow() end,encode=function(value) return game:GetService('HttpService'):JSONEncode(value) end},m,target,${quote(step.nodeId)},relay,requested,connections)
m.Destroying:Once(function() for _,c in connections do c:Disconnect() end end)
local value={subscribed=true}`);
    // Neighbouring nodes share the E key (the landing's fallen tree and flint outcrop are 10 studs apart,
    // both inside the 8-stud range from the walk's arrival), and the engine gives the key to the prompt
    // nearest the camera's view: with the camera left behind from the walk the press gathered the flint
    // (tutorial QA, step 72). Look at this node first, as a player does, so the press goes to it.
    await aimCamera();
    let requestId;
    // settledRefusal: the last correlated result ended the client's request (a refusal that
    // decided against the frozen payload, or an expired epoch), so the next activation
    // allocates a fresh identity. consumed: the previous attempt read a correlated packet,
    // so its value has been consumed and must not be re-read as this attempt's result.
    let waitDiagnostics=null, lastRefused=null, settledRefusal=false, consumed=false;
    const promptDiagnostics=async why => {
      try {
        const state=await execute(id,'Client',`local m=game:GetService('Players').LocalPlayer:FindFirstChild('${marker}')
${pathCode(step.target)}
local p=game:GetService('Players').LocalPlayer;local char=p.Character and p.Character:FindFirstChild('HumanoidRootPart')
local blocked,blockedKind,lineOfSightRaycast
if char then
 local function classify(instance)
  if instance:IsDescendantOf(p.Character) then return 'own-character' end
  local model=instance:FindFirstAncestorOfClass('Model')
  if model and game:GetService('Players'):GetPlayerFromCharacter(model) then return 'other-character' end
  return 'world'
 end
 -- A bare instance name cannot say whose limb or which prop was hit, so the full path and the owner class travel with it.
 local params=RaycastParams.new(); params.FilterType=Enum.RaycastFilterType.Exclude; params.FilterDescendantsInstances={target,p.Character}
 local hit=workspace:Raycast(char.Position, target.Parent.WorldPosition-char.Position, params)
 blocked=hit and hit.Instance:GetFullName() or false; blockedKind=hit and classify(hit.Instance) or false
 -- ProximityPrompt exposes no line-of-sight query, so this is an INFERENCE, not the engine's verdict:
 -- a ray from the character's head to the prompt's world position with the character and the prompt
 -- excluded, which is the shape the engine's own occlusion test takes. It is reported separately from
 -- the RequiresLineOfSight property and labelled so neither is read as the other.
 local head=p.Character:FindFirstChild('Head') or char
 local losParams=RaycastParams.new(); losParams.FilterType=Enum.RaycastFilterType.Exclude; losParams.FilterDescendantsInstances={p.Character,target}
 lineOfSightRaycast=workspace:Raycast(head.Position, target.Parent.WorldPosition-head.Position, losParams)==nil
end
local value={why=${quote(why)},input=m and m:GetAttribute('Input'),triggered=m and m:GetAttribute('Triggered'),packets=m and m:GetAttribute('Packets'),relevant=m and m:GetAttribute('Relevant'),marker=m and m.Value,enabled=target.Enabled,lineOfSight=target.RequiresLineOfSight,lineOfSightRaycast=lineOfSightRaycast,lineOfSightRaycastKind='inferred-raycast',policyReady=m and m:GetAttribute('PolicyReady'),requestIdLog=m and m:GetAttribute('RequestIdLog'),packetIdLog=m and m:GetAttribute('PacketIdLog'),requestedInstances=(function() local n=0;for _,c in p:GetChildren() do if c.Name=='ForgeGatherRequested' then n+=1 end end;return n end)(),holdDuration=target.HoldDuration,maxDistance=target.MaxActivationDistance,serviceEnabled=game:GetService('ProximityPromptService').Enabled,distance=char and (target.Parent.WorldPosition-char.Position).Magnitude,blockedBy=blocked,blockedKind=blockedKind}`);
        return JSON.stringify(state);
      } catch(error) { return 'diagnostic failed: '+String(error && error.message); }
    };
    for(let attempt=0;attempt<12 && (!Number.isFinite(deadline) || Date.now()<deadline);attempt++) {
    // The engine can only trigger the prompt and the source can only accept the
    // gather while the character has a live root; a respawn between attempts is
    // absorbed here instead of surfacing as a missing gather result.
    await execute(id,'Client',characterReadiness(remainingSeconds(deadline,10).toFixed(3)));
    // The reset is per dispatch, not per attempt. While the client still holds the request
    // its late result carries the same identity, so both that identity and any value it
    // already wrote survive; only a result that ended the request is cleared, because only
    // then does the next activation allocate a fresh identity. A consumed packet is dropped
    // so this attempt waits for its own result instead of re-reading the previous one.
    const clearValue=consumed, clearIdentity=settledRefusal;
    consumed=false;
    await execute(id,'Client',`local m=game:GetService('Players').LocalPlayer:FindFirstChild('${marker}');assert(m,'prompt subscription missing')
local ForgeQAReset=(function()
${resetModule}
end)()
local value=ForgeQAReset.reset(m,${clearValue},${clearIdentity})`);
    await key('keyDown','E');
    let packet;
    try {
      packet=await execute(id,'Client',`local m=game:GetService('Players').LocalPlayer:FindFirstChild('${marker}');assert(m,'prompt subscription missing')
if m.Value=='' then observe(m.Changed,function() return true end,function() return m.Value=='' end,${remainingSeconds(deadline,10).toFixed(3)}) end
assert(m.Value~='' and m.Value~='INVALID','correlated gather result missing');local value=game:GetService('HttpService'):JSONDecode(m.Value)
${pathCode(step.target)}
local node=target.Parent.Parent
if value.result and value.result.ok then
if node:GetAttribute('ForgeNodeVersion')<=m:GetAttribute('BeforeVersion') then observe(node:GetAttributeChangedSignal('ForgeNodeVersion'),function() return true end,function() return node:GetAttribute('ForgeNodeVersion')<=m:GetAttribute('BeforeVersion') end,${remainingSeconds(deadline,10).toFixed(3)}) end
assert(node:GetAttribute('ForgeNodeVersion')>m:GetAttribute('BeforeVersion'),'confirmed node version did not advance')
end`);
      consumed=true;
    } catch(error) {
      try { await key('keyUp','E'); } catch {}
      waitDiagnostics=await promptDiagnostics('attempt '+attempt+': '+String(error && error.message));
      await new Promise(resolve=>setTimeout(resolve,500));
      continue;
    }
    await key('keyUp','E');
    if(packet.nodeId!==step.nodeId || typeof packet.requestId!=='string') throw new Error('wrong node or request: '+JSON.stringify(packet));
    // The client keeps one identity while a request is unresolved, so a changed identity
    // means it settled the previous request. Only a result that ended it (a refusal that
    // decided against the frozen payload, or an expired epoch) may do that, and the next
    // activation re-reads the published attributes under a fresh identity.
    if(requestId!==undefined && packet.requestId!==requestId && !settledRefusal) throw new Error('request identity changed while unresolved: '+JSON.stringify(packet));
    requestId=packet.requestId;
    settledRefusal=!!(packet.result && (packet.result.reason==='STALE_VERSION' || packet.result.reason==='REQUEST_EXPIRED'));
    const expectedRefusal=step.expect==='refused' && packet.result && packet.result.reason===step.reason;
    if(!expectedRefusal && packet.result && packet.result.ok===false
        && ((packet.result.data && (packet.result.data.status==='pending' || packet.result.data.status==='recovering'))
          || ['COMMAND_PENDING','SOURCE_BUSY','STALE_VERSION','UNAUTHORIZED','NODE_UNREACHABLE'].includes(packet.result.reason))) {
      lastRefused=packet;
      await new Promise(resolve=>setTimeout(resolve,1000));
      continue;
    }
    if(packet.result?.ok !== (step.expect!=='refused') || (step.expect==='refused' && packet.result.reason!==step.reason)) throw new Error('unexpected terminal gather result: '+JSON.stringify(packet));
    return {kind:'gameplay-prompt',...packet};
    }
    if(waitDiagnostics!==null) throw new Error('gather result wait failed ['+waitDiagnostics+']');
    if(lastRefused) throw new Error('unexpected terminal gather result: '+JSON.stringify(lastRefused));
    throw new Error('terminal gather result missing');
  } finally { try { await key('keyUp','E'); } finally { try { await cleanup(); } finally { await restoreCamera(); } } }
}
