// Product input plus exact event predicates. No business state is written here.
const literal = value => value == null ? 'nil' : typeof value === 'object'
  ? `{${Object.entries(value).map(([k,v])=>`[${Array.isArray(value)?Number(k)+1:literal(k)}]=${literal(v)}`).join(',')}}`
  : JSON.stringify(value);
const locate = (path, name='target') => `local ${name}=game;for _,segment in ${literal(Array.isArray(path)?path:path.split('.'))} do
 if segment=='LocalPlayer' then ${name}=game:GetService('Players').LocalPlayer
 elseif segment=='Character' and ${name}:IsA('Player') then ${name}=${name}.Character
 else ${name}=${name}:FindFirstChild(segment) end;assert(${name},'instance missing: '..segment) end`;
const marker='ForgeQAExactInput';
// The transport raises on a refused tools/call, so a refusal arrives as an exception while a success
// arrives as the parsed MCP result. Both reduce to the same verdict, and `accepted` is read from the
// parsed isError field of that result - never from the mere presence of a non-empty string. The
// bounded ack is retained so a refusal is distinguishable from an accepted-but-silent injection.
const boundedAck = value => { try { return JSON.stringify(value ?? null).slice(0,200); } catch { return String(value).slice(0,200); } };
const refusedResult = error => {
  // StdioMcp.call reports `${tool}: ${JSON.stringify(result)}`, so the parsed MCP result is recoverable
  // from the raised error instead of being guessed from its text.
  const message = String(error && error.message || error);
  const payload = message.slice(message.indexOf(':') + 1).trim();
  let parsed; try { parsed = JSON.parse(payload); } catch { parsed = undefined; }
  return parsed && parsed.isError === true ? parsed : null;
};
const injectInput = async (call, args, label) => {
  let result;
  try { result = await call('user_mouse_input', args); }
  catch (error) {
    const refusal = refusedResult(error);
    // A transport failure is not a product refusal: the injection was never confirmed, so it is
    // re-raised unchanged rather than being mislabelled as a refusal.
    if (!refusal) throw error;
    throw new Error(`${label} injection refused: ${boundedAck(refusal)}`);
  }
  if (result && result.isError === true) throw new Error(`${label} injection refused: ${boundedAck(result)}`);
  return { accepted: true, ack: boundedAck(result) };
};
export function predicateCode(predicate, genre, userId) {
  const getter=predicate.source==='snapshot'
    ? `local qa=game:GetService('ServerStorage').ForgeQA
local function sample() local value=qa.snapshot:Invoke(${literal(genre)},${literal(userId)});for _,key in ${literal(Array.isArray(predicate.field)?predicate.field:predicate.field.split('.'))} do value=if type(value)=='table' then value[key] else nil end;return value end
local signal=qa.StateChanged.Event`
    : `${locate(predicate.target)}
local function sample() return ${predicate.source==='attribute'?`target:GetAttribute(${literal(predicate.field)})`:`target[${literal(predicate.field)}]`} end
local signal=${predicate.source==='attribute'?`target:GetAttributeChangedSignal(${literal(predicate.field)})`:`target:GetPropertyChangedSignal(${literal(predicate.field)})`}`;
  const condition='equals' in predicate?`value==${literal(predicate.equals)}`:'not_equals' in predicate?`value~=${literal(predicate.not_equals)}`:'at_least' in predicate?`type(value)=='number' and value>=${literal(predicate.at_least)}`:'at_most' in predicate?`type(value)=='number' and value<=${literal(predicate.at_most)}`:`(value==nil)==${literal(predicate.is_nil)}`;
  return `${getter}
local function matches() local value=sample();return ${condition} end`;
}
export async function inputStep(step, client, serverId, genre, execute, call) {
  if(step.op==='keyboard' && (step.hold_seconds!==undefined || step.hold_prompt!==undefined)) {
    // A prompt with a HoldDuration only triggers after the key is held for that long, so a
    // single keyPress can never prove it. The hold is injected as a real keyDown/keyUp pair
    // through the product input tool, and the engine's own InputBegan/InputEnded for that key
    // is the evidence: a hold the client never observed, or one shorter than requested, fails.
    const holdMarker='ForgeQAHold';
    let restoreCamera=null;
    const cleanup=async()=>execute(client.studioId,'Client',`local p=game:GetService('Players').LocalPlayer;local m=p:FindFirstChild('${holdMarker}');if m then m:Destroy() end;local value={clean=true}`);
    try {
      const prepared=await execute(client.studioId,'Client',`local p=game:GetService('Players').LocalPlayer
assert(not p:FindFirstChild('${holdMarker}'),'hold observer already exists')
local m=Instance.new('StringValue');m.Name='${holdMarker}';m.Parent=p
local began,ended=false,false
local connections={}
local function finish() if m.Parent and m.Value=='' and began and ended then m.Value=game:GetService('HttpService'):JSONEncode({began=true,ended=true}) end end
table.insert(connections,game:GetService('UserInputService').InputBegan:Connect(function(i) if i.KeyCode==Enum.KeyCode[${literal(step.key)}] then began=true;finish() end end))
table.insert(connections,game:GetService('UserInputService').InputEnded:Connect(function(i) if i.KeyCode==Enum.KeyCode[${literal(step.key)}] then ended=true;finish() end end))
m.Destroying:Once(function() for _,c in connections do c:Disconnect() end end)
local value={subscribed=true}`);
      if(!prepared.subscribed) throw new Error('hold subscription missing');
      let holdSeconds=step.hold_seconds;
      let promptRead=null;
      let holdPromptCandidates=null;
      if(step.hold_prompt!==undefined) {
        // The real prompt's own HoldDuration decides the hold: the scaffold's incubator holds 0.4s,
        // and a shorter press would be an activation the engine never commits. A list of candidate
        // paths is accepted (the incubator's team base is decided at runtime) and the NEAREST one to
        // the actor supplies the duration - the same rule the walk uses, so the prompt held is the one
        // the actor actually walked to rather than whichever candidate happens to resolve first.
        const paths = Array.isArray(step.hold_prompt) ? step.hold_prompt : [step.hold_prompt];
        const resolve = paths.map(path => `(function() local node=game;for segment in string.gmatch(${literal(path)},'[^.]+') do node=node:FindFirstChild(segment);if node==nil then return nil end end return node end)()`);
        holdPromptCandidates=resolve;
        promptRead=await execute(client.studioId,'Client',`local candidates={}
for _,candidate in {${resolve.join(',')}} do if candidate and candidate:IsA('ProximityPrompt') then table.insert(candidates,candidate) end end
assert(#candidates>0,'hold_prompt requires an existing ProximityPrompt')
local p=game:GetService('Players').LocalPlayer;local root=p.Character and p.Character:FindFirstChild('HumanoidRootPart')
local function at(instance) if instance:IsA('BasePart') then return instance.Position end local model=instance:FindFirstAncestorOfClass('Model') if model and model.PrimaryPart then return model.PrimaryPart.Position end return instance:GetPivot().Position end
local prompt=candidates[1]
if root then local best=(at(prompt.Parent)-root.Position).Magnitude
 for index=2,#candidates do local d=(at(candidates[index].Parent)-root.Position).Magnitude;if d<best then prompt,best=candidates[index],d end end end
local value={holdDuration=prompt.HoldDuration,name=prompt:GetFullName()}`);
        holdSeconds=(Number(promptRead.holdDuration)||0)+0.3;
      }
      if(!Number.isFinite(holdSeconds) || holdSeconds<=0) throw new Error('hold duration required');
      // A player looks at the prompt before pressing its key: the engine only activates the prompt its
      // own UI is showing, and the walk can leave the camera pointing away from the incubator. The
      // camera is aimed at the chosen prompt for the hold and restored afterwards.
      if(holdPromptCandidates!==null) {
        await execute(client.studioId,'Client',`local p=game:GetService('Players').LocalPlayer
local root=p.Character and p.Character:FindFirstChild('HumanoidRootPart');assert(root,'root missing')
local candidates={}
for _,candidate in {${holdPromptCandidates.join(',')}} do if candidate and candidate:IsA('ProximityPrompt') then table.insert(candidates,candidate) end end
assert(#candidates>0,'hold_prompt requires an existing ProximityPrompt')
local function at(instance) if instance:IsA('BasePart') then return instance.Position end local model=instance:FindFirstAncestorOfClass('Model') if model and model.PrimaryPart then return model.PrimaryPart.Position end return instance:GetPivot().Position end
local prompt=candidates[1]
local best=(at(prompt.Parent)-root.Position).Magnitude
for index=2,#candidates do local d=(at(candidates[index].Parent)-root.Position).Magnitude;if d<best then prompt,best=candidates[index],d end end
local camera=workspace.CurrentCamera
p:SetAttribute('ForgeQACameraType',camera.CameraType.Name)
camera.CameraType=Enum.CameraType.Scriptable
local target=at(prompt.Parent)
local approach=Vector3.new(target.X-root.Position.X,0,target.Z-root.Position.Z)
local unit=if approach.Magnitude>1e-3 then approach.Unit else Vector3.new(0,0,-1)
local right=Vector3.new(-unit.Z,0,unit.X)
camera.CFrame=CFrame.lookAt(root.Position-unit*11+right*4+Vector3.new(0,6,0),target+Vector3.new(0,1.5,0))
local value={aimed=true,name=prompt:GetFullName()}`);
        restoreCamera=async()=>{
          try {
            await execute(client.studioId,'Client',`local p=game:GetService('Players').LocalPlayer
local name=p:GetAttribute('ForgeQACameraType')
if name then p:SetAttribute('ForgeQACameraType',nil);workspace.CurrentCamera.CameraType=Enum.CameraType[name] end
local value={restored=name}`);
          } catch {}
        };
      }
      // The prompt is observed as it triggers, so a hold that produced nothing is attributed to the
      // prompt (its range, its line-of-sight rule, its own duration) instead of surfacing later as an
      // unexplained wait timeout. The hold is retried while the prompt has not triggered.
      let triggered=false, attempts=0, diagnostic=null;
      for(attempts=1;attempts<=5 && !triggered;attempts++) {
        await execute(client.studioId,'Client',`local p=game:GetService('Players').LocalPlayer
local m=p:FindFirstChild('ForgeQAHoldTrigger')
if m then m:Destroy() end
local flag=Instance.new('BoolValue');flag.Name='ForgeQAHoldTrigger';flag.Value=false;flag.Parent=p
local connections={}
local service=game:GetService('ProximityPromptService')
table.insert(connections,service.PromptTriggered:Connect(function(prompt) flag.Value=true end))
-- Whether the engine's own prompt system saw the hold BEGIN is the fact that separates "the key never
-- reached the prompt" from "the hold was too short", so it is recorded alongside the trigger.
local began=Instance.new('BoolValue');began.Name='ForgeQAHoldBegan';began.Value=false;began.Parent=p
table.insert(connections,service.PromptButtonHoldBegan:Connect(function(prompt) began.Value=true end))
flag.Destroying:Once(function() for _,c in connections do c:Disconnect() end end)
local value={subscribed=true}`);
        const started=Date.now();
        // ONE key-down held for the window. Re-asserting the key-down would restart the engine's hold
        // timer on every repeat, so the prompt would never reach its HoldDuration; the retry below is
        // what absorbs an attempt the engine did not begin at all.
        await call('user_keyboard_input',{studio_id:client.studioId,datamodel_type:'Client',actions:[{action:'keyDown',key_code:step.key}]});
        await new Promise(resolve=>setTimeout(resolve,Math.ceil((holdSeconds+0.3*(attempts-1))*1000)));
        await call('user_keyboard_input',{studio_id:client.studioId,datamodel_type:'Client',actions:[{action:'keyUp',key_code:step.key}]});
        const elapsed=(Date.now()-started)/1000;
        const value=await execute(client.studioId,'Client',`local p=game:GetService('Players').LocalPlayer
local flag=p:FindFirstChild('ForgeQAHoldTrigger');local triggered=flag~=nil and flag.Value==true
if flag then flag:Destroy() end
local beganFlag=p:FindFirstChild('ForgeQAHoldBegan');local engineBegan=beganFlag~=nil and beganFlag.Value==true
if beganFlag then beganFlag:Destroy() end
local m=p:FindFirstChild('${holdMarker}');assert(m,'hold observer missing')
if m.Value=='' then observe(m.Changed,function() return true end,function() return m.Value=='' end,${literal(step.timeout_seconds)}) end
assert(m.Value~='','hold input not observed by the client');local value=game:GetService('HttpService'):JSONDecode(m.Value)
value.triggered=triggered
value.engineHoldBegan=engineBegan
-- The prompt the hold was aimed at, with the facts that decide whether the engine may activate it:
-- its own range and line-of-sight rule, the distance from the actor's root to its parent's pivot, and
-- whether the actor's team is the team the prompt belongs to.
local chosen=nil
for _,candidate in {${holdPromptCandidates?holdPromptCandidates.join(','):''}} do if candidate and candidate:IsA('ProximityPrompt') then
 local root=p.Character and p.Character:FindFirstChild('HumanoidRootPart')
 local pivot=candidate.Parent:GetPivot().Position
 if chosen==nil or (root and (pivot-root.Position).Magnitude < chosen.distance) then
  chosen={name=candidate:GetFullName(),enabled=candidate.Enabled,requiresLineOfSight=candidate.RequiresLineOfSight,maxActivationDistance=candidate.MaxActivationDistance,holdDuration=candidate.HoldDuration,keyboardKey=candidate.KeyboardKeyCode.Name,parentClass=candidate.Parent.ClassName,promptTeam=candidate.Parent:GetAttribute('Team'),actorTeam=if p.Team then p.Team.Name else nil,distance=if root then (pivot-root.Position).Magnitude else nil}
 end
end end
value.prompt=chosen`);
        if(value.began!==true || value.ended!==true) throw new Error('hold key was not observed as InputBegan+InputEnded');
        if(elapsed < holdSeconds-0.05) throw new Error('hold ended early: '+elapsed.toFixed(3)+'s of '+holdSeconds.toFixed(3)+'s');
        triggered=value.triggered===true;
        if(!triggered) await new Promise(resolve=>setTimeout(resolve,600));
        diagnostic=value;
      }
      if(!triggered) throw new Error('hold did not trigger the prompt (engineHoldBegan='+String(diagnostic&&diagnostic.engineHoldBegan)+'): '+JSON.stringify(diagnostic&&diagnostic.prompt));
      return {kind:'keyboard-hold',key:step.key,holdSeconds,prompt:promptRead,attempts,elapsedSeconds:diagnostic.elapsedSeconds,observed:{began:diagnostic.began,ended:diagnostic.ended},triggered,engineHoldBegan:diagnostic.engineHoldBegan===true};
    } finally { await cleanup(); if(restoreCamera) await restoreCamera(); }
  }
  if(step.op==='click') {
    // Product scrolling, never a CanvasPosition write. Each segment waits for
    // the exact scroll signal; a clipped target is not clicked through its panel.
    const navigationDeadline=Date.now()+step.timeout_seconds*1000;
    for(let segment=0;segment<64;segment++) {
      if(Date.now()>=navigationDeadline) throw new Error('scroll navigation deadline');
      const navigation=await execute(client.studioId,'Client',`${locate(step.target)}
local center=target.AbsolutePosition+target.AbsoluteSize/2;local scroll=target:FindFirstAncestorWhichIsA('ScrollingFrame')
local value={visible=true}
if scroll then local p,s=scroll.AbsolutePosition,scroll.AbsoluteSize
 if center.X<p.X or center.X>=p.X+s.X or center.Y<p.Y or center.Y>=p.Y+s.Y then
  -- The mouse tool offers only scrollUp and scrollDown, so only a vertically scrolling control can be
  -- navigated. A horizontally scrolling one cannot be reached at all and is reported rather than fed an
  -- action the tool does not accept.
  assert(scroll.ScrollingDirection~=Enum.ScrollingDirection.X,'target needs horizontal scrolling, which the mouse tool cannot perform')
  assert(center.X>=p.X and center.X<p.X+s.X,'target outside the scroll cross axis; scrolling cannot reach it')
  local player=game:GetService('Players').LocalPlayer;assert(not player:FindFirstChild('ForgeQAScroll'),'scroll observer exists')
  local m=Instance.new('BoolValue');m.Name='ForgeQAScroll';m.Parent=player
  local before=scroll.CanvasPosition;local c;c=scroll:GetPropertyChangedSignal('CanvasPosition'):Connect(function() if scroll.CanvasPosition~=before then m.Value=true end end)
  m.Destroying:Once(function() c:Disconnect() end)
  value={visible=false,direction=if center.Y<p.Y then 'scrollUp' else 'scrollDown',path=scroll:GetFullName()}
 end end`);
      if(navigation.visible) break;
      try {
        // The tool's response is kept: an injection that was not accepted and one that was accepted but
        // produced no state change are different failures, and discarding the response conflates them.
        await injectInput(call,{studio_id:client.studioId,datamodel_type:'Client',actions:[{action:navigation.direction,instance_path:'game.'+navigation.path}]},'scroll');
        await execute(client.studioId,'Client',`local m=game:GetService('Players').LocalPlayer.ForgeQAScroll
if not m.Value then observe(m.Changed,function() return true end,function() return not m.Value end) end
assert(m.Value,'scroll did not move');local value={moved=true}`);
      } finally {await execute(client.studioId,'Client',`local m=game:GetService('Players').LocalPlayer:FindFirstChild('ForgeQAScroll');if m then m:Destroy() end;local value={clean=true}`);}
      if(segment===63) throw new Error('scroll navigation limit');
    }
  }
  const predicate=step.op==='wait_for'?step.predicate:step.untilState;
  const predicateServer=predicate?.source==='snapshot';
  const observerId=predicateServer?serverId:client.studioId, observerModel=predicateServer?'Server':'Client';
  const holder=predicateServer?`game:GetService('ServerStorage')`:`game:GetService('Players').LocalPlayer`;
  const cleanup=async()=>execute(observerId,observerModel,`local m=${holder}:FindFirstChild('${marker}');if m then m:Destroy() end;local value={clean=true}`);
  try {
    const prepared=await execute(observerId,observerModel,`local holder=${holder};assert(not holder:FindFirstChild('${marker}'),'input observer already exists')
local m=Instance.new('StringValue');m.Name='${marker}';m.Parent=holder
local connections={};local function finish(value) if m.Parent and m.Value=='' then m.Value=game:GetService('HttpService'):JSONEncode(value) end end
m.Destroying:Once(function() for _,c in connections do c:Disconnect() end end)
${predicate?`${predicateCode(predicate,genre,client.userId)}
local function check() if matches() then finish({matched=true}) end end
table.insert(connections,signal:Connect(check));check()`:
step.resultAction?`local p=game:GetService('Players').LocalPlayer;local relay=p:FindFirstChild('ForgeHUDResult');assert(relay,'HUD result relay missing')
local inputSeen=false;local reply
local function correlated() if inputSeen and reply then finish(reply) end end
${step.op==='click'?`${locate(step.target)};assert(target:IsA('GuiButton'),'button required');table.insert(connections,target.Activated:Connect(function() inputSeen=true;correlated() end))`:`table.insert(connections,game:GetService('UserInputService').InputBegan:Connect(function(input) if input.KeyCode==Enum.KeyCode[${literal(step.key)}] then inputSeen=true;correlated() end end))`}
table.insert(connections,relay.Event:Connect(function(packet) if packet.request and packet.request.action==${literal(step.resultAction)} then reply=packet;correlated() end end))`:
step.op==='click'?`${locate(step.target)};assert(target:IsA('GuiButton') and target.Visible and target.Active and target.Interactable,'button not usable')
-- The instance this subscription is bound to is remembered, because the HUD can replace it: render()
-- runs from the server state push, the async refresh, resize and open, and controls.finish() destroys any
-- control the current pass did not re-register. A click injected later resolves the path again and would
-- then hit the NEW instance, so the subscription has to be moved with it.
local watched=Instance.new('ObjectValue');watched.Name='Watched';watched.Parent=m
watched.Value=target
-- Which events the target actually receives is the whole question for an accepted click with no
-- activation: a touch-mode client may not translate an injected mouse click into Activated at all.
-- Every candidate is recorded by name, and the platform input type is recorded too. These extra
-- subscriptions are DIAGNOSTIC, so they are installed under pcall: a surprise here must not stop the
-- click from being attempted. Activated - the event the step is proven with - stays outside the pcall.
local function seen(name) if m.Parent and m.Value=='' then m:SetAttribute('Seen',(m:GetAttribute('Seen') or '')..name..',') end end
table.insert(connections,target.Activated:Connect(function() seen('Activated');finish({activated=true}) end))
local diagOk,diagErr=pcall(function()
 table.insert(connections,target.MouseButton1Down:Connect(function() seen('MouseButton1Down') end))
 table.insert(connections,target.MouseButton1Up:Connect(function() seen('MouseButton1Up') end))
 table.insert(connections,target.MouseButton1Click:Connect(function() seen('MouseButton1Click') end))
 table.insert(connections,target.InputBegan:Connect(function() seen('TargetInputBegan') end))
 table.insert(connections,target.InputEnded:Connect(function() seen('TargetInputEnded') end))
 table.insert(connections,target.TouchTap:Connect(function() seen('TouchTap') end))
 table.insert(connections,game:GetService('UserInputService').InputBegan:Connect(function(i) seen('UIS:'..tostring(i.UserInputType)) end))
end)
if not diagOk then m:SetAttribute('Seen','subscribe-error:'..tostring(diagErr)) end`:
step.op==='equip'?`${locate(step.target)};assert(target:IsA('Tool'),'equip requires real Tool')
table.insert(connections,target.Equipped:Connect(function() finish({equipped=true}) end))`:
`table.insert(connections,game:GetService('UserInputService').InputBegan:Connect(function(input) if input.KeyCode==Enum.KeyCode[${literal(step.key)}] then finish({key=${literal(step.key)}}) end end))`}
task.delay(${step.timeout_seconds},function() if m.Parent and m.Value=='' then m.Value='TIMEOUT';for _,c in connections do c:Disconnect() end end end)
local value={subscribed=true}`);
    if(!prepared.subscribed) throw new Error('input subscription missing');
    // Retained so a timeout can report what was injected and whether the tool accepted it.
    let clickProbe=null, injection=null;
    if(step.op==='keyboard') await call('user_keyboard_input',{studio_id:client.studioId,datamodel_type:'Client',actions:[{action:'keyPress',key_code:step.key}]});
    else if(step.op==='click') {
      clickProbe=await execute(client.studioId,'Client',`${locate(step.target)};assert(target:IsA('GuiButton') and target.Visible and target.Active and target.Interactable,'button not usable')
local p=target.AbsolutePosition;local s=target.AbsoluteSize;assert(s.X>0 and s.Y>0,'empty button')
local center=p+s/2;local viewport=workspace.CurrentCamera.ViewportSize
assert(center.X>=0 and center.Y>=0 and center.X<viewport.X and center.Y<viewport.Y,'button outside viewport; user must scroll with product input')
local parent=target.Parent;while parent and not parent:IsA('ScreenGui') do
 if parent:IsA('GuiObject') then assert(parent.Visible,'hidden button ancestor');if parent.ClipsDescendants then local a,b=parent.AbsolutePosition,parent.AbsoluteSize;assert(center.X>=a.X and center.Y>=a.Y and center.X<a.X+b.X and center.Y<a.Y+b.Y,'button clipped; user must scroll with product input') end end;parent=parent.Parent end
-- Everything below is DIAGNOSTIC ONLY: it must never change whether the click is attempted or whether
-- the step's assertions hold, so it is wrapped in pcall and a surprise becomes a recorded diagError
-- instead of aborting the click. The click and its assertions stay outside the pcall.
-- Every call is verified against the engine docs: BasePlayerGui:GetGuiObjectsAtPosition(x,y) lives on
-- PlayerGui and its first entry is the TOPMOST object; GuiService:GetGuiInset() returns two Vector2;
-- UserInputService.TouchEnabled/MouseEnabled/KeyboardEnabled; ScreenGui.DisplayOrder/IgnoreGuiInset/
-- ScreenInsets.
local atList,diagError={},false
local insetX,insetY,insetZ,insetW=0,0,0,0
local touchFlag,mouseFlag,keyboardFlag=false,false,false
local guiName,guiOrder,guiIgnore,guiInsets=nil,nil,nil,nil
local u=game:GetService('UserInputService')
local playerGui=game:GetService('Players').LocalPlayer:FindFirstChildOfClass('PlayerGui')
local ok,err=pcall(function()
 local insetA,insetB=game:GetService('GuiService'):GetGuiInset()
 insetX,insetY,insetZ,insetW=insetA.X,insetA.Y,insetB.X,insetB.Y
 for i,o in ipairs(playerGui:GetGuiObjectsAtPosition(center.X,center.Y)) do
  if i>6 then break end
  table.insert(atList,{path=o:GetFullName(),z=o.ZIndex,cls=o.ClassName})
 end
 local screen=target:FindFirstAncestorOfClass('ScreenGui')
 if screen then guiName,guiOrder,guiIgnore,guiInsets=screen.Name,screen.DisplayOrder,screen.IgnoreGuiInset,tostring(screen.ScreenInsets) end
 touchFlag,mouseFlag,keyboardFlag=u.TouchEnabled,u.MouseEnabled,u.KeyboardEnabled
end)
if not ok then diagError=tostring(err) end
-- Bind the event to the instance that was just measured. If the HUD replaced the button since the
-- subscription was installed, the old one is dead and the click would fire on the new one, so the
-- subscription is re-bound here - immediately before injection - and the replacement is reported.
local watched=m and m:FindFirstChild('Watched')
local rebound=watched~=nil and watched.Value~=target
if watched and rebound then
 watched.Value=target
 local c;c=target.Activated:Connect(function() finish({activated=true});c:Disconnect() end)
 m.Destroying:Once(function() c:Disconnect() end)
end
local value={x=p.X+s.X/2,y=p.Y+s.Y/2,path=target:GetFullName(),rebound=rebound,viewport={viewport.X,viewport.Y},inset={insetX,insetY,insetZ,insetW},input={touch=touchFlag,mouse=mouseFlag,keyboard=keyboardFlag},actor=tostring(game:GetService('Players').LocalPlayer.UserId),gui={name=guiName,displayOrder=guiOrder,ignoreInset=guiIgnore,insets=guiInsets},atPosition=atList,diagError=diagError}`);
      // The injection verdict is kept for the same reason as the scroll path: a refused injection and
      // an accepted one with no Activated event are different failures.
      injection=await injectInput(call,{studio_id:client.studioId,datamodel_type:'Client',actions:[{action:'mouseButtonClick',mouse_button:'left',instance_path:'game.'+clickProbe.path}]},'click');
    } else if(step.op==='equip') {
      // Engine equipment action on a server-projected Tool; no equipment ledger writes.
      await execute(client.studioId,'Client',`${locate(step.target)};local p=game:GetService('Players').LocalPlayer
assert(target:IsA('Tool') and target.Parent==p.Backpack,'tool not in owned backpack');p.Character:FindFirstChildOfClass('Humanoid'):EquipTool(target);local value={requested=true}`);
    }
    let value;
    try {
      value=await execute(observerId,observerModel,`local m=${holder}:FindFirstChild('${marker}');assert(m,'observer missing')
if m.Value=='' then local thread=coroutine.running();local c;c=m.Changed:Connect(function() if m.Value~='' then c:Disconnect();task.spawn(thread) end end);if m.Value=='' then coroutine.yield() else c:Disconnect() end end
assert(m.Value~='' and m.Value~='TIMEOUT','exact predicate/input timeout');local value=game:GetService('HttpService'):JSONDecode(m.Value)`);
    } catch(error) {
      // A click timeout is ambiguous on its own: the injection may have been refused, or accepted with
      // no event. The target geometry, the tool's own reply, what sits at that point and which events the
      // target actually received all travel with the failure, so one run can attribute it.
      if(!clickProbe) throw error;
      let seenEvents=null;
      try { seenEvents=await execute(observerId,observerModel,`local m=${holder}:FindFirstChild('${marker}');local value={seen=m and m:GetAttribute('Seen') or false,triggered=m and m:GetAttribute('Triggered'),packets=m and m:GetAttribute('Packets'),relevant=m and m:GetAttribute('Relevant'),input=m and m:GetAttribute('Input')}`); } catch { /* best effort; the click evidence is not */ }
      throw new Error(String(error && error.message || error)+' click='+JSON.stringify({studio_id:client.studioId,x:clickProbe.x,y:clickProbe.y,path:clickProbe.path,rebound:clickProbe.rebound,accepted:injection?.accepted===true,ack:injection?.ack,viewport:clickProbe.viewport,inset:clickProbe.inset,input:clickProbe.input,actor:clickProbe.actor,gui:clickProbe.gui,atPosition:clickProbe.atPosition,seen:seenEvents}));
    }
    if(step.resultAction && (!value.request?.requestId || value.request.action!==step.resultAction || !value.result)) throw new Error('uncorrelated HUD result');
    if(step.expect && value.result?.ok!==(step.expect==='ok')) throw new Error('unexpected HUD command result');
    return value;
  } finally { await cleanup(); }
}
