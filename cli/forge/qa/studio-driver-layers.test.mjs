import { test, expect } from 'bun:test';
import { deflateSync } from 'node:zlib';
import { runStudio } from './studio-driver.mjs';
import { layersOf, withLayers, hideUiCode, restoreUiCode, hideWorldCode, restoreWorldCode } from './studio-driver-layers.mjs';

// The MCP mock follows studio-driver.test.mjs: a transport whose `call` answers by the code it is
// sent, and which records every call in order so the hide/capture/restore sequence is observable.
function png(width, height) {
  const chunk = (kind, data) => {
    const body = Buffer.concat([Buffer.from(kind), data]);
    let crc = 0xffffffff;
    for (const b of body) { crc ^= b; for (let k = 0; k < 8; k++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
    const header = Buffer.alloc(4), tail = Buffer.alloc(4);
    header.writeUInt32BE(data.length); tail.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([header, body, tail]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  const raw = Buffer.alloc(height * (width * 3 + 1));
  for (let y = 0; y < height; y++) {
    const start = y * (width * 3 + 1);
    for (let x = 0; x < width; x++) {
      const o = start + 1 + x * 3;
      raw[o] = (x * 7 + y * 3) & 255; raw[o + 1] = (x * 3 + y * 11) & 255; raw[o + 2] = (x * 13 + y * 5) & 255;
    }
  }
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

const geometry = {
  device: { id: 'desktop', surface: 'desktop', width: 1280, height: 720, form: 'Desktop', orientation: 'LandscapeLeft', scaling: 'ActualResolution' },
  logical: {
    full: { x: 0, y: 0, width: 1280, height: 720 },
    viewport: { x: 0, y: 0, width: 1280, height: 720 },
    safeArea: { x: 0, y: 0, width: 1280, height: 720 },
    insets: { left: 0, top: 0, right: 0, bottom: 0 },
  },
  criticalUI: [{ id: 'action', x: 10, y: 50, width: 100, height: 40 }],
};
const text = value => ({ content: [{ type: 'text', text: JSON.stringify(value) }] });
const config = { buildIdentity: { id: 'sha256:' + 'a'.repeat(64) }, ownershipToken: 'owned-test', serverId: 'server', clients: [{ studioId: 'client1', userId: '-1' }, { studioId: 'client2', userId: '-2' }] };
const scenarioOf = capture => ({
  name: 'layers', kind: 'studio', timeout_seconds: 30, players: ['first', 'second'],
  steps: [
    { op: 'device', player: 'first', surface: 'desktop', width: 1280, height: 720, timeout_seconds: 5 },
    { op: 'device', player: 'second', surface: 'desktop', width: 1280, height: 720, timeout_seconds: 5 },
    { op: 'join', player: 'first' },
    capture,
  ],
});

function transport({ captureFails = false, hideFails = false } = {}) {
  const order = [];
  return {
    order,
    async request() {
      return { tools: ['list_roblox_studios', 'get_studio_state', 'execute_luau', 'screen_capture', 'user_keyboard_input'].map(name => ({ name, inputSchema: { properties: Object.fromEntries(['studio_id', 'code', 'datamodel_type', 'capture_id', 'actions'].map(key => [key, {}])) } })) };
    },
    async call(name, args) {
      if (name === 'list_roblox_studios') return text({ studios: ['server', 'client1', 'client2'].map(id => ({ id })) });
      if (name === 'get_studio_state') return text(args.studio_id === 'server' ? 'Server' : 'Client');
      if (name === 'screen_capture') {
        order.push('capture');
        if (captureFails) throw new Error('screenshot failed');
        return { content: [{ type: 'image', mimeType: 'image/png', data: png(1600, 900).toString('base64') }] };
      }
      if (name === 'user_keyboard_input') return text('Success');
      const code = args.code;
      if (code.includes('ForgeQA.revision:Invoke')) return text(2);
      for (const [label, source] of [['hide-ui', hideUiCode], ['restore-ui', restoreUiCode], ['hide-world', hideWorldCode], ['restore-world', restoreWorldCode]]) {
        if (code.includes(source)) {
          order.push(label);
          if (hideFails && label.startsWith('hide')) throw new Error('hide failed');
          return text({ ok: true });
        }
      }
      if (code.includes('BUILD_HANDSHAKE_UNAVAILABLE')) {
        return text({ schemaVersion: 1, role: args.datamodel_type.toLowerCase(), buildIdentity: config.buildIdentity.id, serverBuildIdentity: config.buildIdentity.id, sessionId: 'fixture-session', actorId: args.studio_id === 'client1' ? '-1' : '-2', ownedQaToken: config.ownershipToken, placeId: 0 });
      }
      if (code.includes('local controls={}')) { order.push('geometry'); return text(geometry); }
      if (code.includes('local desired=')) return text({ device: 'desktop', width: 1280, height: 720, orientation: 'LandscapeLeft' });
      if (code.includes("folder:FindFirstChild('")) return text({ present: false });
      if (code.includes('placeId=game.PlaceId')) return text({ placeId: 0, token: config.ownershipToken, player: args.studio_id === 'client1' ? '-1' : '-2' });
      if (code.includes('m:Destroy()')) return text('clean');
      if (code.includes('GetPlayers()')) return text(['-1', '-2']);
      if (code.includes('local step=')) return text({ result: { ok: true }, revision: 2 });
      return text({ revision: 1 });
    },
  };
}

const run = (capture, options) => {
  const mock = transport(options);
  return { mock, done: runStudio(scenarioOf(capture), config, mock, async name => name) };
};
const layerCalls = order => order.filter(entry => entry !== 'geometry');
const perClient = (hide, restore) => [hide, 'capture', restore, hide, 'capture', restore];

test('layers default to all and reject anything else', () => {
  expect(layersOf({ op: 'capture' })).toBe('all');
  expect(layersOf({ op: 'capture', layers: 'ui' })).toBe('ui');
  expect(() => layersOf({ op: 'capture', layers: 'hud' })).toThrow('CAPTURE_LAYERS_INVALID');
});

test('world capture hides every owned ScreenGui, captures, then restores the remembered values', async () => {
  const { mock, done } = run({ op: 'capture', target: 'world', layers: 'world' });
  const result = await done;
  expect(result.blockers).toEqual([]);
  expect(layerCalls(mock.order)).toEqual(perClient('hide-ui', 'restore-ui'));
  expect(result.captures.map(row => row.layers)).toEqual(['world', 'world']);
  // The hide leaves the previous Enabled value on the gui itself and the restore reads it back.
  expect(hideUiCode).toContain('gui.Enabled=false');
  expect(hideUiCode).toContain("gui:SetAttribute('ForgeQALayerPrevEnabled',gui.Enabled)");
  expect(restoreUiCode).toContain("gui.Enabled=previous");
});

test('ui capture makes every part locally invisible, captures, then restores', async () => {
  const { mock, done } = run({ op: 'capture', target: 'ui', layers: 'ui' });
  const result = await done;
  expect(result.blockers).toEqual([]);
  expect(layerCalls(mock.order)).toEqual(perClient('hide-world', 'restore-world'));
  expect(result.captures.map(row => row.layers)).toEqual(['ui', 'ui']);
  expect(result.captures[0].visualContent.verdict).toBe('not-applicable');
  expect(hideWorldCode).toContain('part.LocalTransparencyModifier=1');
  expect(hideWorldCode).not.toContain('CurrentCamera');
  expect(restoreWorldCode).toContain('part.LocalTransparencyModifier=previous');
});

test('all, and an absent layers field, touch no layer', async () => {
  for (const capture of [{ op: 'capture', target: 'all', layers: 'all' }, { op: 'capture', target: 'default' }]) {
    const { mock, done } = run(capture);
    const result = await done;
    expect(layerCalls(mock.order)).toEqual(['capture', 'capture']);
    expect(result.captures.map(row => row.layers)).toEqual(['all', 'all']);
  }
});

test('the layer is restored even when the capture throws, and the capture error wins', async () => {
  for (const layers of ['world', 'ui']) {
    const { mock, done } = run({ op: 'capture', target: layers, layers }, { captureFails: true });
    const result = await done;
    expect(result.ok).toBe(false);
    expect(layerCalls(mock.order)).toEqual([`hide-${layers === 'world' ? 'ui' : 'world'}`, 'capture', `restore-${layers === 'world' ? 'ui' : 'world'}`]);
  }
  const actions = [];
  const execute = async (_id, _model, code) => { actions.push(code === hideUiCode ? 'hide' : 'restore'); };
  await expect(withLayers('world', { studioId: 'c' }, execute, async () => { throw new Error('screenshot failed'); })).rejects.toThrow('screenshot failed');
  expect(actions).toEqual(['hide', 'restore']);
});

test('a hide that fails part-way is still restored and never reaches the screenshot', async () => {
  const actions = [];
  const execute = async (_id, _model, code) => {
    actions.push(code === hideUiCode ? 'hide' : 'restore');
    if (code === hideUiCode) throw new Error('hide failed');
  };
  let captured = false;
  await expect(withLayers('world', { studioId: 'c' }, execute, async () => { captured = true; })).rejects.toThrow('hide failed');
  expect(captured).toBe(false);
  expect(actions).toEqual(['hide', 'restore']);
});

test('a failed restore after a good capture is reported, not swallowed', async () => {
  const execute = async (_id, _model, code) => { if (code === restoreWorldCode) throw new Error('restore failed'); };
  await expect(withLayers('ui', { studioId: 'c' }, execute, async () => 'image')).rejects.toThrow('restore failed');
});
