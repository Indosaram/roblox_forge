import { test, expect } from 'bun:test';
import { runWorkload, executeSteps, actorSteps, buildSteps, gatherWaves } from './capacity-workload.mjs';

test('eight distinct actual actor identities are mandatory before workload', async () => {
  let invoked = false;
  await expect(runWorkload({ clients: Array.from({ length: 8 }, () => ({ userId: 'same' })) }, {
    execute: async () => { invoked = true; },
  })).rejects.toThrow('EIGHT_ACTUAL_ACTORS_REQUIRED');
  expect(invoked).toBe(false);
});

test('server shortcuts are not executable workload steps', async () => {
  await expect(executeSteps([{ op: 'server_command' }], { userId: 'actual', studioId: 'client' },
    { serverId: 'server' }, { clock: async () => 1 })).rejects.toThrow('WORKLOAD_STEP_FAILED');
});

test('missing real result cannot synthesize a craft or build binding', async () => {
  await expect(executeSteps([{ op: 'bind_result', field: 'data.jobId', label: 'job' }],
    {}, {}, {})).rejects.toThrow('WORKLOAD_STEP_FAILED');
});

test('workload includes actual gather craft transfer and construction actions', () => {
  const steps = [...actorSteps(), ...buildSteps()];
  expect(steps.some(step => step.op === 'activate_prompt')).toBe(true);
  for (const action of ['craft-complete', 'transfer-deposit', 'settlement-place']) {
    expect(steps.some(step => step.resultAction === `survival-coop:${action}`)).toBe(true);
  }
  expect(steps.some(step => ['command', 'server_command', 'restore', 'advance_elapsed'].includes(step.op))).toBe(false);
});

test('actors sharing a gather node never gather concurrently', () => {
  const gather = nodeId => [{ op: 'walk_to', target: `Workspace.Node.${nodeId}` }, { op: 'activate_prompt', nodeId }];
  const waves = gatherWaves([gather('fiber-bush-01'), gather('fiber-bush-01'), gather('fallen-tree-01'), gather('fallen-tree-01')]);
  const concurrent = waves.map(wave => wave.indices);
  const together = (a, b) => concurrent.some(indices => indices.includes(a) && indices.includes(b));
  expect(waves.length).toBe(2);
  expect(together(0, 1)).toBe(false);
  expect(together(2, 3)).toBe(false);
  expect(together(0, 2)).toBe(true);
  expect(together(1, 3)).toBe(true);
});
