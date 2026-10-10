import { gameplay, resolveReferences } from '../forge/qa/studio-driver-gameplay.mjs';
import { inputStep } from '../forge/qa/studio-driver-input.mjs';

// Workload uses the maintained real input drivers. It never invokes domain
// commands, changes inventory, advances the game clock or supplies fixture data.
export const observedWait = `local function observe(signal,action,required,timeoutSeconds)
 local event=Instance.new('BindableEvent');local complete=false;local observed;local failure;local result;local worker
 local connection=signal:Connect(function(v) observed=v or true;if complete then event:Fire() end end)
 local expired=false
 local deadline=task.delay(timeoutSeconds or 10,function() expired=true;event:Fire() end)
 worker=task.defer(function() local ok,v=pcall(action);if ok then result=v else failure=v end;complete=true;event:Fire() end)
 while not expired and (not complete or (not failure and required(result) and observed==nil)) do event.Event:Wait() end
 connection:Disconnect();if coroutine.status(deadline)=='suspended' then task.cancel(deadline) end
 if coroutine.status(worker)=='suspended' then task.cancel(worker) end;event:Destroy()
 assert(not expired,'WORKLOAD_EVENT_TIMEOUT');assert(not failure,failure);return result,observed
end`;

const path = (...names) => ['Players', 'LocalPlayer', 'PlayerGui', 'ForgeSurvivalHUD', 'SafeArea', 'SurvivalSheet', 'Content', ...names];
const field = (value, keys) => {
  for (const key of Array.isArray(keys) ? keys : keys.split('.')) value = value?.[key];
  return value;
};
const resolve = (value, bindings) => {
  if (!value || typeof value !== 'object' || 'ref' in value) return resolveReferences(value, bindings);
  if (Array.isArray(value)) return value.map(item => resolve(item, bindings));
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, resolve(item, bindings)]));
};

export async function executeSteps(steps, client, owned, ports) {
  const bindings = new Map();
  const receipts = [];
  let last;
  for (const [index, original] of steps.entries()) {
    try {
    const step = resolve(original, bindings);
    if (step.op === 'bind_result') {
      const value = field(last?.result, step.field);
      if (value === undefined) throw new Error('WORKLOAD_RESULT_BINDING_MISSING');
      bindings.set(step.label, value);
      continue;
    }
    if (step.op === 'bind_snapshot') {
      const snapshot = await ports.snapshot(client.userId);
      let value = field(snapshot, step.field);
      if (step.select) {
        const conditions = Array.isArray(step.select) ? step.select : [step.select];
        const matchesCondition = (item, condition) => {
          const actual = field(item, condition.field);
          if (condition.empty === true) {
            if (Array.isArray(actual)) return actual.length === 0;
            return actual !== null && typeof actual === 'object' && Object.keys(actual).length === 0;
          }
          if (condition.equals !== null && typeof condition.equals === 'object') return JSON.stringify(actual) === JSON.stringify(condition.equals);
          return actual === condition.equals;
        };
        value = Object.entries(value || {}).filter(([, item]) => conditions.every(condition => matchesCondition(item, condition)))[0]?.[0];
      }
      if (value === undefined) throw new Error('WORKLOAD_SNAPSHOT_BINDING_MISSING');
      bindings.set(step.label, value);
      continue;
    }
    const before = await ports.clock();
    if (['walk_to', 'activate_prompt'].includes(step.op)) last = await gameplay(step, client, ports.execute, ports.call);
    else if (['keyboard', 'click', 'wait_for', 'equip'].includes(step.op)) last = await inputStep(step, client, owned.serverId, 'survival-coop', ports.execute, ports.call);
    else throw new Error('WORKLOAD_SHORTCUT_OR_UNSUPPORTED_STEP');
    const after = await ports.clock();
    receipts.push({ actorId: client.userId, studioId: client.studioId, op: step.op,
      action: step.resultAction || (step.op === 'activate_prompt' ? 'survival-coop:gather' : null),
      recipeId: step.recipeId, structureId: step.structureId,
      before, after, result: last });
    } catch (cause) {
      const error = new Error('WORKLOAD_STEP_FAILED', { cause });
      error.receipts = receipts;
      error.failedStep = { index, step: original, actorId: client.userId,
        code: String(cause?.message || cause) };
      throw error;
    }
  }
  return receipts;
}

export function actorSteps() {
  return [
    { op: 'walk_to', target: 'Workspace.DevelopmentIsland.fiber-bush-01', withinStuds: 6, timeout_seconds: 40 },
    { op: 'activate_prompt', target: 'Workspace.DevelopmentIsland.fiber-bush-01.ForgeGatherAnchor.ForgeGather', nodeId: 'fiber-bush-01', timeout_seconds: 15 },
    { op: 'keyboard', key: 'C', timeout_seconds: 5 },
    { op: 'click', target: path('Recipe-cord'), timeout_seconds: 5 },
    { op: 'click', target: path('Reserve-cord'), resultAction: 'survival-coop:craft-reserve', expect: 'ok', timeout_seconds: 10 },
    { op: 'bind_result', field: 'data.jobId', label: 'job' },
    { op: 'click', target: path({ ref: 'job', prefix: 'start-' }), resultAction: 'survival-coop:craft-start', expect: 'ok', timeout_seconds: 10 },
    { op: 'bind_snapshot', field: ['workshop', 'entries', { ref: 'job' }, 'job', 'finishAt'], label: 'finish' },
    { op: 'wait_for', timeout_seconds: 20, predicate: { source: 'snapshot', field: 'vitals.clockMillis', at_least: { ref: 'finish' } } },
    { op: 'click', target: path({ ref: 'job', prefix: 'complete-' }), resultAction: 'survival-coop:craft-complete', recipeId: 'cord', expect: 'ok', timeout_seconds: 10 },
    { op: 'keyboard', key: 'C', timeout_seconds: 5 },
    { op: 'walk_to', target: 'Workspace.DevelopmentIsland.fallen-tree-01', withinStuds: 6, timeout_seconds: 40 },
    { op: 'activate_prompt', target: 'Workspace.DevelopmentIsland.fallen-tree-01.ForgeGatherAnchor.ForgeGather', nodeId: 'fallen-tree-01', timeout_seconds: 15 },
    { op: 'bind_snapshot', field: 'inventory.bag.items', select: { field: 'catalogId', equals: 'wood' }, label: 'wood' },
    { op: 'walk_to', target: 'Workspace.DevelopmentIsland.WarehouseApproach', withinStuds: 2, timeout_seconds: 40 },
    { op: 'keyboard', key: 'I', timeout_seconds: 5 },
    { op: 'click', target: path('InventoryGrid', { ref: 'wood' }), timeout_seconds: 5 },
    { op: 'click', target: path({ ref: 'wood', prefix: 'Deposit-' }), resultAction: 'survival-coop:transfer-deposit', expect: 'ok', timeout_seconds: 15 },
    { op: 'keyboard', key: 'I', timeout_seconds: 5 },
  ];
}

export function buildSteps() {
  return [
    { op: 'walk_to', target: 'Workspace.DevelopmentIsland.BuildApproach', withinStuds: 2, timeout_seconds: 40 },
    { op: 'keyboard', key: 'B', timeout_seconds: 5 },
    { op: 'click', target: path('Structure-floor'), timeout_seconds: 5 },
    ...Array.from({ length: 5 }, () => ({ op: 'click', target: path('X+'), timeout_seconds: 5 })),
    { op: 'click', target: path('Z+'), timeout_seconds: 5 },
    { op: 'click', target: path('BuildReserve-floor'), resultAction: 'survival-coop:settlement-reserve', expect: 'ok', timeout_seconds: 10 },
    { op: 'bind_result', field: 'data.reservationId', label: 'floor' },
    { op: 'click', target: path({ ref: 'floor', prefix: 'place-' }), resultAction: 'survival-coop:settlement-place', structureId: 'floor', expect: 'ok', timeout_seconds: 10 },
    { op: 'keyboard', key: 'B', timeout_seconds: 5 },
  ];
}

// Plans that share a gather node must not run concurrently: the second actor's
// raycast passes through the first actor's body (NODE_UNREACHABLE) and both stand
// inside the node's geometry. Actors with disjoint nodes keep full parallelism,
// which is the realistic contention the workload must preserve.
export function gatherWaves(plans) {
  const planNodes = plans.map(plan => new Set(plan.filter(step => step.nodeId).map(step => step.nodeId)));
  const waves = [];
  for (let index = 0; index < plans.length; index += 1) {
    const used = planNodes[index];
    let wave = waves.find(entry => [...used].every(nodeId => !entry.nodes.has(nodeId)));
    if (!wave) { wave = { nodes: new Set(), indices: [] }; waves.push(wave); }
    wave.indices.push(index);
    for (const nodeId of used) wave.nodes.add(nodeId);
  }
  return waves;
}

export async function runWorkload(owned, ports) {
  if (owned.clients.length !== 8 || new Set(owned.clients.map(client => client.userId)).size !== 8) throw new Error('EIGHT_ACTUAL_ACTORS_REQUIRED');
  const configuredOwner = owned.clients.find(client => client.userId === '-1');
  if (!configuredOwner) throw new Error('CONFIGURED_OWNER_NOT_LOADED');
  owned = { ...owned, clients: [configuredOwner, ...owned.clients.filter(client => client !== configuredOwner)] };
  // Bounded happy workload: owner spends two of three tree charges (six wood)
  // and one fiber charge. Others use the remaining configured charges. No
  // recharge, fixture mint, eight-member tribe or extra starting inventory.
  const owner = actorSteps();
  const treePrompt = owner.findIndex(step => step.nodeId === 'fallen-tree-01');
  owner.splice(treePrompt + 1, 0, { ...owner[treePrompt] });
  const deposit = owner.findIndex(step => step.resultAction === 'survival-coop:transfer-deposit');
  owner.splice(deposit + 1, 0, ...Array.from({ length: 5 }, () => [
    { op: 'bind_snapshot', field: 'inventory.bag.items', select: { field: 'catalogId', equals: 'wood' }, label: 'wood' },
    { op: 'click', target: path('InventoryGrid', { ref: 'wood' }), timeout_seconds: 5 },
    { ...owner[deposit] },
  ]).flat());
  const nodes = ['fiber-bush-01', 'fiber-bush-01', 'fallen-tree-01', 'flint-outcrop-01', 'flint-outcrop-01', 'berry-bush-01', 'meat-cache-01'];
  const plans = [owner, ...nodes.map(nodeId => [
    { op: 'walk_to', target: `Workspace.DevelopmentIsland.${nodeId}`, withinStuds: 3, timeout_seconds: 40 },
    { op: 'activate_prompt', target: `Workspace.DevelopmentIsland.${nodeId}.ForgeGatherAnchor.ForgeGather`, nodeId, timeout_seconds: 15 },
  ])];
  // Same-node gathers must not overlap: a concurrent second attempt meets the
  // per-source lock (SOURCE_BUSY), raycasts through the first actor's body
  // (NODE_UNREACHABLE), or arrives after the winner's commit and refuses with
  // the contract's STALE_VERSION. Actors keep full parallelism across distinct
  // nodes -- the realistic contention this workload must preserve -- and the
  // prompt driver absorbs SOURCE_BUSY by replaying the same unresolved request
  // and STALE_VERSION by re-reading the published attributes under a new one.
  const waves = gatherWaves(plans);
  const rows = new Array(plans.length);
  for (const wave of waves) {
    const settled = await Promise.allSettled(wave.indices.map(index => executeSteps(plans[index], owned.clients[index], owned, ports)));
    wave.indices.forEach((index, position) => { rows[index] = settled[position]; });
  }
  const actions = rows.flatMap(row => row.status === 'fulfilled' ? row.value : row.reason?.receipts || []);
  const failed = rows.flatMap((row, index) => row.status === 'rejected' ? [{ actorId: owned.clients[index].userId, code: String(row.reason?.cause?.message || row.reason), failedStep: row.reason?.failedStep }] : []);
  if (failed.length) return { ok: false, actions, failed };
  try { actions.push(...await executeSteps(buildSteps(), owned.clients[0], owned, ports)); }
  catch (error) { actions.push(...(error.receipts || [])); failed.push(error.failedStep); }
  return { ok: failed.length === 0, actions, failed, dimensions: { serverActors: 8, sharedMutationActors: 1,
    configuredTribeLimit: 4, personalOnlyActors: 7, treeCharges: 3, fiberCharges: 3,
    flintCharges: 2, berryCharges: 1, meatCharges: 1, ownerWoodDeposited: 6, floorCostWood: 4 } };
}
