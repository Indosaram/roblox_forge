import { test, expect } from 'bun:test';
import { readFileSync } from 'node:fs';
import { objectReadiness, READINESS_BUDGET_MS } from './persistence-readiness.mjs';

// The module the emitted chunk embeds and the Lune fixture at
// cli/forge/fixtures/persistence-readiness/check.luau requires.
const runtimeSource = readFileSync(new URL('./persistence-readiness.luau', import.meta.url), 'utf8');

test('UNIT readiness requires an explicit target, a requirement and a bounded budget', () => {
  expect(() => objectReadiness()).toThrow('READINESS_TARGET_REQUIRED');
  expect(() => objectReadiness({ object: 'ForgePersistence' })).toThrow('READINESS_TARGET_REQUIRED');
  expect(() => objectReadiness({ service: 'ServerStorage' })).toThrow('READINESS_TARGET_REQUIRED');
  expect(() => objectReadiness({ service: 'ServerStorage', object: 'ForgePersistence' })).toThrow('READINESS_REQUIREMENT_REQUIRED');
  expect(() => objectReadiness({ service: 'ServerStorage', object: 'ForgePersistence', child: 'StartupLeaseReached' }))
    .toThrow('READINESS_CHILD_CLASS_REQUIRED');
  expect(() => objectReadiness({ service: 'ServerStorage', object: 'ForgePersistence', childClass: 'StringValue' }))
    .toThrow('READINESS_CHILD_CLASS_REQUIRED');
  expect(() => objectReadiness({ service: 'ServerStorage', object: 'ForgePersistence', attribute: 'ObservedLeaseExpiry', childCondition: 'nonempty' }))
    .toThrow('INVALID_READINESS_CHILD_CONDITION');
  expect(() => objectReadiness({ service: 'ServerStorage', object: 'ForgePersistence', child: 'StartupLeaseReached', childClass: 'StringValue', childCondition: 'whatever' }))
    .toThrow('INVALID_READINESS_CHILD_CONDITION');
  expect(() => objectReadiness({ service: 'ServerStorage', object: 'ForgePersistence', attribute: 'ObservedLeaseExpiry', budgetMs: 0 }))
    .toThrow('INVALID_READINESS_BUDGET');
  expect(() => objectReadiness({ service: 'ServerStorage', object: 'ForgePersistence', attribute: 'ObservedLeaseExpiry', budgetMs: Number.POSITIVE_INFINITY }))
    .toThrow('INVALID_READINESS_BUDGET');
  expect(() => objectReadiness({ service: 'Server Storage', object: 'ForgePersistence', attribute: 'ObservedLeaseExpiry' }))
    .toThrow('INVALID_READINESS_SERVICE');
  expect(() => objectReadiness({ service: 'ServerStorage', object: 'ForgePersistence', attribute: 'Observed LeaseExpiry' }))
    .toThrow('INVALID_READINESS_ATTRIBUTE');
});

test('UNIT the emitted chunk embeds the runtime verbatim and wires the real signals', () => {
  const code = objectReadiness({ service: 'ServerStorage', object: 'ForgePersistence', attribute: 'ObservedLeaseExpiry', budgetMs: 25000 });
  // The chunk that runs in Studio is the module the Lune fixture requires, embedded verbatim.
  expect(code).toContain(runtimeSource);
  expect(runtimeSource.startsWith('--!strict')).toBe(true);
  expect(runtimeSource).not.toContain('--!nocheck');
  expect(runtimeSource).not.toContain('selene: allow');
  // The real signals the runtime consumes arrive through the injected context.
  expect(code).toContain("ForgeQAReadiness.await({service=game:GetService('ServerStorage')");
  expect(code).toContain("signal=function() local e=Instance.new('BindableEvent')");
  expect(code).toContain('waitEvent=observe');
  expect(code).toContain('now=function() return DateTime.now().UnixTimestampMillis end');
  expect(code).toContain("{object='ForgePersistence',attribute='ObservedLeaseExpiry',budgetMs=25000}");
  // Subscribe-before-check, one absolute deadline, cleanup before every readiness assert: all inside
  // the runtime, in this order.
  expect(runtimeSource.indexOf('ctx.service.ChildAdded:Connect(track)'))
    .toBeLessThan(runtimeSource.indexOf('track(ctx.service:FindFirstChild(spec.object))'));
  expect(runtimeSource.indexOf('track(ctx.service:FindFirstChild(spec.object))'))
    .toBeLessThan(runtimeSource.indexOf('while not ready() do'));
  expect(runtimeSource.match(/ctx\.now\(\) \+ spec\.budgetMs/g)).toHaveLength(1);
  const cleanup = runtimeSource.indexOf('for _, connection in connections do');
  expect(cleanup).toBeGreaterThan(runtimeSource.indexOf('while not ready() do'));
  expect(runtimeSource.indexOf('aggregate.destroy()')).toBeGreaterThan(cleanup);
  expect(runtimeSource.indexOf('assert(target, "READINESS_OBJECT_TIMEOUT:"')).toBeGreaterThan(cleanup);
  // No callback property is read, and there is no poll or sleep.
  expect(runtimeSource).not.toContain('OnInvoke');
  expect(runtimeSource).not.toContain('task.wait');
  expect(runtimeSource).not.toContain('Heartbeat');
  expect(READINESS_BUDGET_MS).toBe(25000);
});

test('UNIT the emitted spec asks only for what that call needs', () => {
  // The runtime gates every signal on the spec, so the spec table is what distinguishes the calls.
  const marker = objectReadiness({ service: 'ServerStorage', object: 'ForgePersistence', child: 'StartupLeaseReached', childClass: 'StringValue', childCondition: 'nonempty' });
  expect(marker).toContain("{object='ForgePersistence',child='StartupLeaseReached',childClass='StringValue',childCondition='nonempty',budgetMs=25000}");
  // No condition for the handshake: the parented child is the contract, so no Value or callback
  // property is involved at all.
  const handshake = objectReadiness({ service: 'ServerScriptService', object: 'ForgeBuildIdentity', child: 'Handshake', childClass: 'BindableFunction' });
  // The exact spec literal above is the contract: no condition, so neither a Value nor a callback
  // property is involved in that wait.
  expect(handshake).toContain("{object='ForgeBuildIdentity',child='Handshake',childClass='BindableFunction',budgetMs=25000}");
  const attribute = objectReadiness({ service: 'ServerStorage', object: 'ForgePersistence', attribute: 'ObservedLeaseExpiry' });
  expect(attribute).toContain("{object='ForgePersistence',attribute='ObservedLeaseExpiry',budgetMs=25000}");
  expect(attribute).not.toContain("child='");
  // The runtime reads the child's Value property signal only when the spec asks for it, and never a
  // callback property; cli/forge/fixtures/persistence-readiness/check.luau proves both by running it.
  expect(runtimeSource).toContain('child:GetPropertyChangedSignal("Value"):Connect(wake)');
  expect(runtimeSource).toContain('if child and valueRequired then');
  expect(runtimeSource).not.toContain('OnInvoke');
});

test('UNIT the runtime tolerates only its own expiry at the deadline, and cleans up first', () => {
  // The tolerance is the helper's own expiry text AND the deadline; every other error keeps its exact
  // value. Cleanup precedes both the rethrow and the readiness asserts.
  expect(runtimeSource).toContain('if tostring(err) ~= "WORKLOAD_EVENT_TIMEOUT" or ctx.now() < deadline then');
  expect(runtimeSource).toContain('error(failure, 0)');
  const destroy = runtimeSource.indexOf('aggregate.destroy()');
  expect(destroy).toBeLessThan(runtimeSource.indexOf('error(failure, 0)'));
  expect(destroy).toBeLessThan(runtimeSource.indexOf('assert(target, "READINESS_OBJECT_TIMEOUT:"'));
  // Each requirement keeps its own readiness code.
  expect(runtimeSource).toContain('"READINESS_OBJECT_TIMEOUT:" .. spec.object');
  expect(runtimeSource).toContain('"READINESS_CHILD_TIMEOUT:" .. spec.object .. "." .. spec.child');
  expect(runtimeSource).toContain('"READINESS_ATTRIBUTE_TIMEOUT:" .. spec.object .. "." .. spec.attribute');
});
