import {test,expect} from 'bun:test';
import {inputStep} from './studio-driver-input.mjs';
import {attachSupplement,runDigest} from './studio-driver-artifacts.mjs';
test('a keyboard hold injects a real keyDown/keyUp pair and requires the client to observe both',async()=>{
  const calls=[];
  const execute=async(_id,_model,code)=>{
    if(code.includes('hold observer already exists')) return {subscribed:true};
    if(code.includes('hold_prompt requires an existing ProximityPrompt')) return {holdDuration:0.4};
    if(code.includes('hold input not observed by the client')) return {began:true,ended:true,triggered:true};
    if(code.includes('ForgeQAHoldTrigger')) return {subscribed:true};
    return {clean:true};
  };
  const call=async(name,args)=>{calls.push([name,args.actions[0].action,args.actions[0].key_code]);return {};};
  const value=await inputStep({op:'keyboard',player:'desktop',key:'E',hold_prompt:'Workspace.Base.Incubator1.Base.Hatch',timeout_seconds:10},{studioId:'owned'},'server','collect-raid',execute,call);
  expect(value.kind).toBe('keyboard-hold');
  // The prompt's own HoldDuration decides the hold, plus the documented margin.
  expect(value.holdSeconds).toBeCloseTo(0.7,5);
  // One key-down is held for the window and closed by exactly one key-up: re-asserting the key-down
  // would restart the engine's hold timer.
  const actions=calls.map(entry=>entry[1]);
  expect(actions).toEqual(['keyDown','keyUp']);
  expect(value.observed).toEqual({began:true,ended:true});
  // The prompt's own trigger is observed, so a hold that produced nothing is attributed to it.
  expect(value.triggered).toBe(true);
});

test('a hold the client never observed as ended fails rather than reporting a hold',async()=>{
  const execute=async(_id,_model,code)=>{
    if(code.includes('hold observer already exists')) return {subscribed:true};
    if(code.includes('hold input not observed by the client')) return {began:true,ended:false};
    if(code.includes('ForgeQAHoldTrigger')) return {subscribed:true};
    return {clean:true};
  };
  await expect(inputStep({op:'keyboard',player:'desktop',key:'E',hold_seconds:0.05,timeout_seconds:10},{studioId:'owned'},'server','collect-raid',execute,async()=>({})))
    .rejects.toThrow('not observed as InputBegan+InputEnded');
});

test('mouse API success cannot replace exact Activated observation and cleanup runs',async()=>{
  const calls=[];
  let subscribed=false,cleaned=false;
  const execute=async(_id,_model,code)=>{
    if(code.includes('local value={visible=true}'))return {visible:true};
    if(code.includes("local value={subscribed=true}")){subscribed=true;return {subscribed:true};}
    if(code.includes('local value={x='))return {x:103,y:545,path:'Players.Player.PlayerGui.Button'};
    if(code.includes('exact predicate/input timeout'))throw new Error('exact predicate/input timeout');
    if(code.includes('clean=true'))cleaned=true;
    return {};
  };
  await expect(inputStep({op:'click',target:'Players.LocalPlayer.PlayerGui.Button',timeout_seconds:5},{studioId:'real-client'},'server','survival-coop',execute,async(name,args)=>{expect(subscribed).toBe(true);calls.push({name,args});return {Success:true};})).rejects.toThrow('exact predicate/input timeout');
  expect(calls[0].name).toBe('user_mouse_input');expect(cleaned).toBe(true);
});
test('HUD command reply is correlated and handed unchanged to bind_result',async()=>{
  const packet={request:{requestId:'real-request',action:'survival-coop:craft-reserve'},result:{ok:true,data:{jobId:'real-job'}}};
  const execute=async(_id,_model,code)=>code.includes('local value={visible=true}')?{visible:true}:code.includes('subscribed=true')?{subscribed:true}:code.includes('exact predicate/input timeout')?packet:code.includes('local value={x=')?{x:100,y:200,path:'Players.Player.PlayerGui.Button'}:{clean:true};
  expect(await inputStep({op:'click',target:'Players.LocalPlayer.PlayerGui.Button',resultAction:'survival-coop:craft-reserve',expect:'ok',timeout_seconds:5},{studioId:'client'},'server','survival-coop',execute,async()=>({}))).toEqual(packet);
  await expect(inputStep({op:'keyboard',key:'F',resultAction:'survival-coop:attack',timeout_seconds:5},{studioId:'client'},'server','survival-coop',execute,async()=>({}))).rejects.toThrow('uncorrelated');
});
// A refused injection and an accepted injection that produced no event are different failures; the
// driver must not conflate them by discarding the tool's reply. The transport raises on a refused
// tools/call, so a refusal reaches the driver as that exception - the real production shape.
test('a refused click injection is reported as refused, not as a timeout',async()=>{
  const calls=[];
  const execute=async(_id,_model,code)=>{
    if(code.includes('local value={subscribed=true}'))return {subscribed:true};
    if(code.includes("FindFirstAncestorWhichIsA('ScrollingFrame')"))return {visible:true};
    if(code.includes('local value={x='))return {x:103,y:545,path:'Players.Player.PlayerGui.Sheet.Content.Recipe-spear'};
    return {clean:true};
  };
  const call=async(name,args)=>{calls.push({name,args});throw new Error('user_mouse_input: {"content":[{"type":"text","text":"instance path not found"}],"isError":true}');};
  await expect(inputStep({op:'click',target:'Players.LocalPlayer.PlayerGui.Sheet.Content.Recipe-spear',timeout_seconds:5},{studioId:'client'},'server','survival-coop',execute,call)).rejects.toThrow('click injection refused: {"content":[{"type":"text","text":"instance path not found"}],"isError":true}');
  expect(calls[0].name).toBe('user_mouse_input');
  expect(calls[0].args.actions[0]).toEqual({action:'mouseButtonClick',mouse_button:'left',instance_path:'game.Players.Player.PlayerGui.Sheet.Content.Recipe-spear'});
});

// A failure that is not a product refusal must not be laundered into a refusal verdict: the injection
// was never confirmed, so the transport error is re-raised unchanged.
test('a transport failure that is not a product refusal is re-raised unchanged',async()=>{
  const execute=async(_id,_model,code)=>{
    if(code.includes('local value={subscribed=true}'))return {subscribed:true};
    if(code.includes("FindFirstAncestorWhichIsA('ScrollingFrame')"))return {visible:true};
    if(code.includes('local value={x='))return {x:103,y:545,path:'Players.Player.PlayerGui.Sheet.Content.Recipe-spear'};
    return {clean:true};
  };
  const call=async()=>{throw new Error('MCP timeout: tools/call');};
  await expect(inputStep({op:'click',target:'Players.LocalPlayer.PlayerGui.Sheet.Content.Recipe-spear',timeout_seconds:5},{studioId:'client'},'server','survival-coop',execute,call)).rejects.toThrow('MCP timeout: tools/call');
});

// A click timeout must carry everything needed to attribute it in one run: the target geometry, the
// tool's verdict, what actually sits at that point, the client's input surface and which events the
// target received. `accepted` comes from the parsed result, and the bounded raw ack is preserved.
test('a click timeout carries the geometry, the tool verdict and which events fired',async()=>{
  const probe={x:103,y:545,path:'Players.Player.PlayerGui.Sheet.Content.Recipe-spear',rebound:false,
    viewport:[390.4,763],inset:[0,0,0,0],input:{touch:true,mouse:true,keyboard:false},actor:'-2',
    gui:{name:'ForgeSurvivalHUD',displayOrder:0,ignoreInset:false,insets:'CoreUISafeInsets'},
    atPosition:[{path:'Players.Player.PlayerGui.ForgeGatherTouch.Gather',z:1,cls:'TextButton'}],diagError:false};
  const execute=async(_id,_model,code)=>{
    if(code.includes('local value={subscribed=true}'))return {subscribed:true};
    if(code.includes("FindFirstAncestorWhichIsA('ScrollingFrame')"))return {visible:true};
    if(code.includes('local value={x='))return probe;
    if(code.includes('exact predicate/input timeout'))throw new Error('AssistantCommand:25: exact predicate/input timeout');
    if(code.includes("m:GetAttribute('Seen')"))return {seen:'UIS:MouseButton1,TargetInputBegan,',triggered:false,packets:0,relevant:0,input:false};
    return {clean:true};
  };
  const accepted=async()=>({content:[{type:'text',text:'{"Success":true}'}]});
  const failure=await inputStep({op:'click',target:'Players.LocalPlayer.PlayerGui.Sheet.Content.Recipe-spear',timeout_seconds:5},{studioId:'client'},'server','survival-coop',execute,accepted).catch(error=>error);
  const payload=JSON.parse(failure.message.slice(failure.message.indexOf('click=')+6));
  expect(payload.accepted).toBe(true);
  expect(payload.ack).toBe('{"content":[{"type":"text","text":"{\\"Success\\":true}"}]}');
  expect(payload.rebound).toBe(false);
  expect(payload.viewport).toEqual([390.4,763]);
  expect(payload.input).toEqual({touch:true,mouse:true,keyboard:false});
  expect(payload.actor).toBe('-2');
  expect(payload.atPosition[0].path).toBe('Players.Player.PlayerGui.ForgeGatherTouch.Gather');
  expect(payload.seen.seen).toBe('UIS:MouseButton1,TargetInputBegan,');
  const refused=async()=>{throw new Error('user_mouse_input: {"content":[{"type":"text","text":"refused"}],"isError":true}');};
  await expect(inputStep({op:'click',target:'Players.LocalPlayer.PlayerGui.Sheet.Content.Recipe-spear',timeout_seconds:5},{studioId:'client'},'server','survival-coop',execute,refused)).rejects.toThrow('click injection refused');
});

// The scroll preflight must refuse what scrolling cannot fix: the mouse tool offers only scrollUp and
// scrollDown, so a target outside the cross axis, or one needing horizontal scrolling, is an error
// rather than an unbounded scroll loop.
test('scroll navigation guards the cross axis and refuses horizontal scrolling',async()=>{
  const emitted=[];
  const execute=async(_id,_model,code)=>{
    emitted.push(code);
    if(code.includes('local value={subscribed=true}'))return {subscribed:true};
    if(code.includes("FindFirstAncestorWhichIsA('ScrollingFrame')"))return {visible:true};
    if(code.includes('local value={x='))return {x:10,y:20,path:'Players.Player.PlayerGui.Sheet.Content.Recipe-spear'};
    return {clean:true};
  };
  await inputStep({op:'click',target:'Players.LocalPlayer.PlayerGui.Sheet.Content.Recipe-spear',timeout_seconds:5},{studioId:'client'},'server','survival-coop',execute,async()=>({Success:true}));
  const navigation=emitted.find(code=>code.includes("FindFirstAncestorWhichIsA('ScrollingFrame')"));
  expect(navigation).toContain("'target outside the scroll cross axis; scrolling cannot reach it'");
  expect(navigation).toContain("'target needs horizontal scrolling, which the mouse tool cannot perform'");
  expect(navigation).toContain('ScrollingDirection~=Enum.ScrollingDirection.X');
  // Only the two actions the tool actually accepts can be emitted.
  expect(navigation).toContain("'scrollUp' else 'scrollDown'");
  expect(navigation).not.toContain('scrollLeft');
  expect(navigation).not.toContain('scrollRight');
});

test('a refused scroll injection is reported as refused',async()=>{
  const execute=async(_id,_model,code)=>{
    if(code.includes('local value={subscribed=true}'))return {subscribed:true};
    if(code.includes("FindFirstAncestorWhichIsA('ScrollingFrame')"))return {visible:false,direction:'scrollDown',path:'Players.Player.PlayerGui.Sheet.Content'};
    if(code.includes('local value={x='))return {x:10,y:2000,path:'Players.Player.PlayerGui.Sheet.Content.Recipe-spear'};
    return {clean:true};
  };
  const call=async()=>{throw new Error('user_mouse_input: {"content":[{"type":"text","text":"refused"}],"isError":true}');};
  await expect(inputStep({op:'click',target:'Players.LocalPlayer.PlayerGui.Sheet.Content.Recipe-spear',timeout_seconds:5},{studioId:'client'},'server','survival-coop',execute,call)).rejects.toThrow('scroll injection refused');
});

// The HUD can replace the clicked button between the subscription and the injection: render() destroys the
// inventory grid and every control it re-registers, and a server state push re-renders at any time. The
// click must still be proven, so the subscription is re-bound to the instance actually measured.
test('a button replaced between subscription and injection is re-bound and still activates',async()=>{
  const execute=async(_id,_model,code)=>{
    if(code.includes('local value={subscribed=true}'))return {subscribed:true};
    if(code.includes("FindFirstAncestorWhichIsA('ScrollingFrame')"))return {visible:true};
    if(code.includes('local value={x='))return {x:103,y:687,path:'Players.Player1.PlayerGui.ForgeSurvivalHUD.SafeArea.SurvivalSheet.Content.InventoryGrid.item',rebound:true};
    if(code.includes('exact predicate/input timeout'))return {activated:true};
    return {clean:true};
  };
  const value=await inputStep({op:'click',target:'Players.LocalPlayer.PlayerGui.ForgeSurvivalHUD.SafeArea.SurvivalSheet.Content.InventoryGrid.item',timeout_seconds:5},{studioId:'client'},'server','survival-coop',execute,async()=>({Success:true}));
  expect(value).toEqual({activated:true});
});

// The replacement is real evidence, so it travels with the failure instead of being invisible.
test('a replaced button that never activates reports the replacement in the click diagnostic',async()=>{
  const execute=async(_id,_model,code)=>{
    if(code.includes('local value={subscribed=true}'))return {subscribed:true};
    if(code.includes("FindFirstAncestorWhichIsA('ScrollingFrame')"))return {visible:true};
    if(code.includes('local value={x='))return {x:103,y:687,path:'Players.Player1.PlayerGui.ForgeSurvivalHUD.SafeArea.SurvivalSheet.Content.InventoryGrid.item',rebound:true,viewport:[390.4,763],inset:[0,0,0,0],input:{touch:true,mouse:true,keyboard:false},actor:'-2',gui:{name:'ForgeSurvivalHUD',displayOrder:0,ignoreInset:false,insets:'CoreUISafeInsets'},atPosition:[{path:'Players.Player1.PlayerGui.ForgeGatherTouch.Gather',z:1,cls:'TextButton'}],diagError:false};
    if(code.includes("m:GetAttribute('Seen')"))return {seen:'UIS:MouseButton1,TargetInputBegan,',triggered:false,packets:0,relevant:0,input:false};
    if(code.includes('exact predicate/input timeout'))throw new Error('exact predicate/input timeout');
    return {clean:true};
  };
  const failure=await inputStep({op:'click',target:'Players.LocalPlayer.PlayerGui.ForgeSurvivalHUD.SafeArea.SurvivalSheet.Content.InventoryGrid.item',timeout_seconds:5},{studioId:'client'},'server','survival-coop',execute,async()=>({Success:true})).catch(error=>error);
  const payload=JSON.parse(String(failure.message).slice(String(failure.message).indexOf('click=')+6));
  expect(payload.rebound).toBe(true);
  expect(payload.accepted).toBe(true);
  expect(payload.path).toBe('Players.Player1.PlayerGui.ForgeSurvivalHUD.SafeArea.SurvivalSheet.Content.InventoryGrid.item');
  // The event set the target received travels with the failure, so an accepted click with no activation
  // is attributable in one run rather than by guessing.
  expect(payload.seen.seen).toBe('UIS:MouseButton1,TargetInputBegan,');
  expect(payload.atPosition).toEqual([{path:'Players.Player1.PlayerGui.ForgeGatherTouch.Gather',z:1,cls:'TextButton'}]);
  expect(payload.input).toEqual({touch:true,mouse:true,keyboard:false});
  expect(payload.actor).toBe('-2');
});

// The diagnostic probe must never be able to break the click: a bad API call in it has to surface as a
// diagError string while the click and its assertions still run to completion.
test('a diagnostic probe failure is recorded and never aborts the click',async()=>{
  const calls=[];
  const execute=async(_id,_model,code)=>{
    calls.push(code);
    if(code.includes('local value={subscribed=true}'))return {subscribed:true};
    if(code.includes("FindFirstAncestorWhichIsA('ScrollingFrame')"))return {visible:true};
    if(code.includes('local value={x='))return {x:103,y:545,path:'Players.Player.PlayerGui.Sheet.Content.Recipe-spear',rebound:false,viewport:[390.4,763],inset:[0,0,0,0],input:{touch:true,mouse:false,keyboard:false},actor:'-2',gui:{},atPosition:[],diagError:'GetGuiObjectsAtPosition is not a valid member of UserInputService'};
    if(code.includes('exact predicate/input timeout'))return {activated:true};
    return {clean:true};
  };
  // The click still completes normally even though the probe reported an error.
  const value=await inputStep({op:'click',target:'Players.LocalPlayer.PlayerGui.Sheet.Content.Recipe-spear',timeout_seconds:5},{studioId:'client'},'server','survival-coop',execute,async()=>({Success:true}));
  expect(value).toEqual({activated:true});
  // The probe is wrapped in pcall and the click assertions stay outside it.
  const probe=calls.find(code=>code.includes('GetGuiObjectsAtPosition'));
  expect(probe).toContain('pcall(function()');
  expect(probe).toContain('diagError');
  expect(probe).toContain("playerGui:GetGuiObjectsAtPosition");
  expect(probe).not.toContain("u:GetGuiObjectsAtPosition");
});

test('external observations bind measured run actor and action time without inventing goals',async()=>{
  const run={scenario:'actual',clients:[{studio_id:'process',actor:'7'}],steps:[{index:1,op:'click',startedSeconds:2,elapsedSeconds:3}],inputs:[],calls:[],captures:[{studio_id:'process',actor:'7'}]};
  const supplement={runSha256:runDigest(run),firstPlay:{goals:{g:{actors:['7'],step:1,elapsedSeconds:2.5,unprompted:false,shortcut:false,observation:'supplied',goalDigest:'supplied'}}}};
  const result=await attachSupplement(run,supplement,async()=>new Uint8Array());
  expect(result.firstPlay.goals.g.unprompted).toBe(false);
  await expect(attachSupplement({...run,steps:[]},supplement,async()=>new Uint8Array())).rejects.toThrow('digest');
  supplement.firstPlay.goals.g.actors=['7','7'];
  await expect(attachSupplement(run,supplement,async()=>new Uint8Array())).rejects.toThrow('actor');
});
