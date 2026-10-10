import { Database } from 'bun:sqlite';

// First-party local test service. No Roblox service durability claim.
export function openStore(path) {
  if (typeof path !== 'string' || !path || path === ':memory:') throw new Error('PERSISTENT_LOCAL_PATH_REQUIRED');
  const db = new Database(path, { create: true });
  db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS records (namespace TEXT NOT NULL, key TEXT NOT NULL, revision INTEGER NOT NULL, value TEXT NOT NULL, PRIMARY KEY(namespace,key))');
  const get = db.query('SELECT revision,value FROM records WHERE namespace=? AND key=?');
  const rows = db.query('SELECT key,revision,value FROM records WHERE namespace=? ORDER BY key');
  const put = db.query('INSERT INTO records VALUES (?,?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET revision=excluded.revision,value=excluded.value');
  const transaction = db.transaction((namespace, key, expected, value) => {
    const current = get.get(namespace, key);
    const revision = current?.revision ?? 0;
    if (revision !== expected) return { conflict: true };
    if (!Number.isSafeInteger(revision + 1)) throw new Error('REVISION_EXHAUSTED');
    put.run(namespace, key, revision + 1, value);
    return { revision: revision + 1, value };
  });
  return {
    read(namespace, key) { return get.get(namespace, key) ?? { revision: 0, value: 'null' }; },
    rows(namespace) { return rows.all(namespace); },
    cas(namespace, key, revision, value) { return transaction.immediate(namespace, key, revision, value); },
    close() { db.close(); },
  };
}

export function startHost({ path, token, namespace, port, maxConcurrentRequests = 64 }) {
  if (!/^[a-f0-9]{64}$/.test(token) || !/^[a-z0-9-]{1,32}$/.test(namespace) || !Number.isInteger(port) || (port !== 0 && port < 1024) || port > 65535) throw new Error('INVALID_OWNED_HOST_CONFIG');
  if (!Number.isSafeInteger(maxConcurrentRequests) || maxConcurrentRequests < 1 || maxConcurrentRequests > 1024) throw new Error('INVALID_LOCAL_REQUEST_CAP');
  const store = openStore(path);
  const epoch = crypto.randomUUID(), startedAtMs = Date.now(), outcomes = [];
  const configuredCaps = Object.freeze({ maxConcurrentRequests, maxRequestBodyBytes: 8_500_000, maxValueBytes: 4_194_304, maxOutcomes: 4096 });
  const counters = { requestCount: 0, admittedCount: 0, rejectedCount: 0, throttleCount: 0, backpressureCount: 0, failures: 0, conflicts: 0, casCount: 0, readCount: 0, inFlight: 0, peakInFlight: 0 };
  let overflow = false;
  const observation = () => ({ backend: 'local-sqlite-cas', namespace, epoch, startedAtMs, endedAtMs: Date.now(),
    budgetUnit: 'concurrent-authenticated-http-requests', coverageScope: 'authenticated-fetch-callbacks',
    configuredCaps: { ...configuredCaps }, ...counters, availableSlots: maxConcurrentRequests - counters.inFlight,
    handledThrottleCount: !overflow && counters.inFlight === 0 && outcomes.length === counters.requestCount ? 0 : null,
    overflow, coverageComplete: !overflow && counters.inFlight === 0 && outcomes.length === counters.requestCount,
    outcomes: outcomes.map(value => ({ ...value })) });
  const server = Bun.serve({ hostname: '127.0.0.1', port, maxRequestBodySize: 8_500_000,
    async fetch(request) {
      if (request.method !== 'POST' || request.headers.get('authorization') !== `Bearer ${token}`) return new Response(null, { status: 403 });
      const route = new URL(request.url).pathname;
      // Sampling is outside the workload budget. It neither consumes a slot nor
      // manufactures an application request in the measured trace.
      if (route === '/observation') {
        try {
          const body = await request.json();
          return body.namespace === namespace ? Response.json(observation()) : new Response(null, { status: 400 });
        } catch { return new Response(null, { status: 400 }); }
      }
      const operation = ++counters.requestCount, requestStartedAtMs = Date.now();
      let admitted = false, status = 503, outcome = 'store-failure';
      let key, inputRevision, acknowledgedRevision;
      const respond = (value, code, classification) => {
        status = code; outcome = classification;
        return Response.json(value, { status: code, headers: { 'x-forge-backend-epoch': epoch, 'x-forge-request-operation': String(operation), 'x-forge-outcome': classification } });
      };
      try {
        if (counters.inFlight >= maxConcurrentRequests) {
          counters.rejectedCount++; counters.throttleCount++; counters.backpressureCount++;
          return respond({ error: 'LOCAL_ADMISSION_LIMIT' }, 429, 'admission-throttle');
        }
        admitted = true; counters.admittedCount++; counters.inFlight++;
        counters.peakInFlight = Math.max(counters.peakInFlight, counters.inFlight);
        const body = await request.json();
        if (body.namespace !== namespace || typeof body.key !== 'string' || body.key.length < 1 || body.key.length > 128 || /[\x00-\x1f]/.test(body.key)) return respond(null, 400, 'invalid-request');
        key = body.key;
        if (route === '/read') {
          counters.readCount++;
          const result = store.read(namespace, body.key);
          acknowledgedRevision = result.revision;
          return respond(result, 200, 'read');
        }
        if (route !== '/cas' || !Number.isSafeInteger(body.revision) || body.revision < 0 || typeof body.value !== 'string' || Buffer.byteLength(body.value) > 4_194_304) return respond(null, 400, 'invalid-request');
        inputRevision = body.revision;
        JSON.parse(body.value);
        counters.casCount++;
        const result = store.cas(namespace, body.key, body.revision, body.value);
        if (result.conflict) counters.conflicts++;
        else acknowledgedRevision = result.revision;
        return respond(result, result.conflict ? 409 : 200, result.conflict ? 'cas-conflict' : 'committed');
      } catch (error) {
        const busy = error?.code === 'SQLITE_BUSY' || error?.code === 'SQLITE_LOCKED';
        if (busy) counters.backpressureCount++;
        return respond({ error: 'LOCAL_STORE_FAILURE' }, 503, busy ? 'sqlite-busy' : 'store-failure');
      } finally {
        if (admitted) counters.inFlight--;
        if (status >= 400 && status !== 409) counters.failures++;
        if (outcomes.length >= configuredCaps.maxOutcomes) overflow = true;
        else outcomes.push({ operation, startedAtMs: requestStartedAtMs, endedAtMs: Date.now(), route: route === '/read' || route === '/cas' ? route : 'invalid', admitted, status, outcome, key, inputRevision, acknowledgedRevision });
      }
    },
  });
  return { ready: { listening: true, hostname: '127.0.0.1', port: server.port, namespace, databasePath: path },
    observation,
    stop() { server.stop(true); store.close(); } };
}

if (import.meta.main) startHost({ path: process.env.FORGE_LOCAL_DB, token: process.env.FORGE_LOCAL_TOKEN, namespace: process.env.FORGE_LOCAL_NAMESPACE, port: Number(process.env.FORGE_LOCAL_PORT) });
