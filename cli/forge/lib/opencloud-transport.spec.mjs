import { test, expect } from 'bun:test';
import { requestOnce } from './opencloud-transport.mjs';
import { createServer } from 'node:http';
import { once } from 'node:events';

test('response loss after receipt is ambiguous without another POST', async () => {
  let calls = 0;
  const server = createServer((request, response) => {
    calls++;
    request.resume();
    request.once('end', () => response.destroy());
  });
  const listening = once(server, 'listening');
  server.listen(0, '127.0.0.1');
  await listening;
  try {
    const result = await requestOnce({ url: `http://127.0.0.1:${server.address().port}`, headers: {}, body: 'held' });
    expect(result).toEqual({ error: 'PUBLISH_TRANSPORT_AMBIGUOUS' });
    expect(calls).toBe(1);
  } finally {
    const closed = once(server, 'close');
    server.close();
    server.closeAllConnections();
    await closed;
  }
}, 5000);

test('native fetch posts held bytes once and strips provider secrets', async () => {
  let calls = 0;
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, async fetch(request) {
    calls++;
    expect(request.headers.get('x-api-key')).toBe('fixture-secret');
    expect(await request.text()).toBe('held-artifact');
    return Response.json({ versionNumber: 7, secret: 'provider-secret' });
  } });
  try {
    const result = await requestOnce({ url: server.url.href, headers: { 'x-api-key': 'fixture-secret' }, body: Buffer.from('held-artifact') });
    expect(result).toEqual({ statusCode: 200, ok: true, body: '{"versionNumber":7}' });
    expect(calls).toBe(1);
  } finally { server.stop(true); }
});

test('abort after observed request is ambiguous and never retries', async () => {
  let received;
  const arrived = new Promise(resolve => { received = resolve; });
  let release;
  const blocked = new Promise(resolve => { release = resolve; });
  let calls = 0;
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, async fetch() {
    calls++;
    received();
    await blocked;
    return new Response('{}');
  } });
  const controller = new AbortController();
  try {
    const pending = requestOnce({ url: server.url.href, headers: {}, body: '' }, { signal: controller.signal });
    await arrived;
    controller.abort();
    expect(await pending).toEqual({ error: 'PUBLISH_TIMEOUT_AMBIGUOUS' });
    expect(calls).toBe(1);
  } finally { release(); server.stop(true); }
}, 5000);

test('rate limit and malformed success remain sanitized single attempts', async () => {
  for (const status of [429, 403, 200]) {
    let calls = 0;
    const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch() {
      calls++;
      return new Response('provider-secret', { status });
    } });
    try {
      expect(await requestOnce({ url: server.url.href, headers: {}, body: '' }))
        .toEqual({ statusCode: status, ok: status === 200, body: '' });
      expect(calls).toBe(1);
    } finally { server.stop(true); }
  }
});

test('success schema rejects error envelopes while deliberately allowing version metadata', async () => {
  for (const body of ['{"versionNumber":1,"errors":["secret"]}', '{"versionNumber":"1"}', '[]', '{"other":"secret"}']) {
    const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch() { return new Response(body); } });
    try {
      expect(await requestOnce({ url: server.url.href, headers: {}, body: '' }))
        .toEqual({ statusCode: 200, ok: true, body: '' });
    } finally { server.stop(true); }
  }
});
