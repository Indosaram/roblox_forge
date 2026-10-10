import { test, expect } from 'bun:test';
import { recoverAtBarrier, saturateCaps } from './capacity-recovery.mjs';

test('recovery cannot terminate a job without actual barrier port', async () => {
  let killed = false;
  await expect(recoverAtBarrier({ session: { controller: { terminateAtBarrier: async () => { killed = true; } } },
    runtime: {}, checkpoint: 'ESCROWED', binding: {}, restart: async () => {} })).rejects.toThrow('LIVE_BARRIER_ADAPTER_REQUIRED');
  expect(killed).toBe(false);
});

test('local snapshot cannot stand in for persistent crash evidence', async () => {
  await expect(recoverAtBarrier({ session: { crashAtBarrier() {} }, checkpoint: 'CREDITED', binding: { namespace: 'n' },
    key: 'key', requestId: 'request', trigger() {},
    runtime: { subscribeBarrier() {}, triggerBarrier() {}, persistentSnapshot: async () => ({ namespace: 'n', backend: 'Memory' }) },
    restart: async () => {} })).rejects.toThrow('PERSISTENT_SNAPSHOT_REQUIRED');
});

test('saturation requires actual configured caps before triggering operations', async () => {
  let triggered = false;
  await expect(saturateCaps({ configuredLimits: async () => ({}), saturate: async () => { triggered = true; } }))
    .rejects.toThrow('ACTUAL_CAP_REQUIRED:payloadBytes');
  expect(triggered).toBe(false);
});
