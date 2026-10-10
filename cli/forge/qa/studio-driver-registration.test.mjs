import { test, expect } from 'bun:test';
import { measureRegistration, verifyRegistrationRound, ownedScope } from './studio-driver-registration.mjs';
const A='0123456789abcdef0123456789abcdef', B='fedcba9876543210fedcba9876543210';
const inventory=[{hwnd:'0x0000000000000001',pid:10,processIdentity:'pid:10:created:100'}, {hwnd:'0x0000000000000002',pid:11,processIdentity:'pid:11:created:101'}];
const logical={sessionId:'unit-session',buildIdentity:'unit-build',actorId:'-1',studioId:'unit-client'};
function batch(round, nonce) {
  return { round, armedQpc:String(round*100),barrierQpc:String(round*100+10),frequency:'10000000',
    observations:inventory.map((row,index)=>({...row,frameQpc:String(round*100+20+index),matches:index===0&&nonce?[{x:16,y:16,nonce}]:[]})) };
}
test('unit registration refuses missing ambiguous stale replayed and changed identities',()=>{
  const first=verifyRegistrationRound(inventory,batch(1,A),null,A);
  expect(verifyRegistrationRound(inventory,batch(2,B),first,B).selected.hwnd).toBe(inventory[0].hwnd);
  let value=batch(1,A);value.observations.pop();expect(()=>verifyRegistrationRound(inventory,value,null,A)).toThrow('REGISTRATION_CANDIDATES_MISSING');
  value=batch(1,A);value.observations[1].matches=[{x:16,y:16,nonce:A}];expect(()=>verifyRegistrationRound(inventory,value,null,A)).toThrow('REGISTRATION_AMBIGUOUS');
  value=batch(1,A);value.observations[0].frameQpc=value.barrierQpc;expect(()=>verifyRegistrationRound(inventory,value,null,A)).toThrow('REGISTRATION_STALE_FRAME');
  expect(()=>verifyRegistrationRound(inventory,batch(2,A),first,A)).toThrow('REGISTRATION_NONCE_REPLAY');
  value=batch(2,B);value.observations[0].processIdentity='pid:10:created:999';expect(()=>verifyRegistrationRound(inventory,value,first,B)).toThrow('REGISTRATION_IDENTITY_CHANGED');
  value=batch(1,A);value.observations[1]={...value.observations[0]};expect(()=>verifyRegistrationRound(inventory,value,null,A)).toThrow('REGISTRATION_IDENTITY_CHANGED');
});
function harness({renderFail=false, cleanupFail=false, armFail=false, closeFail=false}={}) {
  let armed=0,rendered=0,closed=false,persisted;
  const nonces=[A,B];
  const calls=[];
  return {
    calls,get persisted(){return persisted;},
    args:{ logical,makeNonce:()=>nonces.shift(),
      native:{ready:{inventory,jobName:'unit-job',desktopName:'unit-desktop'},
        async arm(round){calls.push('arm'+round);armed=round;if(round===3&&armFail)throw Error('arm failed');return {round,armedQpc:String(round*100)};},
        async snapshot(round){expect(rendered).toBe(round);calls.push('frame'+round);return batch(round,round===1?A:round===2?B:cleanupFail?B:null);},
        async close(){closed=true;calls.push('close');if(closeFail)throw Error('close failed');}},
      async execute(){expect(armed).toBeGreaterThan(0);rendered=armed;calls.push('render'+armed);if(armed===1&&renderFail)throw Error('render failed');return {logical,renderFrames:2,absent:armed===3};},
      async persist(proof){expect(closed).toBe(true);persisted=proof;return {reference:{path:'UNIT-ONLY.json',sha256:'0'.repeat(64)},artifacts:['UNIT-ONLY.json']};},
    },
  };
}
test('unit event order arms before render and closes after observed removal',async()=>{
  const h=harness();const result=await measureRegistration(h.args);
  expect(h.calls).toEqual(['arm1','render1','frame1','arm2','render2','frame2','arm3','render3','frame3','close']);
  expect(result.registrationObserved).toBe(true);expect(h.persisted.cleanup.nativeClosed).toBe(true);
});
for(const mode of ['renderFail','cleanupFail','armFail','closeFail'])test('unit '+mode+' retains failure and never admits source',async()=>{
  const h=harness({[mode]:true});await expect(measureRegistration(h.args)).rejects.toThrow();
  expect(h.calls).toContain('render3');expect(h.calls.at(-1)).toBe('close');expect(h.persisted.ok).toBe(false);
});

// The owned-scope facts in each launch form. FileTime ticks and the ISO stamp are two encodings of
// the same instant, which is what makes a reused pid detectable.
const created = Date.parse('2026-10-07T14:43:59.136Z');
const ticks = (BigInt(created) + 11644473600000n) * 10000n;
const identity = { pid: 15724, creationTime: new Date(created).toISOString(), captureIdentity: `pid:15724:created:${ticks}`,
  jobName: 'Local\\ForgeQA-512e2591ffa84b0dbbf7daac4b65ac9e', treeOwnership: 'windows-job-no-breakaway' };
const isolated = { ...identity, desktopName: 'ForgeQA-7f3a1c2d4e5b6a7c8d9e0f1a2b3c4d5e' };
const interactive = { ...identity, desktopMode: 'interactive', desktopName: 'Default' };

test('unit owned scope accepts both launch forms and refuses every missing fact',()=>{
  expect(ownedScope(isolated)).toBe(true);
  expect(ownedScope(interactive)).toBe(true);
  // The interactive form must declare its mode; a named desktop alone is not the isolated scope.
  expect(ownedScope({ ...identity, desktopName: 'Default' })).toBe(false);
  expect(ownedScope({ ...interactive, desktopName: '' })).toBe(false);
  expect(ownedScope({ ...interactive, desktopName: undefined })).toBe(false);
  expect(ownedScope(null)).toBe(false);
  expect(ownedScope('Local\\ForgeQA-abc')).toBe(false);
  expect(ownedScope({ ...interactive, jobName: 'ForgeQA-512e2591ffa84b0dbbf7daac4b65ac9e' })).toBe(false);
  expect(ownedScope({ ...interactive, jobName: '' })).toBe(false);
  expect(ownedScope({ ...interactive, treeOwnership: 'interactive-foreground' })).toBe(false);
  expect(ownedScope({ ...interactive, pid: 0 })).toBe(false);
  expect(ownedScope({ ...interactive, pid: 15724.5 })).toBe(false);
  expect(ownedScope({ ...interactive, pid: '15724' })).toBe(false);
});

test('unit owned scope refuses a reused pid whose creation stamp disagrees',()=>{
  // A recycled pid with a fresh process: the ISO stamp and the FileTime ticks no longer describe the
  // same instant, so the identity is not the one that was launched.
  expect(ownedScope({ ...interactive, creationTime: new Date(created + 60000).toISOString() })).toBe(false);
  expect(ownedScope({ ...interactive, captureIdentity: `pid:15724:created:${ticks + 600000000n}` })).toBe(false);
  // A pid swapped inside the identity is refused even when the stamp is well formed.
  expect(ownedScope({ ...interactive, captureIdentity: `pid:15725:created:${ticks}` })).toBe(false);
  expect(ownedScope({ ...interactive, captureIdentity: 'pid:15724' })).toBe(false);
  expect(ownedScope({ ...interactive, captureIdentity: undefined })).toBe(false);
  expect(ownedScope({ ...interactive, creationTime: 'not-a-time' })).toBe(false);
  expect(ownedScope({ ...interactive, creationTime: undefined })).toBe(false);
});
