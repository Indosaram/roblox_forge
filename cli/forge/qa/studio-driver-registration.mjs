import { randomBytes, createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdir, stat, readFile, writeFile } from 'node:fs/promises';
import { resolve, relative, isAbsolute } from 'node:path';

const demand = (value, code) => { if (!value) throw new Error(code); };
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
export function registrationDigest(value) {
  const canonical = value => {
    if (value === null || typeof value !== 'object') return JSON.stringify(value);
    const pairs = Array.isArray(value) ? value.map((v, i) => [i + 1, v]) : Object.entries(value);
    pairs.sort(([a], [b]) => { const x = typeof a + String(a), y = typeof b + String(b); return x < y ? -1 : x > y ? 1 : 0; });
    return '{' + pairs.map(([k, v]) => canonical(k) + ':' + canonical(v)).join(',') + '}';
  };
  return 'sha256:' + hash(canonical(value));
}
const tick = value => { demand(typeof value === 'string' && /^[1-9][0-9]*$/.test(value), 'REGISTRATION_QPC'); return BigInt(value); };
const key = row => row.hwnd + '/' + row.processIdentity;
export function verifyRegistrationRound(inventory, observation, previous, nonce) {
  demand(Array.isArray(inventory) && inventory.length > 0 && inventory.length <= 32, 'REGISTRATION_INVENTORY');
  const candidates = new Map();
  for (const row of inventory) {
    demand(/^0x[0-9a-f]{16}$/.test(row.hwnd) && Number.isSafeInteger(row.pid) && row.pid > 0 &&
      new RegExp('^pid:' + row.pid + ':created:[1-9][0-9]*$').test(row.processIdentity) && !candidates.has(row.hwnd), 'REGISTRATION_INVENTORY');
    candidates.set(row.hwnd, row);
  }
  demand(tick(observation.armedQpc) < tick(observation.barrierQpc) && tick(observation.frequency) > 0n, 'REGISTRATION_CAUSAL_ORDER');
  if (previous) demand(tick(observation.armedQpc) > tick(previous.lastQpc) && observation.frequency === previous.frequency, 'REGISTRATION_STALE_ROUND');
  demand(Array.isArray(observation.observations) && observation.observations.length === inventory.length, 'REGISTRATION_CANDIDATES_MISSING');
  const seen = new Set(), matches = [];
  let lastQpc = observation.barrierQpc;
  for (const row of observation.observations) {
    demand(candidates.has(row.hwnd) && !seen.has(row.hwnd) && key(row) === key(candidates.get(row.hwnd)) && row.pid === candidates.get(row.hwnd).pid, 'REGISTRATION_IDENTITY_CHANGED');
    seen.add(row.hwnd);
    demand(tick(row.frameQpc) > tick(observation.barrierQpc), 'REGISTRATION_STALE_FRAME');
    if (tick(row.frameQpc) > tick(lastQpc)) lastQpc = row.frameQpc;
    demand(Array.isArray(row.matches), 'REGISTRATION_MATCHES_REQUIRED');
    for (const match of row.matches) {
      demand(Number.isInteger(match.x) && Number.isInteger(match.y) && match.x >= 0 && match.y >= 0 && /^[a-f0-9]{32}$/.test(match.nonce), 'REGISTRATION_MATCH_INVALID');
      matches.push({ ...match, ...candidates.get(row.hwnd) });
    }
  }
  if (nonce === null) demand(matches.length === 0, 'REGISTRATION_REMOVAL_UNPROVEN');
  else {
    demand(/^[a-f0-9]{32}$/.test(nonce) && (!previous || nonce !== previous.nonce), 'REGISTRATION_NONCE_REPLAY');
    demand(matches.length === 1 && matches[0].nonce === nonce, matches.length > 1 ? 'REGISTRATION_AMBIGUOUS' : 'REGISTRATION_NONCE_MISSING');
    if (previous?.selected) demand(key(matches[0]) === key(previous.selected), 'REGISTRATION_IDENTITY_CHANGED');
  }
  return { lastQpc, frequency: observation.frequency, nonce, selected: matches[0] || previous?.selected };
}

export function challengeCode({ marker, owner, nonce, phase, logical }) {
  const quote = JSON.stringify;
  return `local p=game:GetService('Players').LocalPlayer
assert(p and tostring(p.UserId)==${quote(logical.actorId)},'REGISTRATION_ACTOR_CHANGED')
local scripts=p:FindFirstChild('PlayerScripts');local identity=scripts and scripts:FindFirstChild('ForgeBuildIdentity')
local fn=identity and identity:FindFirstChild('Handshake');assert(fn and fn:IsA('BindableFunction'),'REGISTRATION_HANDSHAKE_MISSING')
local h=fn:Invoke()
local identityMatches=h.schemaVersion==1 and h.role=='client' and h.sessionId==${quote(logical.sessionId)} and h.buildIdentity==${quote(logical.buildIdentity)} and h.serverBuildIdentity==${quote(logical.buildIdentity)} and h.actorId==${quote(logical.actorId)}
${phase === 3 ? '' : "assert(identityMatches,'REGISTRATION_IDENTITY_CHANGED')"}
local gui=p:FindFirstChild('PlayerGui');assert(gui,'REGISTRATION_PLAYER_GUI')
local existing=gui:FindFirstChild(${quote(marker)})
${phase === 1 ? `assert(not existing,'REGISTRATION_GUI_COLLISION')` : `if existing then assert(existing:GetAttribute('RegistrationOwner')==${quote(owner)},'REGISTRATION_FOREIGN_GUI') end`}
local done=Instance.new('BindableEvent');local count=0;local expired=false
local connection=game:GetService('RunService').RenderStepped:Connect(function()count+=1;if count>=2 then done:Fire() end end)
local timer=task.delay(5,function()expired=true;done:Fire()end)
local ok,reason=pcall(function()
${nonce === null ? 'if existing then existing:Destroy() end' : `-- The safe-area origin keeps the marker clear of the client's own topbar: with
-- IgnoreGuiInset=true a panel at (16,16) was measured under the topbar, which
-- covered the ring's top rows and left an undecodable partial marker.
local screen=existing
if not screen then screen=Instance.new('ScreenGui');screen.Name=${quote(marker)};screen.IgnoreGuiInset=false;screen.ResetOnSpawn=false;screen.DisplayOrder=2147483000;screen:SetAttribute('RegistrationOwner',${quote(owner)}) end
if existing then existing:ClearAllChildren() end
local panel=Instance.new('Frame');panel.Name='Nonce';panel.Size=UDim2.fromOffset(144,80);panel.Position=UDim2.fromOffset(16,16);panel.BackgroundColor3=Color3.fromRGB(255,0,255);panel.BorderSizePixel=0;panel.Parent=screen
local nonce=${quote(nonce)}
for i=1,32 do local digit=tonumber(string.sub(nonce,i,i),16)
 for shift=3,0,-1 do local bit=(i-1)*4+3-shift;local cell=Instance.new('Frame');cell.Size=UDim2.fromOffset(8,8);cell.Position=UDim2.fromOffset((bit%16+1)*8,(math.floor(bit/16)+1)*8);cell.BorderSizePixel=0;cell.BackgroundColor3=if bit32.band(bit32.rshift(digit,shift),1)==1 then Color3.new(1,1,1) else Color3.new(0,0,0);cell.Parent=panel end
end
screen.Parent=gui`}
if count<2 and not expired then done.Event:Wait() end
assert(not expired and count>=2,'REGISTRATION_RENDER_TIMEOUT')
end)
connection:Disconnect();if coroutine.status(timer)=='suspended' then task.cancel(timer) end;done:Destroy();assert(ok,reason);assert(identityMatches,'REGISTRATION_IDENTITY_CHANGED')
return game:GetService('HttpService'):JSONEncode({logical={sessionId=h.sessionId,buildIdentity=h.buildIdentity,actorId=h.actorId,studioId=${quote(logical.studioId)}},renderFrames=count,absent=gui:FindFirstChild(${quote(marker)})==nil})`;
}

export async function measureRegistration({ native, logical, execute, persist, makeNonce = () => randomBytes(16).toString('hex') }) {
  const nonces = [makeNonce(), makeNonce()];
  demand(nonces.every(value => /^[a-f0-9]{32}$/.test(value)) && nonces[0] !== nonces[1], 'REGISTRATION_NONCE_REPLAY');
  const owner = randomBytes(16).toString('hex'), marker = 'ForgeRegistration_' + owner;
  const proof = { schemaVersion: 1, protocol: 'forge-rendered-nonce-v1', ...logical,
    jobName: native.ready.jobName, desktopName: native.ready.desktopName, inventory: native.ready.inventory, rounds: [] };
  let prior, failure, cleanupFailure;
  const render = async (phase, nonce) => {
    const ack = await execute(challengeCode({ marker, owner, phase, nonce, logical }), phase);
    demand(ack && Number.isInteger(ack.renderFrames) && ack.renderFrames >= 2 && Object.keys(logical).every(k => ack.logical?.[k] === logical[k]), 'REGISTRATION_RENDER_ACK');
    return ack;
  };
  try {
    for (let round = 1; round <= 2; round++) {
      const armed = await native.arm(round, nonces[round - 1]);
      const ack = await render(round, nonces[round - 1]);
      const frames = await native.snapshot(round);
      const batch = { ...frames, armedQpc: armed.armedQpc, nonce: nonces[round - 1], logical: ack.logical, renderFrames: 2 };
      demand(batch.round === round, 'REGISTRATION_ROUND_REPLAY');
      proof.rounds.push(batch);
      prior = verifyRegistrationRound(proof.inventory, batch, prior, batch.nonce);
    }
  } catch (error) { failure = error; }
  finally {
    let armed;
    try { armed = await native.arm(3, 'remove'); } catch (error) { cleanupFailure = error; }
    // Even a dead observer must not prevent removal of our own client GUI.
    try {
      const ack = await render(3, null);
      demand(ack.absent === true, 'REGISTRATION_GUI_NOT_ABSENT');
      if (armed) {
        const frames = await native.snapshot(3);
        const cleanup = { ...frames, armedQpc: armed.armedQpc, logical: ack.logical, renderFrames: ack.renderFrames, absent: true };
        demand(cleanup.round === 3, 'REGISTRATION_ROUND_REPLAY');
        proof.cleanup = cleanup;
        prior = verifyRegistrationRound(proof.inventory, cleanup, prior, null);
      }
    } catch (error) { cleanupFailure ??= error; }
    try { await native.close(); if (proof.cleanup) proof.cleanup.nativeClosed = true; }
    catch (error) { cleanupFailure ??= error; }
  }
  if (failure || cleanupFailure) {
    const retained = await persist({ ...proof, ok: false, failure: failure?.message || null, cleanupFailure: cleanupFailure?.message || null });
    const error = new Error(cleanupFailure ? 'REGISTRATION_CLEANUP_UNPROVEN' : failure.message);
    error.registrationFailure = retained;
    throw error;
  }
  demand(prior?.selected && proof.cleanup?.nativeClosed, 'REGISTRATION_INCOMPLETE');
  Object.assign(proof, { pid: prior.selected.pid, processIdentity: prior.selected.processIdentity, hwnd: prior.selected.hwnd });
  const receipt = await persist(proof);
  return { registrationObserved: true, role: 'game-client', ...logical,
    pid: proof.pid, processIdentity: proof.processIdentity, hwnd: proof.hwnd,
    registrationEvidence: receipt.reference, registrationDigest: registrationDigest(proof),
    registrationArtifacts: receipt.artifacts, registrationCompletedQpc: prior.lastQpc,
    registrationFrequency: prior.frequency };
}

async function openNative(executable, directory, scope, lifecycle, root) {
  let child, lines, awaiting, exitPromise, finished = false, closedEvent = false;
  const reject = error => awaiting?.reject(error);
  const resource = lifecycle.attempt('registration', directory, async (_, signal) => {
    if (!child) return { released: true, evidence: { notStarted: true } };
    const abort = () => { child.kill(); reject(new Error('REGISTRATION_CLEANUP_TIMEOUT')); };
    signal.addEventListener('abort', abort, { once: true });
    try {
      if (!finished) child.stdin.end('close\n');
      const exit = await exitPromise;
      demand(exit.code === 0 && closedEvent, 'REGISTRATION_NATIVE_CLOSE_UNPROVEN');
      return { released: true, evidence: exit };
    } finally { signal.removeEventListener('abort', abort); lines?.close(); if (!finished) child.kill(); }
  });
  const wait = (type, round, action) => lifecycle.observe({ phase: 'registration-' + type, timeoutMs: 15000,
    subscribe(resolveEvent, rejectEvent) {
      demand(!awaiting, 'REGISTRATION_CONCURRENT_COMMAND');
      awaiting = { type, round, resolve: resolveEvent, reject: rejectEvent };
      return () => { awaiting = null; };
    }, action }).then(result => result.observed);
  const ready = await wait('ready', undefined, () => {
    child = spawn(executable, [scope.jobName, scope.desktopName ?? '', directory], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    exitPromise = new Promise(resolveExit => child.once('close', (code, signal) => { finished = true; reject(new Error('REGISTRATION_NATIVE_EXIT')); resolveExit({ code, signal }); }));
    child.once('error', () => reject(new Error('REGISTRATION_NATIVE_START_FAILED')));
    child.once('spawn', () => { if (!lifecycle.closing) lifecycle.acquire(resource, { pid: child.pid, directory }); });
    child.stderr.resume();
    lines = createInterface({ input: child.stdout });
    lines.on('line', line => {
      try {
        demand(line.length <= 1048576, 'REGISTRATION_PROTOCOL_SIZE');
        const event = JSON.parse(line);
        if (event.type === 'closed') closedEvent = true;
        else if (event.type === 'error') reject(new Error(event.code));
        else if (awaiting?.type === event.type && (awaiting.round === undefined || awaiting.round === event.round)) awaiting.resolve(event);
        else reject(new Error('REGISTRATION_UNEXPECTED_EVENT'));
      } catch (error) {
        reject(error);
      }
    });
  });
  demand(ready.jobName === scope.jobName && ready.desktopName === scope.desktopName, 'REGISTRATION_SCOPE_MISMATCH');
  const paths = new Set();
  return {
    ready,
    arm: (round, nonce) => wait('armed', round, () => child.stdin.write('arm ' + round + ' ' + nonce + '\n')),
    async snapshot(round) {
      const event = await wait('frames', round, () => child.stdin.write('snapshot ' + round + '\n'));
      demand(Array.isArray(event.observations) && event.observations.length <= 32, 'REGISTRATION_FRAME_SET');
      const observations = [];
      for (const frame of event.observations) {
        const absolute = resolve(frame.path), local = relative(directory, absolute);
        demand(local && !local.startsWith('..') && !isAbsolute(local) && !paths.has(absolute), 'REGISTRATION_FRAME_PATH');
        const info = await stat(absolute);
        demand(info.isFile() && info.size > 0 && info.size <= 67108864, 'REGISTRATION_FRAME_SIZE');
        const bytes = await readFile(absolute);
        demand(bytes.length === info.size && Number.isSafeInteger(frame.width) && Number.isSafeInteger(frame.height) && frame.stride === frame.width * 4 && frame.stride * frame.height === bytes.length, 'REGISTRATION_FRAME_SIZE');
        const path = relative(root, absolute).replaceAll('\\', '/');
        demand(!path.startsWith('../') && !isAbsolute(path), 'REGISTRATION_ARTIFACT_ROOT');
        paths.add(absolute);
        observations.push({ ...frame, path, sha256: hash(bytes) });
      }
      return { round: event.round, barrierQpc: event.barrierQpc, frequency: event.frequency, observations };
    },
    async close() { const result = await lifecycle.release(resource); demand(result.released, 'REGISTRATION_NATIVE_CLOSE_UNPROVEN'); },
  };
}

// The owned-scope facts the launcher establishes, in the form each launch mode produces them. A
// private desktop is the isolated launch's enumeration scope; the interactive launch - the only mode
// in which this Studio build registers its MCP server - runs on the caller's own desktop, so it is
// accepted on the job, the no-breakaway tree and the process identity alone. That identity carries
// the pid and its creation stamp in two encodings of the same instant, so a reused pid cannot pass.
// This check never admits a window: the native inventory restricts candidates to processes inside
// this job, and checkSourceIdentity requires the captured window owner to be the admitted process
// identity.
export function ownedScope(ownedProcess) {
  if (!ownedProcess || typeof ownedProcess !== 'object') return false;
  if (!/^Local\\ForgeQA-[a-f0-9]+$/.test(ownedProcess.jobName || '')) return false;
  if (ownedProcess.treeOwnership !== 'windows-job-no-breakaway') return false;
  const pid = ownedProcess.pid;
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  const stamp = /^pid:([0-9]+):created:([0-9]+)$/.exec(ownedProcess.captureIdentity || '');
  if (!stamp || Number(stamp[1]) !== pid) return false;
  const created = Date.parse(ownedProcess.creationTime);
  if (!Number.isFinite(created)) return false;
  // FileTime ticks and the ISO stamp are two encodings of the same instant.
  const millis = Number(BigInt(stamp[2]) / 10000n) - 11644473600000;
  if (Math.abs(millis - created) > 2000) return false;
  const privateDesktop = /^ForgeQA-[a-f0-9]+$/.test(ownedProcess.desktopName || '');
  const interactive =
    ownedProcess.desktopMode === 'interactive'
    && typeof ownedProcess.desktopName === 'string'
    && ownedProcess.desktopName.length > 0;
  return privateDesktop || interactive;
}

export async function registerClientSource({ logical, ownedProcess, artifactDirectory, transport, lifecycle, root = process.cwd() }) {
  demand(ownedScope(ownedProcess), 'REGISTRATION_OWNED_SCOPE_REQUIRED');
  const directory = resolve(artifactDirectory, 'registration-' + randomBytes(16).toString('hex'));
  await mkdir(resolve(artifactDirectory), { recursive: true });
  await mkdir(directory);
  const native = await openNative(resolve(root, 'build/task16-qualityav-native/Release/qualityav-register.exe'), directory, ownedProcess, lifecycle, root);
  const execute = async (code, phase) => {
    if (phase === 3) transport.deadline = Date.now() + 10000;
    // A freshly registered client datamodel reports a transient reachability failure
    // until its Luau bridge loads; retry only that failure against a bounded deadline
    // so the registration phase never reports a product error for a slow bridge.
    const bridgeDeadline = Date.now() + 30000;
    let result;
    for (;;) {
      // Phase 3 keeps its short transport window per attempt instead of expiring it
      // while the bridge is still loading.
      if (phase === 3) transport.deadline = Date.now() + 10000;
      try {
        result = await transport.call('execute_luau', { studio_id: logical.studioId, datamodel_type: 'Client', code });
        break;
      } catch (error) {
        const message = String(error && error.message ? error.message : error);
        if (!/Target is not reachable|createExecuteLuauBridge|Place is not open/i.test(message) || Date.now() >= bridgeDeadline) throw error;
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    }
    demand(!result.isError, 'REGISTRATION_PRODUCT_ERROR');
    const text = (result.content || []).filter(part => part.type === 'text').map(part => part.text).join('\n');
    const marker = text.match(/FORGE_QA_JSON:([^\r\n]+)/);
    return JSON.parse(marker ? marker[1] : text);
  };
  return measureRegistration({ native, logical, execute, persist: async proof => {
    const absolute = resolve(directory, 'registration.json');
    const bytes = Buffer.from(JSON.stringify(proof));
    await writeFile(absolute, bytes, { flag: 'wx' });
    const path = relative(root, absolute).replaceAll('\\', '/');
    demand(!path.startsWith('../') && !isAbsolute(path), 'REGISTRATION_ARTIFACT_ROOT');
    const artifacts = [path, ...proof.rounds.flatMap(round => round.observations.map(row => row.path)), ...(proof.cleanup?.observations || []).map(row => row.path)];
    return { reference: { path, sha256: hash(bytes) }, artifacts };
  } });
}
