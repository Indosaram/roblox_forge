import { test, expect } from 'bun:test';
import { persistenceSnapshot } from './capacity-collector.mjs';

// The readback requires explicit bounded limits; these mirror the collector's wrap-up
// phase: one fixed total deadline, one per-call cap, one accepted maximum capture.
const LIMITS = { totalBudgetMs: 600000, maxBytes: 33554432, chunkBudgetMs: 90000 };

const fixture = (json, { truncate = false } = {}) => {
  const b64 = Buffer.from(json, 'utf8').toString('base64');
  const partBytes = 180000;
  const calls = { setup: 0, subs: 0, destroyed: 0 };
  const rawCall = async code => {
    if (code.includes('jsonBytes')) {
      calls.setup += 1;
      return JSON.stringify({
        jsonBytes: Buffer.byteLength(json, 'utf8'),
        b64Bytes: b64.length,
        partBytes,
        parts: Math.ceil(b64.length / partBytes),
      });
    }
    const range = code.match(/local off=(\d+);local fin=(\d+)/);
    if (range) {
      calls.subs += 1;
      const piece = b64.slice(Number(range[1]) - 1, Number(range[2]));
      // Simulate the execute_luau text cap cutting a chunk mid-string.
      return truncate && calls.subs === 1 ? piece.slice(0, Math.max(1, piece.length - 8)) : piece;
    }
    if (code.includes('Destroy')) { calls.destroyed += 1; return 'gone'; }
    throw new Error('UNEXPECTED_RAW_CALL');
  };
  return { rawCall, calls };
};

test('persistenceSnapshot reassembles snapshots larger than the execute text cap', async () => {
  const payload = {
    identity: { mode: 'studio-local', namespace: 'capacity-qa', epoch: 7 },
    sequence: 41,
    attempts: 12,
    overflow: false,
    // Multibyte content forces byte-accurate base64 handling; the size pushes
    // the stream past one 60k chunk (and past a single 180k holder part).
    records: [{ key: 'camp-v1', value: '기록🚀'.repeat(20000) }],
  };
  const json = JSON.stringify(payload);
  const b64Bytes = Buffer.from(json, 'utf8').toString('base64').length;
  expect(b64Bytes).toBeGreaterThan(180000);
  const { rawCall, calls } = fixture(json);
  const snapshot = await persistenceSnapshot(rawCall, () => {}, LIMITS)();
  expect(snapshot).toEqual(payload);
  expect(calls.setup).toBe(1);
  expect(calls.subs).toBeGreaterThanOrEqual(4);
  expect(calls.destroyed).toBe(1);
});

test('persistenceSnapshot rejects a truncated chunk read and still clears the holder', async () => {
  const { rawCall, calls } = fixture(JSON.stringify({ identity: { mode: 'studio-local' }, records: [] }), { truncate: true });
  await expect(persistenceSnapshot(rawCall, () => {}, LIMITS)()).rejects.toThrow('PERSISTENCE_SNAPSHOT_TRUNCATED');
  expect(calls.destroyed).toBe(1);
});

test('persistenceSnapshot fails closed when setup reports no bytes', async () => {
  const rawCall = async code => {
    if (code.includes('jsonBytes')) return JSON.stringify({ jsonBytes: 0, b64Bytes: 0, partBytes: 180000, parts: 0 });
    if (code.includes('Destroy')) return 'gone';
    throw new Error('UNEXPECTED_RAW_CALL');
  };
  await expect(persistenceSnapshot(rawCall, () => {}, LIMITS)()).rejects.toThrow('PERSISTENCE_SNAPSHOT_UNAVAILABLE');
});
