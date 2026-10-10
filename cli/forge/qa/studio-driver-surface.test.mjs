import {test,expect} from 'bun:test';
import {inputStep} from './studio-driver-input.mjs';
import {deviceStep,motionStep,restoreDeviceCode,collectDeviceDiagnostics} from './studio-driver-surface.mjs';
test('offscreen click scrolls through product input before activation subscription',async()=>{
 const calls=[];let navigation=0;
 const execute=async(_id,_model,code)=>{
  if(code.includes('local value={visible=true}'))return ++navigation===1?{visible:false,direction:'scrollDown',path:'Players.P.PlayerGui.Scroll'}:{visible:true};
  if(code.includes('local value={subscribed=true}'))return {subscribed:true};
  if(code.includes('local value={x='))return {path:'Players.P.PlayerGui.Scroll.Button'};
  if(code.includes('exact predicate/input timeout'))return {activated:true};
  return {moved:true};
 };
 const result=await inputStep({op:'click',target:'Players.LocalPlayer.PlayerGui.Button',timeout_seconds:5},{studioId:'c'},'s','survival-coop',execute,async(name,args)=>calls.push(args.actions));
 expect(result.activated).toBe(true);
 expect(calls[0][0].action).toBe('scrollDown');
 expect(calls[1][0]).toEqual({action:'mouseButtonClick',mouse_button:'left',instance_path:'game.Players.P.PlayerGui.Scroll.Button'});
});
test('device selects phone before orientation and subscribes before setters',async()=>{
 let code;
 await deviceStep({surface:'mobile',width:390,height:844,timeout_seconds:5},{studioId:'c'},async(_id,_model,source)=>{code=source;return {width:390,height:844,orientation:'Portrait'};});
 expect(code.indexOf('PreRender:Connect')).toBeLessThan(code.indexOf('svc:SetDeviceAsync(selected)'));
 expect(code.indexOf('svc:SetDeviceAsync(selected)')).toBeLessThan(code.indexOf('svc:SetOrientationAsync(Enum.ScreenOrientation.Portrait)'));
 expect(code).toContain('svc:SetResolutionAsync(844,390)');
 expect(code).toContain('before=before,desired=desired,actual=actual');
 expect(code).toContain('DEVICE_SETUP_FAILED');
});
test('desktop setup omits orientation and restoration gates it on actual device form',async()=>{
 let code;
 await deviceStep({surface:'desktop',width:1280,height:720,timeout_seconds:5},{studioId:'c'},async(_id,_model,source)=>{code=source;return {width:1280,height:720};});
 expect(code).not.toContain('svc:SetOrientationAsync');
 expect(code).toContain('orientation=nil');
 expect(restoreDeviceCode.indexOf('svc:SetDeviceAsync(saved.id)')).toBeLessThan(restoreDeviceCode.indexOf('svc:SetOrientationAsync'));
 expect(restoreDeviceCode).toContain('form==Enum.DeviceForm.Phone or form==Enum.DeviceForm.Tablet');
});
test('wrong actual viewport cannot pass and exact device diagnostics propagate',async()=>{
 await expect(deviceStep({surface:'mobile',width:390,height:844,timeout_seconds:5},{studioId:'c'},async()=>({device:'phone',width:749,height:367}))).rejects.toThrow('DEVICE_CONFIG_MISMATCH');
 await expect(deviceStep({surface:'mobile',width:390,height:844,timeout_seconds:5},{studioId:'c'},async()=>({width:390,height:844,orientation:'LandscapeRight'}))).rejects.toThrow('DEVICE_ORIENTATION_MISMATCH');
 const failure='DEVICE_SETUP_FAILED '+JSON.stringify({error:'viewport predicate timeout',evidence:{before:{form:'Desktop'},desired:{width:390,height:844},actual:{form:'Phone',orientation:'LandscapeLeft',viewport:{width:749,height:367}}}});
 await expect(deviceStep({surface:'mobile',width:390,height:844,timeout_seconds:5},{studioId:'c'},async()=>{throw new Error(failure);})).rejects.toThrow(failure);
});
test('device and motion forward actual product results rather than approving them',async()=>{
 const measured={device:'discovered-phone',width:390,height:844,orientation:'Portrait',viewport:{width:390.3999938964844,height:763},geometry:{safe:{width:390.3999938964844,height:763}}};
 expect(await deviceStep({surface:'mobile',width:390,height:844,timeout_seconds:5},{studioId:'c'},async()=>measured)).toBe(measured);
 const frames={samples:[{mode:'warn'},{mode:'chase'}],video:false};
 expect(await motionStep({op:'motion_end',target:'Workspace.ForgeWildlife.hunter-01'},{studioId:'c'},async()=>frames)).toBe(frames);
});
test('device diagnostic sections retain timeout metrics separately from truncated errors',async()=>{
 const sections={before:{id:'iphone_13',dpi:153.33},desired:{width:390,height:844},selected:{id:'iphone_6_Plus',resolutionScale:3},actual:{orientation:'LandscapeRight',viewport:{width:749,height:367}},failure:{ok:false,error:'viewport predicate timeout'}};
 const observed=[];
 const result=await collectDeviceDiagnostics({studioId:'actual-client'},async(id,model,code)=>{
  expect(id).toBe('actual-client');expect(model).toBe('Client');
  const section=code.match(/folder:FindFirstChild\('([^']+)'\)/)[1];observed.push(section);
  return {present:section in sections,data:sections[section]};
 });
 expect(observed).toEqual(['before','desired','selected','actual','geometry','screenGuis','failure']);
 expect(result).toEqual(sections);
});
test('absent device diagnostic fields are not fabricated',async()=>{
 expect(await collectDeviceDiagnostics({studioId:'c'},async()=>({present:false}))).toEqual({});
});
