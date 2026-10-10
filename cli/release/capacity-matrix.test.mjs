import { test, expect } from 'bun:test';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { collectMatrix, checkpoints, sha256, awaitLeaseExpiry, unresolvedResources } from './capacity-matrix.mjs';

test('exact lease deadline subscribes cancellation without waiting for elapsed time',async()=>{
  const controller=new AbortController();
  const waiting=awaitLeaseExpiry(Math.floor(Date.now()/1000)+120,controller.signal);
  controller.abort();
  await expect(waiting).rejects.toThrow('CANCELLED');
});

test('UNIT coordinator keeps each checkpoint backend through sequential jobs and retains originals',async()=>{
  const root=await mkdtemp(join(tmpdir(),'capacity-matrix-unit-'));
  const calls=[];let active=0;
  try {
    const matrix=await collectMatrix({artifactDirectory:join(root,'owned'),players:8,pack:'unit',buildIdentity:{id:'unit'},driver:{}},
      async(request,lifecycle)=>{
        expect(active++).toBe(0);
        const resource=lifecycle.attempt('unit','unit-job',async()=>{active--;return{released:true,evidence:{unit:true}};});
        lifecycle.acquire(resource,{unit:true});
        calls.push({phase:request.checkpoint,namespace:request.driver.persistence.namespace});
        // No successful acquisition warmup is fabricated: the missing real key
        // must stop only that checkpoint, while other isolated probes continue.
        return {currentBuild:request.buildIdentity,blockers:['UNIT_NO_LIVE_PROOF']};
      });
    expect(calls.map(row=>row.phase)).toEqual(['MEASUREMENT','ESCROWED','CREDITED','FINALIZED','LEASE_KEY_DISCOVERY','LEASE_RENEWED']);
    expect(new Set(calls.map(row=>row.namespace)).size).toBe(6);
    expect(matrix.stages.map(row=>row.phase)).toEqual(['MEASUREMENT',...checkpoints]);
    expect(matrix.stages.find(row=>row.phase==='LEASE_ACQUIRED').error).toBe('OBSERVED_LEASE_KEY_REQUIRED');
    for(const stage of matrix.stages) {
      expect(stage.cleanup.ok).toBe(true);
      expect(sha256(await readFile(join(matrix.directory,stage.receipt.path)))).toBe(stage.receipt.sha256);
      expect(sha256(await readFile(join(matrix.directory,stage.database.path)))).toBe(stage.database.sha256);
    }
  } finally {await rm(root,{recursive:true,force:true});}
});
test('UNIT unresolved owned resource halts subsequent allocations',async()=>{
  const root=await mkdtemp(join(tmpdir(),'capacity-matrix-unit-'));let calls=0;
  try {
    const matrix=await collectMatrix({artifactDirectory:join(root,'owned'),players:8,pack:'unit',buildIdentity:{id:'unit'},driver:{}},async(_,lifecycle)=>{
      calls++;lifecycle.attempt('unit','unresolved',async()=>({released:false}));return{};
    });
    expect(calls).toBe(1);expect(matrix.stages).toHaveLength(1);
    expect(matrix.stages[0].runs[0].lifecycle.residuals).toEqual(['unresolved']);
  } finally {await rm(root,{recursive:true,force:true});}
});

test('UNIT a recorded run failure with proven release continues to the next checkpoint',async()=>{
  const root=await mkdtemp(join(tmpdir(),'capacity-matrix-unit-'));
  const calls=[];
  try {
    const matrix=await collectMatrix({artifactDirectory:join(root,'owned'),players:8,pack:'unit',buildIdentity:{id:'unit'},driver:{}},
      async(request,lifecycle)=>{
        const resource=lifecycle.attempt('unit','unit-job',async()=>({released:true,evidence:{unit:true}}));
        lifecycle.acquire(resource,{unit:true});
        calls.push(request.checkpoint);
        lifecycle.fail('capacity-window','CAPACITY_WINDOW_FAILED');
        return {currentBuild:request.buildIdentity,blockers:['UNIT_NO_LIVE_PROOF'],attemptError:'UNIT_ATTEMPT_FAILED'};
      });
    expect(calls).toEqual(['MEASUREMENT','ESCROWED','CREDITED','FINALIZED','LEASE_KEY_DISCOVERY','LEASE_RENEWED']);
    expect(matrix.stages).toHaveLength(6);
    // The terminal run failure stays visible and the stage is not renamed.
    expect(matrix.stages[0].error).toBeUndefined();
    expect(matrix.stages[0].runs[0].attemptError).toBe('UNIT_ATTEMPT_FAILED');
    expect(matrix.stages[4].error).toBe('OBSERVED_LEASE_KEY_REQUIRED');
  } finally {await rm(root,{recursive:true,force:true});}
});

test('UNIT a genuine cleanup failure still halts and absent release evidence refuses',async()=>{
  const root=await mkdtemp(join(tmpdir(),'capacity-matrix-unit-'));let calls=0;
  try {
    const matrix=await collectMatrix({artifactDirectory:join(root,'owned'),players:8,pack:'unit',buildIdentity:{id:'unit'},driver:{}},
      async(_,lifecycle)=>{
        calls++;
        lifecycle.attempt('unit','half',async()=>({released:false}));
        return {};
      });
    expect(calls).toBe(1);
    expect(matrix.stages).toHaveLength(1);
    expect(matrix.stages[0].runs[0].lifecycle.residuals).toEqual(['half']);
  } finally {await rm(root,{recursive:true,force:true});}
  expect(unresolvedResources(null)).toBe(true);
  expect(unresolvedResources({})).toBe(true);
  expect(unresolvedResources({resources:[{id:'x'}],residuals:[]})).toBe(true);
  expect(unresolvedResources({resources:[{id:'x',cleanup:'pending'}],residuals:[]})).toBe(true);
  expect(unresolvedResources({resources:[{id:'x',cleanup:'unresolved'}],residuals:[]})).toBe(true);
  expect(unresolvedResources({resources:[{id:'x',cleanup:'released'}],residuals:['x']})).toBe(true);
  expect(unresolvedResources({resources:[{id:'x',cleanup:'released'}],residuals:[]})).toBe(false);
  expect(unresolvedResources({resources:[],residuals:[]})).toBe(false);
});
