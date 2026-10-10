import { test, expect } from 'bun:test';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { launchOwnedEditor } from './studio-driver-process.mjs';
import { StudioLifecycle } from './studio-driver-lifecycle.mjs';

test('editor identity is acquired from supervisor and cleanup awaits release and closure', async () => {
  const lifecycle = new StudioLifecycle();
  const identity = { pid: 12, creationTime: 'owned-creation', commandLine: 'Studio owned.rbxl', artifact: 'owned.rbxl', baseline: [99] };
  let child;
  const spawn = () => {
    expect(lifecycle.receipt().resources[0].state).toBe('attempted');
    child = new EventEmitter();
    child.pid = 10;
    child.stdin = new PassThrough();
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    child.stdin.once('data', () => child.stdout.write(JSON.stringify({ event: 'acquired', identity }) + '\n'));
    child.stdin.once('finish', () => {
      child.stdout.write(JSON.stringify({ event: 'released', pid: 12, treeExited: true, eventProof: 'JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO' }) + '\n');
      child.emit('close', 0, null);
    });
    return child;
  };
  const launched = await launchOwnedEditor({ executable: 'Studio.exe', artifact: 'owned.rbxl' }, lifecycle, spawn);
  expect(launched.controller.identity).toEqual(identity);
  const cleanup = await lifecycle.close();
  expect(cleanup.residuals).toEqual([]);
  expect(cleanup.resources[0].evidence.pid).toBe(12);
});

test('supervisor close without release rejects cleanup rather than retaining an unresolved promise', async () => {
  const lifecycle = new StudioLifecycle();
  const spawn = () => {
    const child = new EventEmitter();
    child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
    child.stdin.once('data', () => child.stdout.write(JSON.stringify({ event: 'acquired', identity: { pid: 12 } }) + '\n'));
    child.stdin.once('finish', () => child.emit('close', 1, null));
    return child;
  };
  await launchOwnedEditor({ executable: 'Studio.exe', artifact: 'owned.rbxl' }, lifecycle, spawn);
  const cleanup = await lifecycle.close();
  expect(cleanup.ok).toBe(false);
  expect(cleanup.residuals).toEqual(['owned-editor']);
});
