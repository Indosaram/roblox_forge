import {test,expect} from 'bun:test';
import {wildlifeTrace,conservation,wildlifeTraceCode,retainWildlifeTrace,WILDLIFE_TRACE_LIMIT,wildlifeDiagnosis,WILDLIFE_UNMET_MARKER,WILDLIFE_ESSENTIAL_FIELDS,WILDLIFE_DIAGNOSIS_BUDGET,wildlifeDiagnosisLength} from './studio-driver-wildlife.mjs';
test('wildlife subscription is installed before caller can move and a failed predicate retains the folder',async()=>{
 const calls=[];
 const execute=async(_id,model,code)=>{
  calls.push({model,code});
  if(code.includes('local value={subscribed=true'))return {subscribed:true};
  if(code.includes('ordered wildlife state/distance predicate timeout'))throw new Error('predicate timeout');
  return {clean:true};
 };
 expect(await wildlifeTrace({op:'motion_begin',target:'Workspace.ForgeWildlife.grazer-01',home:[-20,4,24]},'server',execute)).toEqual({subscribed:true});
 await expect(wildlifeTrace({op:'motion_end',observations:[{mode:'flee',displacement:1},{mode:'roam',outside:24}],timeout_seconds:5},'server',execute)).rejects.toThrow('predicate timeout');
 expect(calls.every(c=>c.model==='Server')).toBe(true);
 // The window is retained for the caller's bounded readback, which is what destroys it.
 expect(calls.some(c=>c.code.includes('folder:Destroy()'))).toBe(false);
});
test('malformed attack conservation compares actual inventory fields and health independent of key order',()=>{
 const before={inventory:{bag:{items:{spear:{quantity:1,durabilityMilli:100}}}},healthMilli:60000};
 expect(()=>conservation(before,{healthMilli:60000,inventory:before.inventory})).not.toThrow();
 expect(()=>conservation(before,{...before,healthMilli:0})).toThrow('refused attack changed');
 expect(()=>conservation(before,{...before,inventory:{bag:{items:{}}}})).toThrow('refused attack changed');
});

// The trace is the only record of where every NPC and actor actually was when a step could not
// proceed, so it must be read before the folder is destroyed and read within a bound.
test('the trace retention read is bounded, ordered and still destroys the folder',()=>{
 const code=wildlifeTraceCode(240);
 expect(code).toContain("FindFirstChild('ForgeQAWildlifeTrace')");
 expect(code).toContain('#samples-239');
 expect(code).toContain('table.sort(samples,function(a,b) return (a.elapsedSeconds or 0)<(b.elapsedSeconds or 0) end)');
 expect(code).toContain("value.overflow=f:GetAttribute('Overflow')==true");
 expect(code).toContain('value.total=#samples');
 expect(code).toContain('f:Destroy()');
 expect(code).toContain('value={present=f~=nil}');
 expect(()=>wildlifeTraceCode(0)).toThrow('INVALID_WILDLIFE_TRACE_LIMIT');
 expect(()=>wildlifeTraceCode(2401)).toThrow('INVALID_WILDLIFE_TRACE_LIMIT');
 expect(()=>wildlifeTraceCode(1.5)).toThrow('INVALID_WILDLIFE_TRACE_LIMIT');
});

test('retained trace evidence keeps the newest samples and refuses a malformed read',()=>{
 const samples=Array.from({length:500},(_,i)=>({elapsedSeconds:i,mode:'chase',position:[i,3,18]}));
 const kept=retainWildlifeTrace({present:true,overflow:false,total:500,samples});
 expect(kept.present).toBe(true);
 expect(kept.total).toBe(500);
 expect(kept.samples).toHaveLength(WILDLIFE_TRACE_LIMIT);
 expect(kept.samples.at(-1).elapsedSeconds).toBe(499);
 expect(kept.samples[0].elapsedSeconds).toBe(500-WILDLIFE_TRACE_LIMIT);
 expect(retainWildlifeTrace({present:false})).toEqual({present:false});
 expect(()=>retainWildlifeTrace(null)).toThrow('WILDLIFE_TRACE_RESULT_REQUIRED');
 expect(()=>retainWildlifeTrace({present:true})).toThrow('WILDLIFE_TRACE_SAMPLES_REQUIRED');
 expect(()=>retainWildlifeTrace({present:true,samples:[]},5000)).toThrow('INVALID_WILDLIFE_TRACE_LIMIT');
});

// A motion_end keeps only the machine essentials in the failure text and leaves the sample window in
// the folder for the caller's bounded readback, because the engine caps an MCP result message far
// below a full window and inlining it truncated the JSON mid-array.
const unmetEssentials={rules:4,unmetIndex:4,unmet:{mode:'idle',homeAtMost:1,outside:12},matched:3,total:9,overflow:false,
 unmetModeObserved:true,closest:{elapsedSeconds:12.5,displacement:3.2,homeDistance:1.2647,minActorDistance:40.6,minActorHomeDistance:41.39}};
const failingExecute=calls=>({
 execute:async(_id,model,code)=>{
  calls.push({model,code});
  if(code.includes('local value={subscribed=true'))return {subscribed:true};
  if(code.includes('ordered wildlife state/distance predicate timeout'))throw new Error(`sabuiltin_CommandExecution:25: ordered wildlife state/distance predicate timeout ${WILDLIFE_UNMET_MARKER} ${JSON.stringify(unmetEssentials)}`);
  return {clean:true};
 },
});

test('an unmet ordered rule reports the exact unmet rule and retains the window for readback',async()=>{
 const calls=[];
 const {execute}=failingExecute(calls);
 await wildlifeTrace({op:'motion_begin',target:'Workspace.ForgeWildlife.hunter-01',home:[22,4,24]},'server',execute);
 let failure;
 try{await wildlifeTrace({op:'motion_end',observations:[{mode:'warn'},{mode:'chase',displacement:1},{mode:'return',actorsHomeOutside:40},{mode:'idle',homeAtMost:1,outside:12}],timeout_seconds:5},'server',execute);}
 catch(error){failure=error;}
 expect(failure).toBeDefined();
 expect(failure.message).toContain('ordered wildlife state/distance predicate timeout');
 // The essentials name the rule that was never met and what the samples showed.
 const d=failure.wildlifeTrace;
 expect(d.rules).toBe(4);
 expect(d.unmetIndex).toBe(4);
 expect(d.unmet).toEqual({mode:'idle',homeAtMost:1,outside:12});
 expect(d.matched).toBe(3);
 expect(d.total).toBe(9);
 expect(d.overflow).toBe(false);
 expect(d.unmetModeObserved).toBe(true);
 expect(d.closest.homeDistance).toBe(1.2647);
 expect(d.closest.minActorHomeDistance).toBe(41.39);
 // The window is NOT in the failure text - that is the truncation this replaces.
 expect(failure.message).not.toContain('"samples"');
 // The folder is retained for the caller's bounded readback, which is what destroys it.
 expect(calls.some(c=>c.code.includes('folder:Destroy()'))).toBe(false);
 expect(calls.every(c=>c.model==='Server')).toBe(true);
});

test('a satisfied predicate destroys the folder and returns the bounded window',async()=>{
 const calls=[];
 const execute=async(_id,model,code)=>{
  calls.push({model,code});
  if(code.includes('local value={subscribed=true'))return {subscribed:true};
  if(code.includes('local value={samples=kept,matched=matched}'))return {samples:[],matched:[]};
  return {clean:true};
 };
 await wildlifeTrace({op:'motion_begin',target:'Workspace.ForgeWildlife.hunter-01',home:[22,4,24]},'server',execute);
 expect(await wildlifeTrace({op:'motion_end',observations:[{mode:'warn'}],timeout_seconds:5},'server',execute)).toEqual({samples:[],matched:[]});
 expect(calls.at(-1).code).toContain('folder:Destroy()');
});

test('the emitted motion_end keeps only the machine essentials in the failure text',async()=>{
 const calls=[];
 const {execute}=failingExecute(calls);
 await wildlifeTrace({op:'motion_begin',target:'Workspace.ForgeWildlife.hunter-01',home:[22,4,24]},'server',execute);
 await expect(wildlifeTrace({op:'motion_end',observations:[{mode:'warn'}],timeout_seconds:5},'server',execute)).rejects.toThrow('predicate timeout');
 const end=calls.find(c=>c.code.includes('unmetIndex=index'));
 expect(end).toBeDefined();
 expect(end.code).toContain('local unmet=rules[index]');
 expect(end.code).toContain('local essentials=http:JSONEncode({rules=#rules,unmetIndex=index');
 expect(end.code).toContain('unmetModeObserved=observed');
 expect(end.code).toContain('closest=closest})');
 expect(end.code).not.toContain('samples=kept})');
 expect(end.code).toContain("'ordered wildlife state/distance predicate timeout " + WILDLIFE_UNMET_MARKER + " '..essentials");
 expect(end.code).toContain("'wildlife trace overflow " + WILDLIFE_UNMET_MARKER + " '..essentials");
 expect(end.code).toContain('#samples-239');
 // The bounded window is still built and is still what the step value returns on success.
 expect(end.code).toContain('local value={samples=kept,matched=matched}');
 expect(end.code).not.toContain('local value={samples=samples');
});

test('the emitted motion_begin measures home from the instance, not the authored coordinate',async()=>{
 const calls=[];
 const execute=async(_id,model,code)=>{calls.push({model,code});if(code.includes('local value={subscribed=true'))return {subscribed:true};return {clean:true};};
 await wildlifeTrace({op:'motion_begin',target:'Workspace.ForgeWildlife.hunter-01',home:[22,4,24]},'server',execute);
 const begin=calls.find(c=>c.code.includes('local value={subscribed=true'));
 // The module's own idle/leash rules measure against its recorded home; a re-authored coordinate
 // one stud off makes a one-stud bound unsatisfiable in 3D.
 expect(begin.code).toContain("local home=target:GetAttribute('ForgeWildlifeHome') or Vector3.new(22,4,24)");
});

// The boundedness is the point: the previous message inlined up to 240 samples and the engine cut
// it at 867 characters mid-array, so the machine summary must stay a closed, bounded field set.
test('the machine summary is a closed field set that fits the diagnosis budget',async()=>{
 const calls=[];
 const {execute}=failingExecute(calls);
 await wildlifeTrace({op:'motion_begin',target:'Workspace.ForgeWildlife.hunter-01',home:[22,4,24]},'server',execute);
 await expect(wildlifeTrace({op:'motion_end',observations:[{mode:'warn'}],timeout_seconds:5},'server',execute)).rejects.toThrow('predicate timeout');
 const end=calls.find(c=>c.code.includes('unmetIndex=index'));
 // The emitted JSONEncode key list is exactly the closed set - no sample window can creep back in.
 const encoded=end.code.match(/local essentials=http:JSONEncode\(\{(.*?)\}\)/)[1];
 const emitted=encoded.split(',').map(pair=>pair.split('=')[0].trim()).filter(Boolean);
 expect(emitted).toEqual(WILDLIFE_ESSENTIAL_FIELDS);
 expect(emitted).not.toContain('samples');
 // Worst case: the longest enum mode, the trace cap as an integer, and full-precision numbers.
 const worst={rules:WILDLIFE_TRACE_LIMIT,unmetIndex:WILDLIFE_TRACE_LIMIT,unmet:{mode:'telegraph',actorsHomeOutside:2400,displacement:2400,homeAtMost:2400,outside:2400},matched:WILDLIFE_TRACE_LIMIT,total:WILDLIFE_TRACE_LIMIT,overflow:true,unmetModeObserved:true,closest:{elapsedSeconds:1234.5678901234567,displacement:0.1234567890123456,homeDistance:1.2646849155426026,minActorDistance:40.605201721191409,minActorHomeDistance:41.38820266723633}};
 expect(Object.keys(worst)).toEqual(WILDLIFE_ESSENTIAL_FIELDS);
 expect(wildlifeDiagnosisLength(worst)).toBeLessThan(WILDLIFE_DIAGNOSIS_BUDGET);
 // And the worst case still parses as a complete diagnosis.
 const parsed=wildlifeDiagnosis(`${WILDLIFE_UNMET_MARKER} ${JSON.stringify(worst)}`);
 expect(parsed).not.toBe(null);
 expect(parsed.unmetIndex).toBe(WILDLIFE_TRACE_LIMIT);
 expect(parsed.closest.minActorHomeDistance).toBe(41.38820266723633);
});

test('the ordered-trace diagnosis requires the essentials in full and refuses a truncated message',()=>{
 expect(wildlifeDiagnosis('nothing here')).toBe(null);
 expect(wildlifeDiagnosis(`${WILDLIFE_UNMET_MARKER} `)).toBe(null);
 expect(wildlifeDiagnosis(`${WILDLIFE_UNMET_MARKER} {"rules":4`)).toBe(null);
 // The observed failure mode: the message was cut mid-array, so the prefix is not a diagnosis.
 expect(wildlifeDiagnosis(`${WILDLIFE_UNMET_MARKER} {"unmet":{"mode":"idle","homeAtMost":1,"outside":12},"rules":4,"unmetModeObserved":true,"samples":[{"homeDistance":1.26`)).toBe(null);
 // A complete object missing essentials is still not a diagnosis.
 expect(wildlifeDiagnosis(`${WILDLIFE_UNMET_MARKER} {"unmet":null,"rules":4,"unmetIndex":4,"matched":3,"total":9,"overflow":false}`)).toBe(null);
 // A malformed rule or closest sample is refused rather than trusted.
 expect(wildlifeDiagnosis(`${WILDLIFE_UNMET_MARKER} {"rules":4,"unmetIndex":4,"unmet":{"mode":7},"matched":3,"total":9,"overflow":false,"unmetModeObserved":true}`)).toBe(null);
 expect(wildlifeDiagnosis(`${WILDLIFE_UNMET_MARKER} {"rules":4,"unmetIndex":4,"unmet":null,"matched":3,"total":9,"overflow":false,"unmetModeObserved":true,"closest":{"homeDistance":"nope"}}`)).toBe(null);
 expect(wildlifeDiagnosis(undefined)).toBe(null);
 const ok=wildlifeDiagnosis(`${WILDLIFE_UNMET_MARKER} {"rules":4,"unmetIndex":4,"unmet":{"mode":"idle","homeAtMost":1,"outside":12},"matched":3,"total":9,"overflow":false,"unmetModeObserved":true,"closest":{"homeDistance":1.2647,"minActorHomeDistance":41.39}}`);
 expect(ok.unmetIndex).toBe(4);
 expect(ok.unmet).toEqual({mode:'idle',homeAtMost:1,outside:12});
 expect(ok.unmetModeObserved).toBe(true);
 expect(ok.closest.homeDistance).toBe(1.2647);
 expect(ok.total).toBe(9);
 expect(ok.matched).toBe(3);
});
