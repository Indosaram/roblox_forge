// Read-only engine observations; owned marker is the only instance this creates.
export async function wildlifeTrace(step,serverId,execute) {
  const marker='ForgeQAWildlifeTrace';
  if(step.op==='motion_begin' && (!Array.isArray(step.home)||step.home.length!==3||step.home.some(n=>!Number.isFinite(n))))throw new Error('finite authored home coordinates required');
  if(step.op==='motion_begin') return execute(serverId,'Server',`local storage=game:GetService('ServerStorage');assert(not storage:FindFirstChild('${marker}'),'wildlife trace already active')
local target=game;for segment in string.gmatch(${JSON.stringify(step.target)},'[^.]+') do target=target:FindFirstChild(segment);assert(target,'wildlife missing') end
local root=target:FindFirstChild('HumanoidRootPart');assert(root,'wildlife root missing')
local home=target:GetAttribute('ForgeWildlifeHome') or Vector3.new(${step.home.join(',')});local start=root.Position;local started=os.clock()
local folder=Instance.new('Folder');folder.Name='${marker}';folder.Parent=storage
local count=0;local lastMode;local nextFrame=0
local function sample()
 local elapsed=os.clock()-started;local mode=target:GetAttribute('ForgeWildlifeState')
 if count>=2400 then folder:SetAttribute('Overflow',true);return end
 if mode==lastMode and elapsed<nextFrame then return end;lastMode=mode;nextFrame=elapsed+0.1;count+=1
 local actors={};for _,p in game:GetService('Players'):GetPlayers() do local r=p.Character and p.Character:FindFirstChild('HumanoidRootPart');if r then table.insert(actors,{actor=tostring(p.UserId),distance=(r.Position-root.Position).Magnitude,homeDistance=(r.Position-home).Magnitude}) end end
 local value=Instance.new('StringValue');value.Name=tostring(count);value.Value=game:GetService('HttpService'):JSONEncode({elapsedSeconds=elapsed,mode=mode,position={root.Position.X,root.Position.Y,root.Position.Z},displacement=(root.Position-start).Magnitude,homeDistance=(root.Position-home).Magnitude,healthMilli=target:GetAttribute('ForgeWildlifeHealthMilli'),actors=actors});value.Parent=folder
end
local a=target:GetAttributeChangedSignal('ForgeWildlifeState'):Connect(sample)
local b=game:GetService('RunService').Heartbeat:Connect(sample)
folder.Destroying:Once(function() a:Disconnect();b:Disconnect() end);sample()
local value={subscribed=true,initialState=lastMode,home={home.X,home.Y,home.Z}}`);
  const rules=step.observations;
  if(!Array.isArray(rules)||!rules.length)throw new Error('ordered wildlife observations required');
  for(const rule of rules) {
    if(!['flee','roam','warn','chase','return','idle','telegraph','dead'].includes(rule.mode))throw new Error('unknown observed wildlife mode');
    for(const key of ['displacement','homeAtMost','outside','actorsHomeOutside'])if(key in rule && (!Number.isFinite(rule[key])||rule[key]<0))throw new Error('invalid wildlife distance predicate');
  }
  let retainForReadback=false;
  try {
    return await execute(serverId,'Server',`local folder=game:GetService('ServerStorage'):FindFirstChild('${marker}');assert(folder,'wildlife subscription absent')
local rules=game:GetService('HttpService'):JSONDecode(${JSON.stringify(JSON.stringify(rules))});local index=1;local samples={};local matched={}
local function accept(child)
 local sample=game:GetService('HttpService'):JSONDecode(child.Value);table.insert(samples,sample)
 local rule=rules[index];if not rule or sample.mode~=rule.mode then return end
 if rule.displacement and sample.displacement<rule.displacement then return end
 if rule.homeAtMost and sample.homeDistance>rule.homeAtMost then return end
 if rule.outside then if #sample.actors~=2 then return end;for _,actor in sample.actors do if actor.distance<=rule.outside then return end end end
 if rule.actorsHomeOutside then if #sample.actors~=2 then return end;for _,actor in sample.actors do if actor.homeDistance<=rule.actorsHomeOutside then return end end end
 table.insert(matched,sample);index+=1
end
local existing=folder:GetChildren();table.sort(existing,function(a,b)return tonumber(a.Name)<tonumber(b.Name) end);for _,child in existing do accept(child) end
local thread;local done=false
local connection=folder.ChildAdded:Connect(function(child) accept(child);if index>#rules and thread and not done then done=true;task.spawn(thread) end end)
if index<=#rules then thread=coroutine.running();task.delay(${step.timeout_seconds || 20},function() if not done then done=true;task.spawn(thread) end end);coroutine.yield() end
connection:Disconnect()
-- The failure record must be built here, before the caller's finally would destroy the folder: the
-- ordered samples are the only account of what every NPC and actor actually did, and without them
-- an unmet rule cannot be told apart from a mis-staged scenario.
local overflow=folder:GetAttribute('Overflow')==true
local http=game:GetService('HttpService')
local kept={};for i=math.max(1,#samples-${WILDLIFE_TRACE_LIMIT - 1}),#samples do table.insert(kept,samples[i]) end
local unmet=rules[index]
local observed=false;local closest=nil
if unmet then
 for _,sample in samples do
  if sample.mode==unmet.mode then
   observed=true
   local distances={};local homes={}
   for _,actor in sample.actors do table.insert(distances,actor.distance);table.insert(homes,actor.homeDistance) end
   local candidate={elapsedSeconds=sample.elapsedSeconds,displacement=sample.displacement,homeDistance=sample.homeDistance,
    minActorDistance=#distances>0 and math.min(table.unpack(distances)) or nil,
    minActorHomeDistance=#homes>0 and math.min(table.unpack(homes)) or nil}
   if closest==nil
    or (unmet.displacement and (candidate.displacement or 0)>(closest.displacement or 0))
    or (unmet.homeAtMost and (candidate.homeDistance or math.huge)<(closest.homeDistance or math.huge))
    or (unmet.outside and (candidate.minActorDistance or 0)>(closest.minActorDistance or 0))
    or (unmet.actorsHomeOutside and (candidate.minActorHomeDistance or 0)>(closest.minActorHomeDistance or 0)) then
    closest=candidate
   end
  end
 end
end
-- Only the machine essentials travel in the failure text. The engine caps an MCP result message well
-- below the size of a full sample window, so inlining the samples truncates the JSON mid-array and
-- destroys the very diagnosis it was meant to carry. The window stays in the folder and is read back
-- by the caller's bounded retention, which is also what destroys it.
local essentials=http:JSONEncode({rules=#rules,unmetIndex=index,unmet=unmet,matched=#matched,total=#samples,overflow=overflow,unmetModeObserved=observed,closest=closest})
assert(not overflow,'wildlife trace overflow ${WILDLIFE_UNMET_MARKER} '..essentials)
assert(index>#rules,'ordered wildlife state/distance predicate timeout ${WILDLIFE_UNMET_MARKER} '..essentials)
local value={samples=kept,matched=matched}`);
  } catch (error) {
    // The failure text carries only the machine essentials; the sample window stays in the folder so
    // the caller's bounded retention can read it. The folder is therefore retained for that readback
    // (which destroys it) instead of being destroyed here.
    const diagnosis = wildlifeDiagnosis(error && error.message);
    if (diagnosis) error.wildlifeTrace = diagnosis;
    retainForReadback = true;
    throw error;
  } finally {
    // A satisfied predicate leaves its bounded window in the step value, so the folder is destroyed
    // here; a failed one retains the folder for the driver's bounded readback.
    if (!retainForReadback) {
      await execute(serverId,'Server',`local folder=game:GetService('ServerStorage'):FindFirstChild('${marker}');if folder then folder:Destroy() end;local value={clean=true}`);
    }
  }
}

export function conservation(before,after) {
  const stable=value=>value && typeof value==='object'?Array.isArray(value)?value.map(stable):Object.fromEntries(Object.keys(value).sort().map(k=>[k,stable(value[k])])):value;
  if(JSON.stringify(stable(before))!==JSON.stringify(stable(after)))throw new Error('refused attack changed inventory or wildlife health');
}

// Bounded retention of the wildlife trace. A step that fails on the way out of a chase otherwise
// leaves no record of where any NPC or actor actually was: the trace holds one sample per state
// change and heartbeat (bounded at 2400 by the trace itself) with every NPC's position, mode and
// health plus each actor's distance, and it is the only evidence that can separate a static
// obstruction from the pursuer. The read keeps the most recent samples and is capped so the
// post-deadline cleanup budget is not spent on a long trace.
export const WILDLIFE_TRACE_LIMIT = 240;

function traceLimit(limit) {
  if (!Number.isInteger(limit) || limit < 1 || limit > 2400) throw new Error('INVALID_WILDLIFE_TRACE_LIMIT');
  return limit;
}

export function wildlifeTraceCode(limit = WILDLIFE_TRACE_LIMIT) {
  traceLimit(limit);
  return `local f=game:GetService('ServerStorage'):FindFirstChild('ForgeQAWildlifeTrace')
local value={present=f~=nil}
if f then
 local http=game:GetService('HttpService')
 local samples={}
 for _,c in f:GetChildren() do table.insert(samples,http:JSONDecode(c.Value)) end
 table.sort(samples,function(a,b) return (a.elapsedSeconds or 0)<(b.elapsedSeconds or 0) end)
 local kept={}
 for i=math.max(1,#samples-${limit - 1}),#samples do table.insert(kept,samples[i]) end
 value.overflow=f:GetAttribute('Overflow')==true
 value.total=#samples
 value.samples=kept
 f:Destroy()
end`;
}

export function retainWildlifeTrace(payload, limit = WILDLIFE_TRACE_LIMIT) {
  traceLimit(limit);
  if (!payload || typeof payload !== 'object') throw new Error('WILDLIFE_TRACE_RESULT_REQUIRED');
  if (payload.present !== true) return { present: false };
  if (!Array.isArray(payload.samples)) throw new Error('WILDLIFE_TRACE_SAMPLES_REQUIRED');
  return {
    present: true,
    overflow: payload.overflow === true,
    total: Number.isInteger(payload.total) ? payload.total : payload.samples.length,
    samples: payload.samples.slice(-limit),
  };
}

// A motion_end that times out leaves its sample window in the folder for the caller's bounded
// retention, and puts only the machine essentials in the failure text. The engine caps an MCP result
// message far below a full sample window, so a message that inlined the samples was truncated
// mid-array; parsing such a prefix as if it were complete is exactly the failure this avoids. The
// essentials are therefore required in full, and a truncated or partial object yields null rather
// than a diagnosis assembled from whatever survived.
export const WILDLIFE_UNMET_MARKER = 'WILDLIFE_ORDERED_PREDICATE_UNMET';

// The machine summary that travels in the failure text is a closed field set with bounded values:
// an enum mode, integers bounded by the trace cap, and five numbers. Keeping the set closed is what
// keeps the message inside the engine's MCP result budget - the version that inlined the sample
// window was truncated mid-array at 867 characters, which is why the window is read back from the
// folder instead.
export const WILDLIFE_ESSENTIAL_FIELDS = [
  'rules',
  'unmetIndex',
  'unmet',
  'matched',
  'total',
  'overflow',
  'unmetModeObserved',
  'closest',
];

// Serialized size the emitted message must stay under, marker included. The observed truncation was
// at 867 characters, so this bound is deliberately below it and is asserted against a worst case.
export const WILDLIFE_DIAGNOSIS_BUDGET = 800;

// Serialized length of a diagnosis message carrying this summary.
export function wildlifeDiagnosisLength(essentials) {
  return WILDLIFE_UNMET_MARKER.length + 1 + JSON.stringify(essentials).length;
}

const WILDLIFE_ESSENTIAL_KEYS = ['rules', 'unmetIndex', 'matched', 'total', 'overflow', 'unmetModeObserved'];

export function wildlifeDiagnosis(message) {
  const text = typeof message === 'string' ? message : '';
  const marker = text.lastIndexOf(WILDLIFE_UNMET_MARKER);
  if (marker < 0) return null;
  const tail = text.slice(marker + WILDLIFE_UNMET_MARKER.length).trim();
  const end = tail.lastIndexOf('}');
  if (end < 0) return null;
  let report;
  try { report = JSON.parse(tail.slice(0, end + 1)); } catch { return null; }
  if (!report || typeof report !== 'object' || Array.isArray(report)) return null;
  // Completeness is required, not assumed: a truncated message parses to an object missing keys.
  for (const key of WILDLIFE_ESSENTIAL_KEYS) if (!(key in report)) return null;
  if (!Number.isInteger(report.rules) || report.rules < 1) return null;
  if (!Number.isInteger(report.unmetIndex) || report.unmetIndex < 1) return null;
  if (!Number.isInteger(report.matched) || report.matched < 0) return null;
  if (!Number.isInteger(report.total) || report.total < 0) return null;
  if (typeof report.overflow !== 'boolean' || typeof report.unmetModeObserved !== 'boolean') return null;
  const unmet = report.unmet;
  if (unmet !== null && unmet !== undefined) {
    if (typeof unmet !== 'object' || Array.isArray(unmet) || typeof unmet.mode !== 'string') return null;
    for (const key of ['displacement', 'homeAtMost', 'outside', 'actorsHomeOutside']) {
      if (key in unmet && (!Number.isFinite(unmet[key]) || unmet[key] < 0)) return null;
    }
  }
  const closest = report.closest;
  if (closest !== null && closest !== undefined) {
    if (typeof closest !== 'object' || Array.isArray(closest)) return null;
    for (const key of ['displacement', 'homeDistance', 'minActorDistance', 'minActorHomeDistance']) {
      if (key in closest && closest[key] !== null && !Number.isFinite(closest[key])) return null;
    }
  }
  return {
    rules: report.rules,
    unmetIndex: report.unmetIndex,
    unmet: unmet ?? null,
    matched: report.matched,
    total: report.total,
    overflow: report.overflow,
    unmetModeObserved: report.unmetModeObserved,
    closest: closest ?? null,
  };
}
