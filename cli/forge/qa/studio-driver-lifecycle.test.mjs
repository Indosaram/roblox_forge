import { test, expect } from 'bun:test';
import { StudioLifecycle } from './studio-driver-lifecycle.mjs';

test('targeted release closes only selected resource and remains idempotent',async()=>{
  const lifecycle=new StudioLifecycle();
  const closed=[];
  const host=lifecycle.attempt('host','host',async()=>{closed.push('host');return {released:true,evidence:{stopped:true}};});
  const editor=lifecycle.attempt('editor','editor',async()=>{closed.push('editor');return {released:true,evidence:{treeExited:true}};});
  expect((await lifecycle.release(editor)).released).toBe(true);
  await lifecycle.release(editor);
  expect(closed).toEqual(['editor']);
  expect(host.cleanup).toBe('pending');
  await lifecycle.close();
  expect(closed).toEqual(['editor','host']);
});

function fixture() {
  const timers = new Set();
  const lifecycle = new StudioLifecycle({ schedule: callback => { timers.add(callback); return callback; }, unschedule: callback => timers.delete(callback) });
  return { lifecycle, timers };
}

test('owned attempts are recorded before allocation and reconciled in reverse order', async () => {
  const { lifecycle } = fixture();
  const released = [];
  const transport = lifecycle.attempt('process', 'transport', async row => { released.push(row.id); return { released: true, evidence: { exitCode: 0 } }; });
  lifecycle.acquire(transport, { pid: 12, creationId: 'owned' });
  lifecycle.attempt('client', 'second-client', async row => {
    expect(row.acquired).toBe(false);
    released.push(row.id);
    return { released: true, evidence: { requestAbsentAndSettled: true } };
  });
  lifecycle.fail('second-client', 'OPERATION_FAILED');
  const receipt = await lifecycle.close();
  expect(released).toEqual(['second-client', 'transport']);
  expect(receipt.ok).toBe(false);
  expect(receipt.failure.phase).toBe('second-client');
  expect(receipt.residuals).toEqual([]);
  await lifecycle.close();
  expect(released.length).toBe(2);
});

test('event subscription precedes synchronous action and is always disposed', async () => {
  const { lifecycle, timers } = fixture();
  let listener, disposed = false;
  const result = await lifecycle.observe({ phase: 'input', subscribe: notify => { listener = notify; return () => { disposed = true; }; }, action: () => { listener('InputBegan'); return 'injected'; } });
  expect(result).toEqual({ value: 'injected', observed: 'InputBegan' });
  expect(disposed).toBe(true);
  expect(timers.size).toBe(0);
});

test('deadline bounds action even when its event arrived but invocation hangs', async () => {
  const { lifecycle, timers } = fixture();
  let entered;
  const started = new Promise(resolve => { entered = resolve; });
  let disposed = false, actionSignal;
  const pending = lifecycle.observe({ phase: 'admission', subscribe: notify => { notify('ready'); return () => { disposed = true; }; }, action: signal => { actionSignal = signal; entered(); return new Promise(() => {}); } });
  const rejected = pending.then(() => { throw new Error('expected deadline rejection'); }, error => error);
  await started;
  for (const expire of [...timers]) expire();
  expect((await rejected).message).toBe('OPERATION_TIMEOUT');
  expect(disposed).toBe(true);
  expect(actionSignal.aborted).toBe(true);
  expect(lifecycle.receipt().failure).toEqual({ phase: 'admission', code: 'OPERATION_TIMEOUT' });
});

test('cancellation aborts pending action and unregisters subscription', async () => {
  const { lifecycle, timers } = fixture();
  const cancel = new AbortController();
  let entered, disposed = false;
  const started = new Promise(resolve => { entered = resolve; });
  const pending = lifecycle.observe({ phase: 'capture', signal: cancel.signal, subscribe: () => () => { disposed = true; }, action: () => { entered(); return new Promise(() => {}); } });
  const rejected = pending.then(() => { throw new Error('expected cancellation rejection'); }, error => error);
  await started;
  cancel.abort();
  expect((await rejected).message).toBe('CANCELLED');
  expect(disposed).toBe(true);
  expect(timers.size).toBe(0);
});

test('unproven cleanup retains residual and continues without touching foreign resources', async () => {
  const { lifecycle } = fixture();
  const foreign = { closed: false };
  let transportClosed = false;
  lifecycle.attempt('process', 'owned-transport', async () => { transportClosed = true; return { released: true, evidence: { exitCode: 0 } }; });
  lifecycle.attempt('client', 'owned-client', async () => { throw new Error('transport unavailable'); });
  const receipt = await lifecycle.close();
  expect(transportClosed).toBe(true);
  expect(foreign.closed).toBe(false);
  expect(receipt.residuals).toEqual(['owned-client']);
  expect(receipt.ok).toBe(false);
});

test('a resource with its own cleanup bound is not cut off by the default timeout', async () => {
  const timers = [];
  const lifecycle = new StudioLifecycle({ timeoutMs: 10, schedule: (callback, ms) => { timers.push({ callback, ms }); return callback; }, unschedule: () => {} });
  let finish;
  const row = lifecycle.attempt('editor-process', 'slow-editor', () => new Promise(resolve => { finish = resolve; }), { cleanupTimeoutMs: 40000 });
  lifecycle.acquire(row, { pid: 1 });
  const closing = lifecycle.close();
  for (let i = 0; i < 10 && !finish; i++) await Promise.resolve();
  expect(timers.at(-1).ms).toBe(40000);
  finish({ released: true, evidence: { treeExited: true } });
  const receipt = await closing;
  expect(row.cleanup).toBe('released');
  expect(receipt.ok).toBe(true);
});
