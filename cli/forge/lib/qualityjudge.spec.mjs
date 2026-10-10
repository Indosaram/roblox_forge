import { test } from 'node:test';
import assert from 'node:assert/strict';
import { invocation, extractJudgment, incompleteReceipt, audiovisual, referenceEvidence, runVisual } from './qualityjudge.mjs';
import { EventEmitter } from 'node:events';
import { runOwned } from './qualityav.mjs';

const request = {
  profile: { pack: 'fixture', tier: 'vertical-slice', reference: { exemplars: [{ path: 'reference.png' }] } },
  snapshot: { evidence: 'fixture' },
  inputs: { evidence: { captures: ['capture.png'], actions: ['actions.json'], scenarios: ['scenario.json'] } },
  artifactBytes: { 'reference.png': [1], 'capture.png': [2], 'actions.json': [123, 125], 'scenario.json': [123, 125] },
};
test('uses actual image attachments and stdin traces with tools disabled', () => {
  const plan = invocation(request, { OMO_BIN: 'omo.js', FORGE_QUALITY_EVALUATOR: 'fixture' });
  assert.ok(plan.args.includes('--no-tools'));
  assert.equal(plan.args.filter(arg => arg.startsWith('@')).length, 2);
  assert.equal(JSON.parse(plan.prompt.split('\n')[1]).traces['actions.json'], '{}');
  assert.throws(() => invocation(request, {}), /MISSING_OMO_BIN/);
  assert.throws(() => invocation(request, { OMO_BIN: 'omo.js', FORGE_QUALITY_EVALUATOR: 'fixture', FORGE_QUALITY_VISUAL_MODEL: 'paid-unknown' }), /UNAUTHORIZED_VISUAL_MODEL/);
});
test('preserves model results but cannot approve unheard audio', () => {
  const judgment = { criteria: { legibility: { score: 3 } }, blockers: [], fun: { verdict: 'approved', rationale: 'fixture', confidence: 'fixture' } };
  const parsed = extractJudgment(JSON.stringify({ type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: JSON.stringify(judgment) }] } }));
  const receipt = incompleteReceipt(request, 'fixture', parsed);
  assert.equal(receipt.verdict, 'inconclusive');
  assert.equal(receipt.schemaVersion, 2);
  assert.equal(receipt.captureSchemaVersion, 2);
  assert.equal(receipt.buildIdentity, undefined);
  assert.equal(receipt.review.fun.verdict, 'inconclusive');
  assert.equal(receipt.review.criteria.legibility.score, 3);
  assert.ok(receipt.review.blockers.includes('AUDIO_INPUT_UNSUPPORTED'));
  assert.throws(() => extractJudgment(''), /MISSING_MODEL_JUDGMENT/);
});

test('executable AV route reports absent artifacts and decoder without claiming listening', async () => {
  let invoked = false;
  const decode = async () => { invoked = true; throw new Error('unexpected decoder'); };
  const missing = await audiovisual(request, {}, decode);
  assert.deepEqual(missing.blockers, ['AV_EVIDENCE_REQUIRED']);
  const configured = structuredClone(request);
  configured.inputs.evidence.audiovisual = ['av.json'];
  const result = await audiovisual(configured, {}, decode);
  assert.equal(result.verdict, 'inconclusive');
  assert.deepEqual(result.blockers, ['AV_DECODER_CONFIGURATION_REQUIRED']);
  assert.equal(invoked, false);
});

test('reference bytes remain untrusted and do not turn an image route into approval', () => {
  assert.deepEqual(referenceEvidence(request).blockers, ['REFERENCE_EVIDENCE_REQUIRED']);
  const bound = structuredClone(request);
  bound.inputs.evidence.reference = ['reference.json'];
  bound.artifactBytes['reference.json'] = [...Buffer.from('{"claim":"approved"}')];
  const result = referenceEvidence(bound);
  assert.equal(result.verdict, 'inconclusive');
  assert.equal(result.evidence['reference.json'], '{"claim":"approved"}');
});

test('visual child has bounded cancellation and never exposes provider failure text', async () => {
  for (const mode of ['cancel', 'overflow', 'exit']) {
    const child = new EventEmitter();
    child.pid = 42; child.stdout = new EventEmitter(); child.stderr = new EventEmitter(); child.stdin = new EventEmitter();
    child.stdin.end = () => {};
    child.kill = () => { child.emit('close', null, 'SIGKILL'); return true; };
    const timers = new Set();
    const controller = new AbortController();
    const pending = runVisual({ args: ['private-argument'], prompt: 'private-prompt' }, { signal: controller.signal,
      runner: (executable, args, options) => runOwned(executable, args, { ...options, maxBytes: 32,
        spawnProcess: () => child, schedule: callback => { timers.add(callback); return callback; }, unschedule: callback => timers.delete(callback) }) });
    const rejected = assert.rejects(pending, error => {
      assert.ok(error.safeEvidence);
      assert.equal(JSON.stringify(error).includes('private'), false);
      assert.equal(error.message.includes('private'), false);
      return true;
    });
    child.stderr.emit('data', Buffer.from('private-provider-secret'));
    if (mode === 'cancel') controller.abort();
    if (mode === 'overflow') child.stdout.emit('data', Buffer.alloc(33));
    if (mode === 'exit') child.emit('close', 9, null);
    await rejected;
    assert.equal(timers.size, 0);
  }
});
