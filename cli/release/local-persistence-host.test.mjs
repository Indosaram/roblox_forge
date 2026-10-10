import { test, expect } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openStore, startHost } from './local-persistence-host.mjs';

test('local request cap rejects invalid configuration before opening storage', () => {
  expect(() => startHost({ path: ':memory:', token: 'a'.repeat(64), namespace: 'owned', port: 0, maxConcurrentRequests: 0 })).toThrow('INVALID_LOCAL_REQUEST_CAP');
});

test('actual loopback HTTP enforces auth namespace CAS bounds and persisted wrapper readback', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'forge-local-http-'));
  const token = 'a'.repeat(64);
  let host;
  try {
    host = startHost({ path: join(directory, 'owned.sqlite'), token, namespace: 'owned', port: 0 });
    expect(host.ready.listening).toBe(true);
    expect(host.ready.hostname).toBe('127.0.0.1');
    const request = (route, body, authorization = `Bearer ${token}`) => fetch(`http://127.0.0.1:${host.ready.port}/${route}`, {
      method: 'POST', headers: { authorization, 'content-type': 'application/json' },
      body: typeof body === 'string' ? body : JSON.stringify(body), signal: AbortSignal.timeout(5000),
    });
    const read = { namespace: 'owned', key: 'personal:1' };
    for (const authorization of ['', 'Bearer wrong']) expect((await request('read', read, authorization)).status).toBe(403);
    expect((await request('read', { ...read, namespace: 'foreign' })).status).toBe(400);
    expect((await request('read', '{')).status).toBe(503);
    expect((await request('cas', { ...read, revision: 0, value: 'x'.repeat(4_194_305) })).status).toBe(400);
    const values = ['{"generation":1,"data":{"quantity":7}}', '{"generation":1,"data":{"quantity":8}}'];
    const responses = await Promise.all(values.map(value => request('cas', { ...read, revision: 0, value })));
    expect(responses.map(response => response.status).sort()).toEqual([200, 409]);
    const winner = responses.findIndex(response => response.status === 200);
    const stored = await (await request('read', read)).json();
    expect(stored).toEqual({ revision: 1, value: values[winner] });
    expect((await request('cas', { ...read, revision: 0, value: '{}' })).status).toBe(409);
    expect(await (await request('read', read)).json()).toEqual(stored);
    const observed = host.observation();
    expect(observed.backend).toBe('local-sqlite-cas');
    expect(observed.namespace).toBe('owned');
    expect(observed.configuredCaps).toEqual({ maxConcurrentRequests: 64, maxRequestBodyBytes: 8_500_000, maxValueBytes: 4_194_304, maxOutcomes: 4096 });
    expect(observed.requestCount).toBe(8);
    expect(observed.admittedCount).toBe(8);
    expect(observed.conflicts).toBe(2);
    expect(observed.casCount).toBe(3);
    expect(observed.readCount).toBe(2);
    expect(observed.failures).toBe(3);
    expect(observed.throttleCount).toBe(0);
    expect(observed.handledThrottleCount).toBe(0);
    expect(observed.coverageComplete).toBe(true);
    expect(observed.outcomes).toHaveLength(8);
    for (const response of responses) {
      expect(response.headers.get('x-forge-backend-epoch')).toBe(observed.epoch);
      const operation = Number(response.headers.get('x-forge-request-operation'));
      expect(Number.isSafeInteger(operation) && operation > 0).toBe(true);
      const row = observed.outcomes.find(value => value.operation === operation);
      expect(row.status).toBe(response.status);
      expect(row.key).toBe(read.key);
      expect(row.inputRevision).toBe(0);
      expect(row.acknowledgedRevision).toBe(response.status === 200 ? 1 : undefined);
      expect(row.value).toBeUndefined();
    }
    expect(observed.outcomes[0].key).toBeUndefined();
    expect(observed.endedAtMs).toBeGreaterThanOrEqual(observed.startedAtMs);
    expect((await (await request('observation', { namespace: 'owned' })).json()).epoch).toBe(observed.epoch);
    expect(host.observation().requestCount).toBe(8);
    observed.outcomes[0].status = 200;
    expect(host.observation().outcomes[0].status).toBe(400);
  } finally { host?.stop(); rmSync(directory, { recursive: true, force: true }); }
});

test('CAS rejects stale writes and reopens committed wrappers without replaying debit', () => {
  const directory = mkdtempSync(join(tmpdir(), 'forge-local-store-'));
  const path = join(directory, 'owned.sqlite');
  let store;
  try {
    store = openStore(path);
    expect(store.read('owned', 'personal:1').revision).toBe(0);
    expect(store.cas('owned', 'personal:1', 0, '{"generation":1,"quantity":7}').revision).toBe(1);
    expect(store.cas('owned', 'personal:1', 0, '{"quantity":4}')).toEqual({ conflict: true });
    store.close();
    store = openStore(path);
    expect(JSON.parse(store.read('owned', 'personal:1').value)).toEqual({ generation: 1, quantity: 7 });
    expect(store.read('other', 'personal:1').revision).toBe(0);
    store.cas('owned', 'a', 0, '{}');
    store.cas('other', 'foreign', 0, '{}');
    expect(store.rows('owned')).toEqual([
      { key: 'a', revision: 1, value: '{}' },
      { key: 'personal:1', revision: 1, value: '{"generation":1,"quantity":7}' },
    ]);
  } finally { store?.close(); rmSync(directory, { recursive: true, force: true }); }
});
