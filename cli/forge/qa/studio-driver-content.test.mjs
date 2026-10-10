import { test, expect } from 'bun:test';
import { deflateSync } from 'node:zlib';
import { decodeRasterLuma, LUMA_BLOCK } from './studio-driver-surface.mjs';
import {
  assertVisualContent,
  meanDetail,
  regionBlocks,
  uniformityStats,
  worldRegionGrid,
  VISUAL_CONTENT,
} from './studio-driver-content.mjs';

// A genuine RGB PNG from a per-pixel function, so the decoder is exercised on a
// real encoded stream rather than a header-only fake.
function png(width, height, pixel) {
  const raw = Buffer.alloc(height * (1 + width * 3));
  for (let y = 0; y < height; y++) {
    const rowStart = y * (1 + width * 3);
    raw[rowStart] = 0; // filter: None
    for (let x = 0; x < width; x++) {
      const [r, g, b] = pixel(x, y);
      const o = rowStart + 1 + x * 3;
      raw[o] = r; raw[o + 1] = g; raw[o + 2] = b;
    }
  }
  const chunk = (kind, data) => {
    const body = Buffer.concat([Buffer.from(kind), data]);
    let crc = 0xffffffff;
    for (const byte of body) { crc ^= byte; for (let k = 0; k < 8; k++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
    const header = Buffer.alloc(4); header.writeUInt32BE(data.length);
    const tail = Buffer.alloc(4); tail.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([header, body, tail]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// The real capture path is JPEG, so every assertion is exercised on an encoded
// JPEG too: Bun's own image encoder turns the synthetic PNG into a baseline JPEG.
const jpeg = async buffer => Buffer.from(await new Bun.Image(buffer).jpeg({ quality: 95 }).bytes());

const WIDTH = 320, HEIGHT = 240;
// A HUD strip across the top and a control box bottom-right, both excluded - the
// same shape a real capture's critical-UI set has.
const EXCLUDED = [
  { x: 0, y: 0, width: WIDTH, height: 30 },
  { x: WIDTH - 80, y: HEIGHT - 40, width: 80, height: 40 },
];

// The world is one flat colour: a screen that did not render at all.
const flatWorld = png(WIDTH, HEIGHT, (x, y) => {
  if (y < 30) return [20, 22, 28];
  if (x >= WIDTH - 80 && y >= HEIGHT - 40) return [255, 140, 40];
  return [252, 252, 253];
});

// The world is two large flat fields - a white sky over a grey ground. This is the
// real blank-world mobile shape: a large spread, but no structure.
const twoToneWorld = png(WIDTH, HEIGHT, (x, y) => {
  if (y < 30) return [20, 22, 28];
  if (x >= WIDTH - 80 && y >= HEIGHT - 40) return [255, 140, 40];
  return y < HEIGHT * 0.6 ? [250, 250, 251] : [190, 190, 192];
});

// A rendered-looking world: sky gradient, ground and a handful of parts, so most
// blocks are crossed by a boundary.
const variedWorld = png(WIDTH, HEIGHT, (x, y) => {
  if (y < 30) return [20, 22, 28];
  if (x >= WIDTH - 80 && y >= HEIGHT - 40) return [255, 140, 40];
  const horizon = Math.floor(HEIGHT * 0.55);
  if (y < horizon) {
    const t = y / horizon;
    return [Math.round(110 + 90 * t), Math.round(160 + 60 * t), Math.round(225 + 25 * t)];
  }
  const ground = [Math.round(70 + 40 * ((x * 7) % 13) / 13), Math.round(120 + 30 * ((y * 5) % 11) / 11), 80];
  if (x % 97 < 12 && y % 71 < 26) return [200, 196, 120];
  if (x % 53 < 9 && y % 47 < 18) return [150, 150, 148];
  return ground;
});

test('a flat one-colour world fails the visual-content gate', async () => {
  for (const bytes of [flatWorld, await jpeg(flatWorld)]) {
    const { luma, format } = decodeRasterLuma(bytes);
    expect(format).toBe(bytes === flatWorld ? 'png' : 'jpeg');
    expect(meanDetail(worldRegionGrid(luma, EXCLUDED))).toBeLessThan(VISUAL_CONTENT.minDetail);
    expect(() => assertVisualContent({ luma, excludeRects: EXCLUDED, label: 'flat' })).toThrow(/CAPTURE_VISUAL_CONTENT_UNIFORM/);
  }
});

test('a two-tone blank world (white sky over grey ground) fails', async () => {
  // The real blank mobile frame: a sky/ground step gives a non-trivial luminance
  // spread, but the two fields carry no structure, so a stddev-only gate would
  // pass it and the detail gate must not.
  for (const bytes of [twoToneWorld, await jpeg(twoToneWorld)]) {
    const { luma } = decodeRasterLuma(bytes);
    const grid = worldRegionGrid(luma, EXCLUDED);
    const spread = uniformityStats(regionBlocks(grid).map(block => block.luma)).stdDev;
    expect(spread).toBeGreaterThan(0.05);
    expect(meanDetail(grid)).toBeLessThan(VISUAL_CONTENT.minDetail);
    expect(() => assertVisualContent({ luma, excludeRects: EXCLUDED, label: 'two-tone' })).toThrow(/CAPTURE_VISUAL_CONTENT_UNIFORM/);
  }
});

test('a varied world region passes the visual-content gate', async () => {
  for (const bytes of [variedWorld, await jpeg(variedWorld)]) {
    const { luma } = decodeRasterLuma(bytes);
    const stats = assertVisualContent({ luma, excludeRects: EXCLUDED, label: 'varied' });
    expect(stats.verdict).toBe('varied');
    expect(stats.meanDetail).toBeGreaterThanOrEqual(VISUAL_CONTENT.minDetail);
  }
});

test('the gate measures the world region, not the HUD it excludes', () => {
  // A frame whose world is flat but whose HUD is large and busy: without the
  // exclusion the busy HUD raises the mean detail and masks the blank world, so
  // the exclusion is what makes the gate measure the world rather than the UI.
  const hudLeft = 160; // half the frame is an excluded, high-contrast HUD panel
  const masked = png(WIDTH, HEIGHT, (x, y) => {
    if (x < hudLeft) return (x + y) % 2 === 0 ? [10, 10, 10] : [250, 250, 250]; // busy HUD
    return [252, 252, 253]; // the whole world, flat white
  });
  const excludedHud = [{ x: 0, y: 0, width: hudLeft, height: HEIGHT }];
  const { luma } = decodeRasterLuma(masked);
  expect(meanDetail(worldRegionGrid(luma, excludedHud))).toBeLessThan(VISUAL_CONTENT.minDetail);
  expect(meanDetail(worldRegionGrid(luma, []))).toBeGreaterThanOrEqual(VISUAL_CONTENT.minDetail);
  expect(() => assertVisualContent({ luma, excludeRects: excludedHud, label: 'masked' })).toThrow(/CAPTURE_VISUAL_CONTENT_UNIFORM/);
  expect(assertVisualContent({ luma, excludeRects: [], label: 'masked' }).verdict).toBe('varied');
});

test('the block grid matches the image size', () => {
  const { luma } = decodeRasterLuma(variedWorld);
  expect(luma.cols).toBe(Math.ceil(WIDTH / LUMA_BLOCK));
  expect(luma.rows).toBe(Math.ceil(HEIGHT / LUMA_BLOCK));
  expect(luma.values.length).toBe(luma.cols * luma.rows);
  expect(luma.detail.length).toBe(luma.cols * luma.rows);
  for (const value of luma.values) {
    expect(value).toBeGreaterThanOrEqual(0);
    expect(value).toBeLessThanOrEqual(1);
  }
});

test('a region too small to judge is reported inconclusive rather than failed', () => {
  // A HUD covering nearly the whole frame is not evidence the world rendered: the verdict is
  // `inconclusive`, which the capture path records as unjudgeable rather than as a visual pass.
  const { luma } = decodeRasterLuma(flatWorld);
  const everything = [{ x: 0, y: 0, width: WIDTH, height: HEIGHT }];
  expect(assertVisualContent({ luma, excludeRects: everything, label: 'covered' }).verdict).toBe('inconclusive');
});

test('uniformityStats reports the spread it is given', () => {
  const flat = uniformityStats(new Array(400).fill(0.98));
  expect(flat.stdDev).toBeCloseTo(0, 9);
  const spread = uniformityStats(Array.from({ length: 400 }, (_, i) => (i % 20) / 20));
  expect(spread.stdDev).toBeGreaterThan(0.2);
});
