import { createHash, randomBytes } from 'node:crypto';
import { mkdir, readFile, writeFile, readdir, access } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { StudioLifecycle } from '../forge/qa/studio-driver-lifecycle.mjs';
import { startHost, openStore } from './local-persistence-host.mjs';
import { Database } from 'bun:sqlite';

export const checkpoints = ['ESCROWED', 'CREDITED', 'FINALIZED', 'LEASE_ACQUIRED', 'LEASE_RENEWED'];
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
// An owned lifecycle is unresolved unless every resource proved release. Absent or
// unknown evidence refuses: a missing resources/residuals array, or a row whose
// cleanup is not 'released' (including 'pending' or absent), is unresolved. A
// recorded failure with every resource released is a run failure, not a lost
// resource, and must not halt or rename the matrix stage.
export const unresolvedResources = lifecycle => !lifecycle || typeof lifecycle !== 'object'
  || !Array.isArray(lifecycle.resources) || !Array.isArray(lifecycle.residuals)
  || lifecycle.resources.some(row => !row || row.cleanup !== 'released')
  || lifecycle.residuals.length > 0;

export async function currentCollectorIdentity() {
  const entries=[];
  const walk=async path=>{
    for(const entry of await readdir(path,{withFileTypes:true})) {
      const child=`${path}/${entry.name}`;
      if(entry.isDirectory()) await walk(child);
      else if(/\.(mjs|luau)$/.test(entry.name)) entries.push(`${child}:${sha256(await readFile(child))}`);
    }
  };
  await walk('cli/release');await walk('cli/forge/qa');
  return sha256(entries.sort().join('\n'));
}

// Lease expiry is the tested event, not polling/backoff. Cancellation removes
// the exact deadline before any subsequent allocation can occur.
export async function awaitLeaseExpiry(expiresAt, signal) {
  if (!Number.isSafeInteger(expiresAt)) throw new Error('DURABLE_LEASE_REQUIRED');
  const remaining=expiresAt*1000-Date.now()+1000;
  if (remaining>125000) throw new Error('LEASE_EXPIRY_OUTSIDE_BOUND');
  if (signal?.aborted) throw new Error('CANCELLED');
  if (remaining<=0) return;
  let timer,abort;
  try {
    await new Promise((resolve,reject)=>{
      abort=()=>reject(new Error('CANCELLED'));
      signal?.addEventListener('abort',abort,{once:true});
      if(signal?.aborted) {abort();return;}
      timer=setTimeout(resolve,remaining);
    });
  } finally {clearTimeout(timer);signal?.removeEventListener('abort',abort);}
}

// The injected runner is a UNIT seam only. Production binds it lexically to
// attempt; neither evidence nor driver configuration can choose executable code.
export async function collectMatrix(request, run) {
  const directory = resolve(request.artifactDirectory);
  await mkdir(directory); // Exclusive owned output; never reuse a user's DB.
  const matrix = { schema: 'capacity-matrix/v1', buildIdentity: request.buildIdentity,
    collectorIdentity: request.collectorIdentity, pack: request.pack, players: request.players,
    startedAtMs: Date.now(), stages: [], artifacts: [] };
  const retain = async (name, value) => {
    const bytes = Buffer.from(JSON.stringify(value));
    await writeFile(join(directory, name), bytes, { flag: 'wx' });
    return { path: name, sha256: sha256(bytes), bytes: bytes.length };
  };
  for (const phase of ['MEASUREMENT', ...checkpoints]) {
    if (request.signal?.aborted) { matrix.cancelled=true; break; }
    const lifecycle = new StudioLifecycle();
    let host;
    const namespace = `cap-${randomBytes(10).toString('hex')}`;
    const path = join(directory, `${phase}.sqlite`);
    const stage = { phase, namespace, startedAtMs: Date.now(), runs: [] };
    matrix.stages.push(stage);
    try {
      const resource = lifecycle.attempt('persistent-host', phase, async () => {
        host?.stop();
        return { released: true, evidence: { stopped: true, databaseRetained: true, namespace } };
      });
      const local = { path, namespace, port: 0, token: randomBytes(32).toString('hex') };
      host = startHost(local);
      if (!host.ready?.listening || host.ready.namespace !== namespace) throw new Error('HOST_NOT_READY');
      lifecycle.acquire(resource, { namespace, port: host.ready.port });
      const driver = { ...request.driver, localPersistence: local,
        persistence: { namespace, port: host.ready.port, token: local.token } };
      delete driver.leaseRenewalKey;
      const invoke = async extra => {
        const job = new StudioLifecycle();
        let result;
        const cancel = () => { job.fail('cancel','CANCELLED'); void job.close(); };
        request.signal?.addEventListener('abort',cancel,{once:true});
        try { result = await run({ ...request, driver, host, recovery: undefined, ...extra }, job); }
        catch (error) { result = { blockers: ['COLLECTION_FAILED'], error: String(error.message) }; }
        finally { const cleanup = await job.close(); request.signal?.removeEventListener('abort',cancel); result ??= {}; result.lifecycle = cleanup; }
        stage.runs.push(result);
        // Only a lost owned resource forbids the next Job. A blanket
        // JOB_CLEANUP_FAILED replaced the real attemptError (observed: the
        // ESCROWED MCP deadline was reported as JOB_CLEANUP_FAILED).
        if (unresolvedResources(result.lifecycle)) throw new Error('JOB_CLEANUP_FAILED');
        return result;
      };
      if (phase === 'LEASE_ACQUIRED') {
        const warmup = await invoke({ checkpoint: 'LEASE_KEY_DISCOVERY' });
        if (!warmup.leaseKey) throw new Error('OBSERVED_LEASE_KEY_REQUIRED');
        driver.persistence.leaseAcquireKey = warmup.leaseKey;
        const store=openStore(path);
        try { driver.persistence.waitLeaseExpiry=JSON.parse(store.read(namespace,warmup.leaseKey).value).lease.expiresAt; }
        finally {store.close();}
        await awaitLeaseExpiry(driver.persistence.waitLeaseExpiry,request.signal);
        await invoke({ checkpoint: phase });
      } else await invoke({ checkpoint: phase, recovery: checkpoints.slice(0, 3).includes(phase) ? phase : undefined });
      stage.observation = typeof host.observation === 'function' ? host.observation() : null;
      // Enumerate the actual namespace, not only keys selected by telemetry.
      const store = openStore(path);
      try {
        stage.finalReadback = typeof store.rows === 'function' ? store.rows(namespace) : null;
      } finally { store.close(); }
    } catch (error) { stage.error = String(error.message); }
    finally {
      stage.cleanup = await lifecycle.close();
      stage.endedAtMs = Date.now();
      try {
        // Close all hosts/connections, then force WAL into the retained main DB.
        // A busy checkpoint is missing durability evidence, never a valid hash.
        // bun:sqlite cannot open an existing database read-write without CREATE
        // (bad parameter or other API misuse), so existence is proven by access()
        // and the open itself keeps create semantics.
        await access(path);
        const database=new Database(path);
        try {
          const checkpoint=database.query('PRAGMA wal_checkpoint(TRUNCATE)').get();
          if(!checkpoint || checkpoint.busy!==0) throw new Error('DATABASE_CHECKPOINT_BUSY');
        } finally {database.close();}
        const bytes = await readFile(path);
        stage.database = { path: `${phase}.sqlite`, bytes: bytes.length, sha256: sha256(bytes) };
      } catch { stage.error ??= 'RETAINED_DATABASE_MISSING'; }
      stage.receipt = await retain(`${phase}.json`, stage);
      matrix.artifacts.push(stage.receipt);
    }
    // A lost owned resource forbids allocating another Job or host.
    if (unresolvedResources(stage.cleanup) || stage.runs.some(value => unresolvedResources(value.lifecycle))) break;
  }
  matrix.endedAtMs = Date.now();
  matrix.directory = directory;
  return matrix;
}
