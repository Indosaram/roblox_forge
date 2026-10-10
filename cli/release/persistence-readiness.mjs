import { readFileSync } from 'node:fs';
import { observedWait } from './capacity-workload.mjs';

// Bounded readiness for the objects the owned server bootstrap publishes asynchronously. The
// RuntimeBackend parents ServerStorage.ForgePersistence with its StartupLeaseReached marker from its
// own startup path (the marker is parented with an empty Value at RuntimeBackend.luau:112 and its
// Value is assigned when the barrier is reached at :114, while ObservedLeaseExpiry is set at :304
// after the lease wait), and the embedded ForgeBuildIdentity script assigns
// ServerScriptService.ForgeBuildIdentity.Handshake before it parents that child
// (cli/forge/lib/buildidentity.luau:146 then :149). The owned editor registers with the bridge as
// soon as its datamodel is reachable, which can be before any of that has happened, so a read issued
// at registration races the bootstrap (observed: COLLECTION_FAILED, 'ForgePersistence is not a valid
// member of ServerStorage').
//
// The emitted chunk prepends the maintained observe helper and embeds the readiness runtime verbatim
// (cli/release/persistence-readiness.luau), which the Lune fixture at
// cli/forge/fixtures/persistence-readiness/check.luau requires, so the code that runs in Studio is
// the code the fixture drives. The runtime subscribes to the exact creation/child/attribute/value
// signals before its first check and waits under one absolute deadline that no bounded wait can
// extend; the helper's own expiry is tolerated only when it coincides with that deadline, and any
// other error is re-raised with its exact value. The only child condition is 'nonempty': the
// marker's Value is assigned after the child is parented, so its Value change has to wake the wait,
// while the handshake needs no condition because OnInvoke is assigned before it is parented and its
// callback property is never read.
export const READINESS_BUDGET_MS = 25000;

// The runtime is read once and embedded verbatim; it carries no suppression and no Roblox global.
const runtime = readFileSync(new URL('./persistence-readiness.luau', import.meta.url), 'utf8');

const identifier = (label, value) => {
  if (value === undefined) return '';
  if (typeof value !== 'string' || !/^[A-Za-z0-9_]+$/.test(value)) throw new Error(`INVALID_READINESS_${label}`);
  return value;
};

export function objectReadiness({ service, object, child, childClass, childCondition, attribute, budgetMs = READINESS_BUDGET_MS } = {}) {
  const serviceName = identifier('SERVICE', service);
  const objectName = identifier('OBJECT', object);
  const childName = identifier('CHILD', child);
  const childClassName = identifier('CHILD_CLASS', childClass);
  const attributeName = identifier('ATTRIBUTE', attribute);
  if (!serviceName || !objectName) throw new Error('READINESS_TARGET_REQUIRED');
  if ((childName === '') !== (childClassName === '')) throw new Error('READINESS_CHILD_CLASS_REQUIRED');
  if (childCondition !== undefined && (childName === '' || childCondition !== 'nonempty')) {
    throw new Error('INVALID_READINESS_CHILD_CONDITION');
  }
  if (childName === '' && attributeName === '') throw new Error('READINESS_REQUIREMENT_REQUIRED');
  if (!Number.isSafeInteger(budgetMs) || budgetMs <= 0) throw new Error('INVALID_READINESS_BUDGET');
  const spec = [`object='${objectName}'`];
  if (childName) spec.push(`child='${childName}'`, `childClass='${childClassName}'`);
  if (childCondition) spec.push(`childCondition='${childCondition}'`);
  if (attributeName) spec.push(`attribute='${attributeName}'`);
  spec.push(`budgetMs=${budgetMs}`);
  return `${observedWait}
local ForgeQAReadiness=(function()
${runtime}
end)()
ForgeQAReadiness.await({service=game:GetService('${serviceName}'),signal=function() local e=Instance.new('BindableEvent') return {event=e.Event,fire=function() e:Fire() end,destroy=function() e:Destroy() end} end,waitEvent=observe,now=function() return DateTime.now().UnixTimestampMillis end},{${spec.join(',')}})`;
}
