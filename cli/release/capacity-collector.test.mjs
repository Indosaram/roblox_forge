import { test, expect } from 'bun:test';
import { readFileSync } from 'node:fs';
import { attempt, collectWindow, sampleCode, persistenceSnapshot, leaseIdentityRead, leaseExpiryRead } from './capacity-collector.mjs';
import { StudioLifecycle } from '../forge/qa/studio-driver-lifecycle.mjs';

// The readiness runtime both restart reads embed, and the module the Lune fixture drives.
const runtimeSource = readFileSync(new URL('./persistence-readiness.luau', import.meta.url), 'utf8');

test('UNIT the lease-restart reads wait for the restarted server bootstrap before they read', () => {
  // The embedded ForgeBuildIdentity script assigns its Handshake and the RuntimeBackend publishes
  // ForgePersistence with ObservedLeaseExpiry, both after the datamodel is reachable, so each read is
  // preceded by the bounded readiness wait for its own object and runs after that wait.
  expect(leaseIdentityRead).toContain(runtimeSource);
  expect(leaseIdentityRead).toContain("ForgeQAReadiness.await({service=game:GetService('ServerScriptService')");
  // No condition: the producer assigns the callback before parenting the child, so the parented
  // child is the contract and the spec carries no condition.
  expect(leaseIdentityRead).toContain("{object='ForgeBuildIdentity',child='Handshake',childClass='BindableFunction',budgetMs=25000}");
  expect(leaseIdentityRead).not.toContain('OnInvoke');
  expect(leaseIdentityRead.indexOf('ForgeQAReadiness.await('))
    .toBeLessThan(leaseIdentityRead.indexOf('ForgeBuildIdentity.Handshake:Invoke()'));
  expect(leaseExpiryRead).toContain(runtimeSource);
  expect(leaseExpiryRead).toContain("ForgeQAReadiness.await({service=game:GetService('ServerStorage')");
  expect(leaseExpiryRead).toContain("{object='ForgePersistence',attribute='ObservedLeaseExpiry',budgetMs=25000}");
  expect(leaseExpiryRead.indexOf('ForgeQAReadiness.await('))
    .toBeLessThan(leaseExpiryRead.indexOf("ForgePersistence:GetAttribute('ObservedLeaseExpiry')"));
});

test('recovery still requires actual maintained launch admission', async () => {
  const report = await attempt({ recovery: 'transfer', players: 8 }, {
    request: async () => ({ tools: [] }),
  }, new StudioLifecycle());
  expect(report.ok).toBe(false);
  expect(report.admittedPlayers).toBe(0);
  expect(report.admission.attempted).toBe(false);
});

test('actual admission refuses absent schemas without allocating or sampling', async () => {
  const calls = [];
  const transport = { request: async (method) => { calls.push(method); return { tools: [] }; },
    call: async () => { throw new Error('allocation must not run'); } };
  const lifecycle = new StudioLifecycle();
  const report = await attempt({ players: 8 }, transport, lifecycle);
  expect(report.ok).toBe(false);
  expect(report.admittedPlayers).toBe(0);
  expect(calls).toEqual(['tools/list']);
  // The host CIM probe now runs before launch; it must appear only as a
  // self-released record, with no allocated Studio resource left behind.
  const resources = (await lifecycle.close()).resources;
  expect(resources.filter(resource => resource.state === 'acquired')).toEqual([]);
  expect(resources.filter(resource => resource.kind !== 'hardware-probe')).toEqual([]);
}, 30000);

test('duplicate actual sessions reject before execute', async () => {
  const lifecycle = new StudioLifecycle();
  let calls = 0;
  await expect(collectWindow({ serverId: 'server', clients: [
    { studioId: 'same', actorId: '1' }, { studioId: 'same', actorId: '2' } ],
    execute: async () => { calls++; } }, { players: 2 }, lifecycle)).rejects.toThrow('DUPLICATE_CLIENT');
  expect(calls).toBe(0);
  await lifecycle.close();
});

test('loaded identity mismatch rejects returned measurements', async () => {
  const lifecycle = new StudioLifecycle();
  const buildIdentity = `sha256:${'a'.repeat(64)}`;
  const payload = JSON.stringify({ loaded: { buildIdentity, sessionId: 'foreign' },
    frameMs: [1], engineDtMs: [1], memoryMb: [1], updateAsyncBudget: [], sampleTimes: [1],
    startedAtSeconds: 1, endedAtSeconds: 2, robloxVersion: 'test' });
  await expect(collectWindow({ serverId: 'server', serverSessionId: 'owned',
    clients: [{ studioId: 'client', actorId: '1' }],
    execute: async () => ({ parts: [payload.length], bytes: payload.length,
      startedAtSeconds: 1, endedAtSeconds: 2, holder: 'ForgeCapacitySample1' }),
    executeRawText: async (studioId, model, code) =>
      code.includes('return v.Value') ? payload : 'gone' },
  { players: 1, buildIdentity, startSeconds: 1, endSeconds: 2, timeoutMs: 1000 }, lifecycle))
    .rejects.toThrow('LOADED_IDENTITY_MISMATCH');
  await lifecycle.close();
});


// Exact call discrimination: the setup payload also destroys holders, so the destroy
// call is identified by its unique terminator, never by 'c:Destroy()'.
const isRead = code => code.includes('local off=');
const isDestroy = code => code.includes("return 'gone'");
const snapshotPayload = () => {
  const payload = `{"pad":"${'x'.repeat(89990)}"}`;
  const jsonBytes = Buffer.byteLength(payload, 'utf8');
  return { payload, jsonBytes, b64: Buffer.from(payload, 'utf8').toString('base64') };
};

test('UNIT sampler emits the observed frame period on its own clock with engine dt as provenance', () => {
  const code = sampleCode({ buildIdentity: `sha256:${'a'.repeat(64)}`, actorId: '-1',
    startSeconds: 100, endSeconds: 400, server: true, sliceIndex: 1 });
  // Emitted machine tokens: the sampler body is Luau and is not executed here.
  expect(code).toContain('table.insert(frames,(now-lastNow)*1000)');
  expect(code).toContain('local lastNow=workspace:GetServerTimeNow()');
  expect(code).toContain('table.insert(engineDt,dt*1000)');
  expect(code).toContain('engineDtMs=engineDt');
  expect(code).not.toContain('table.insert(frames,dt*1000)');
  expect(code).toContain("assert(frames[i]>0,'SAMPLE_CLOCK_NONPOSITIVE')");
});

test('UNIT merged window carries engine dt provenance beside the measured period', async () => {
  const lifecycle = new StudioLifecycle();
  const buildIdentity = `sha256:${'a'.repeat(64)}`;
  const payload = JSON.stringify({ loaded: { role: 'server', buildIdentity, sessionId: 'owned' },
    frameMs: [30, 31], engineDtMs: [0, 31], memoryMb: [100, 101], updateAsyncBudget: [],
    sampleTimes: [1, 1.03], startedAtSeconds: 1, endedAtSeconds: 2, robloxVersion: 'test' });
  const rows = await collectWindow({ serverId: 'server', serverSessionId: 'owned', clients: [],
    execute: async () => ({ parts: [payload.length], bytes: payload.length,
      startedAtSeconds: 1, endedAtSeconds: 2, holder: 'ForgeCapacitySample1' }),
    executeRawText: async (studioId, model, code) => code.includes('return v.Value') ? payload : 'gone' },
  { players: 0, buildIdentity, startSeconds: 1, endSeconds: 2, timeoutMs: 1000 }, lifecycle);
  expect(rows[0].frameMs).toEqual([30, 31]);
  expect(rows[0].engineDtMs).toEqual([0, 31]);
  expect(rows[0].sampleTimes).toEqual([1, 1.03]);
  await lifecycle.close();
});

test('UNIT snapshot readback requires explicit bounded limits', async () => {
  await expect(persistenceSnapshot(async () => '{}', () => {})())
    .rejects.toThrow('PERSISTENCE_SNAPSHOT_LIMITS_REQUIRED');
  await expect(persistenceSnapshot(async () => '{}', () => {},
    { totalBudgetMs: 60000, maxBytes: Number.POSITIVE_INFINITY, chunkBudgetMs: 90000 })())
    .rejects.toThrow('PERSISTENCE_SNAPSHOT_LIMITS_REQUIRED');
});

test('UNIT snapshot readback refuses a capture above the explicit accepted maximum and still cleans up', async () => {
  const { b64, jsonBytes } = snapshotPayload();
  const setup = JSON.stringify({ jsonBytes, b64Bytes: b64.length, partBytes: 180000, parts: 1 });
  const calls = [];
  const rawCall = async code => {
    if (isRead(code)) { calls.push('read'); return ''; }
    if (isDestroy(code)) { calls.push('destroy'); return 'gone'; }
    calls.push('setup');
    return setup;
  };
  await expect(persistenceSnapshot(rawCall, () => {}, { totalBudgetMs: 600000, maxBytes: 1000, chunkBudgetMs: 90000 })())
    .rejects.toThrow('PERSISTENCE_SNAPSHOT_TOO_LARGE');
  // The bounded destroy still runs after the refusal; no read was attempted.
  expect(calls).toEqual(['setup', 'destroy']);
});

test('UNIT snapshot readback enforces one bounded total deadline and still cleans up', async () => {
  const { b64, jsonBytes } = snapshotPayload();
  const setup = JSON.stringify({ jsonBytes, b64Bytes: b64.length, partBytes: 180000, parts: 1 });
  const realNow = Date.now;
  let clock = 1000000;
  const calls = [];
  const budgets = [];
  Date.now = () => clock;
  try {
    const rawCall = async code => {
      if (isRead(code)) {
        calls.push('read');
        const read = code.match(/local off=(\d+);local fin=(\d+)/);
        clock += 60000;
        return b64.slice(Number(read[1]) - 1, Number(read[2]));
      }
      if (isDestroy(code)) { calls.push('destroy'); return 'gone'; }
      calls.push('setup');
      clock += 5000;
      return setup;
    };
    await expect(persistenceSnapshot(rawCall, budget => { budgets.push(budget); },
      { totalBudgetMs: 60000, maxBytes: 33554432, chunkBudgetMs: 90000 })())
      .rejects.toThrow('PERSISTENCE_SNAPSHOT_BUDGET_EXHAUSTED');
    // Setup and the first chunk are admitted, the second is refused by the fixed total
    // deadline, and the separately capped destroy still runs so no holder leaks.
    expect(calls).toEqual(['setup', 'read', 'destroy']);
    // setup arms the full remaining 60000; the single admitted chunk arms 55000;
    // the separately capped destroy arms the 90000 per-call cap.
    expect(budgets).toEqual([60000, 55000, 90000]);
  } finally { Date.now = realNow; }
});
