const q = JSON.stringify;
export async function parallelPrompt(step, actors, serverId, genre, rawExecute, rawCall) {
  if (!Number.isFinite(step.timeout_seconds) || step.timeout_seconds <= 0) throw new Error('CONTENTION_TIMEOUT_REQUIRED');
  const deadline = performance.now() + step.timeout_seconds * 1000;
  let failed = false;
  const remaining = () => Math.max(0, deadline - performance.now());
  const bounded = async (action, budget, code) => {
    if (budget <= 0) throw new Error(code);
    let timer;
    try {
      return await Promise.race([Promise.resolve().then(action), new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(code)), budget);
      })]);
    } finally { clearTimeout(timer); }
  };
  const execute = (...args) => {
    if (failed) return Promise.reject(new Error('CONTENTION_GROUP_ABORTED'));
    return bounded(() => rawExecute(...args), remaining(), 'CONTENTION_GROUP_TIMEOUT');
  };
  const call = (...args) => {
    if (failed) return Promise.reject(new Error('CONTENTION_GROUP_ABORTED'));
    return bounded(() => rawCall(...args), remaining(), 'CONTENTION_GROUP_TIMEOUT');
  };
  const attempted = [];
  const marker = 'ForgeQAParallelPrompt';
  const nodeSnapshot = () => execute(serverId, 'Server', `local target=game;for part in string.gmatch(${q(step.target)},'[^.]+') do target=target:FindFirstChild(part);assert(target,'gather target missing') end
assert(target:IsA('ProximityPrompt'),'gather prompt required');local node=target.Parent.Parent
local value={id=node:GetAttribute('ForgeNodeId'),version=node:GetAttribute('ForgeNodeVersion'),charges=node:GetAttribute('ForgeNodeCount'),depleted=node:GetAttribute('ForgeNodeDepleted')}`);
  const snapshot = actor => execute(serverId, 'Server', `local value=game:GetService('ServerStorage').ForgeQA.snapshot:Invoke(${q(genre)},${q(actor.userId)})`);
  const quantity = state => {
    const items = state?.inventory?.bag?.items;
    if (!items) throw new Error('CONTENTION_INVENTORY_UNAVAILABLE');
    return Object.values(items).filter(item => item.catalogId === step.conservation.catalogId).reduce((sum, item) => sum + item.quantity, 0);
  };
  try {
    const beforeNode = await nodeSnapshot();
    if(beforeNode.id!==step.nodeId || beforeNode.charges!==1 || beforeNode.depleted!==false || !Number.isFinite(beforeNode.version))throw new Error('CONTENTION_FINAL_CHARGE_REQUIRED');
    const before = await Promise.all(actors.map(snapshot));
    const readiness = await Promise.all(actors.map(async actor => {
      attempted.push(actor);
      return execute(actor.studioId, 'Client', `local p=game:GetService('Players').LocalPlayer
local target=game;for name in string.gmatch(${q(step.target)},'[^.]+') do target=target:FindFirstChild(name);assert(target,'prompt missing') end
assert(target:IsA('ProximityPrompt'),'prompt required');local node=target.Parent.Parent
assert(node:GetAttribute('ForgeNodeId')==${q(step.nodeId)},'wrong node')
local relay=p:FindFirstChild('ForgeGatherResult');assert(relay,'gather relay missing')
local requested=p:FindFirstChild('ForgeGatherRequested');assert(requested and requested:IsA('BindableEvent'),'CONTENTION_REQUEST_TELEMETRY_UNAVAILABLE')
assert(not p:FindFirstChild('${marker}'),'parallel subscription exists')
local m=Instance.new('StringValue');m.Name='${marker}';m.Parent=p
local inputAt,triggerAt;local connections={};local requestId;local request
table.insert(connections,requested.Event:Connect(function(packet)
 if packet.nodeId==${q(step.nodeId)} then
  if request then m.Value='INVALID';return end
  request=packet
 end
end))
table.insert(connections,game:GetService('UserInputService').InputBegan:Connect(function(input) if input.KeyCode==Enum.KeyCode.E then inputAt=workspace:GetServerTimeNow() end end))
table.insert(connections,game:GetService('ProximityPromptService').PromptTriggered:Connect(function(prompt) if prompt==target then triggerAt=workspace:GetServerTimeNow() end end))
table.insert(connections,relay.Event:Connect(function(packet)
 if packet.nodeId==${q(step.nodeId)} and inputAt and triggerAt then
  if type(packet.requestId)~='string' or (requestId and packet.requestId~=requestId) then m.Value='INVALID';return end
  requestId=packet.requestId
  if packet.result and packet.result.data and packet.result.data.status=='pending' then return end
  if not request or request.requestId~=packet.requestId then m.Value='INVALID';return end
  m.Value=game:GetService('HttpService'):JSONEncode({packet=packet,request=request,inputAt=inputAt,triggerAt=triggerAt,resultAt=workspace:GetServerTimeNow()})
 end
end))
m.Destroying:Once(function() for _,connection in connections do connection:Disconnect() end end)
local value={version=node:GetAttribute('ForgeNodeVersion'),readyAt=workspace:GetServerTimeNow()}`);
    }));
    if (readiness.some(row => row.version !== beforeNode.version)) throw new Error('CONTENTION_NODE_VERSION_MISMATCH');
    // Both complete subscription acknowledgements precede either injected key.
    await Promise.all(actors.map(actor => call('user_keyboard_input', { studio_id: actor.studioId, datamodel_type: 'Client', actions: [{ action: 'keyDown', key_code: 'E' }] })));
    const outcomes = await Promise.all(actors.map(actor => execute(actor.studioId, 'Client', `local m=game:GetService('Players').LocalPlayer:FindFirstChild('${marker}');assert(m,'subscription missing')
if m.Value=='' then observe(m.Changed,function() return true end,function() return m.Value=='' end,${Math.max(0.001, remaining()/1000)}) end
assert(m.Value~='' and m.Value~='INVALID','terminal correlated result missing');local value=game:GetService('HttpService'):JSONDecode(m.Value)`)));
    const packets = outcomes.map(row => row.packet);
    for(let index=0;index<outcomes.length;index++) {
      const row=outcomes[index],request=row.request;
      if(request.nodeId!==step.nodeId || String(request.actorId)!==actors[index].userId || request.requestId!==row.packet.requestId || request.nodeVersion!==readiness[0].version || !Number.isFinite(request.serverTime) || request.serverTime<row.inputAt || request.serverTime>row.resultAt) throw new Error('CONTENTION_DISPATCH_IDENTITY_MISMATCH');
    }
    if(Math.max(...outcomes.map(row=>row.request.serverTime))>Math.min(...outcomes.map(row=>row.resultAt)))throw new Error('CONTENTION_REQUESTS_DID_NOT_OVERLAP');
    if (new Set(packets.map(packet => packet.requestId)).size !== actors.length) throw new Error('CONTENTION_REQUEST_COLLISION');
    if (packets.filter(packet => packet.result?.ok === true).length !== step.expect.ok || packets.filter(packet => packet.result?.ok === false).length !== step.expect.refused) throw new Error('CONTENTION_OUTCOME_MISMATCH');
    for (const packet of packets) if (!packet.result.ok && !step.refusalReasons.includes(packet.result.reason)) throw new Error('CONTENTION_REFUSAL_MISMATCH');
    const after = await Promise.all(actors.map(snapshot));
    const afterNode = await nodeSnapshot();
    if(afterNode.id!==beforeNode.id || afterNode.charges!==0 || afterNode.depleted!==true || !Number.isFinite(afterNode.version) || afterNode.version<=beforeNode.version)throw new Error('CONTENTION_FINAL_CHARGE_NOT_CONSUMED');
    const ordered = value => Array.isArray(value) ? value.map(ordered) : value && typeof value === 'object'
      ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value;
    const canonical = value => JSON.stringify(ordered(value));
    for (let index=0;index<actors.length;index++) {
      const oldItems=before[index].inventory.bag.items,newItems=after[index].inventory.bag.items;
      if (!packets[index].result.ok && canonical(oldItems)!==canonical(newItems)) throw new Error('CONTENTION_LOSER_INVENTORY_CHANGED');
      const other = items => Object.fromEntries(Object.entries(items).filter(([,item]) => item.catalogId!==step.conservation.catalogId));
      if (canonical(other(oldItems))!==canonical(other(newItems))) throw new Error('CONTENTION_UNRELATED_INVENTORY_CHANGED');
      if (packets[index].result.ok && packets[index].result.data?.status!=='confirmed') throw new Error('CONTENTION_CONFIRMATION_REQUIRED');
    }
    const delta = after.reduce((sum, state) => sum + quantity(state), 0) - before.reduce((sum, state) => sum + quantity(state), 0);
    if (delta !== step.conservation.quantityGain) throw new Error('CONTENTION_CONSERVATION_FAILED');
    return { readiness, outcomes, actors: actors.map(actor => actor.userId), before, after, beforeNode, afterNode, quantityGain: delta };
  } finally {
    failed = true;
    // These requests have an independent cleanup budget. A timed-out remote
    // action is not assumed cancelled: production must still close its owned
    // process Job to settle late work before claiming successful cleanup.
    const cleanupDeadline = performance.now() + 10000;
    const clean = action => bounded(action, Math.max(0, cleanupDeadline-performance.now()), 'CONTENTION_CLEANUP_TIMEOUT');
    const cleanup = await Promise.allSettled(attempted.map(async actor => {
      try { await clean(() => rawCall('user_keyboard_input', { studio_id: actor.studioId, datamodel_type: 'Client', actions: [{ action: 'keyUp', key_code: 'E' }] })); }
      finally { await clean(() => rawExecute(actor.studioId, 'Client', `local m=game:GetService('Players').LocalPlayer:FindFirstChild('${marker}');if m then m:Destroy() end;local value={clean=true}`)); }
    }));
    if (cleanup.some(result => result.status === 'rejected')) throw new Error('CONTENTION_CLEANUP_UNRESOLVED');
  }
}
