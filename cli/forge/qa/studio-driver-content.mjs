// Visual-content gate for a captured frame.
//
// The geometry checks around a capture prove the HUD was where it said it was and
// that the image decoded; they say nothing about whether the 3D view rendered at
// all. A place whose baked Lighting was wrong once produced captures that passed
// every geometry gate while the entire world region was a flat screen, so this
// gate measures the pixels the HUD does not own.
//
// The world region is the full frame minus the rectangles the run owns (the
// measured critical-UI set) and minus the reserved chat window. Its block
// luminance is decoded from the same parser the capture already uses
// (studio-driver-surface.mjs), so no second image decoder is introduced.
//
// The failure signal is DETAIL: the mean per-block structure of the world region.
// Each 8x8 block carries a detail value - for a JPEG, the count of its nonzero AC
// coefficients; for a PNG, the count of pixels deviating from the block's own
// mean - so a smooth block is near zero and a block crossed by an edge, texture or
// an object is large. A rendered scene is full of the latter; a screen that failed
// to render is a smooth field of the former. Detail is used rather than a plain
// standard deviation because a blank world is not always one colour: a white sky
// over a washed-out ground is two large flat fields, which has a large spread but
// no structure. Measured on real captures the two populations do not overlap - a
// blank world scores 0.1-1.9, a rendered one 3.9-21.8.
import { LUMA_BLOCK } from './studio-driver-surface.mjs';

const demand = (condition, code) => { if (!condition) throw new Error(code); };

export const VISUAL_CONTENT = Object.freeze({
  // Below this many world samples the region cannot be judged (the HUD covers
  // nearly everything); the gate reports "skipped" rather than guessing.
  minSamples: 64,
  // Mean per-block detail below which the world region reads as structure-free.
  // The real gap is 1.9 (blank) to 3.9 (rendered); this sits between them.
  minDetail: 2.5,
});

/** Mean/standard deviation/median of a sample list (reported as evidence). */
export function uniformityStats(samples) {
  const count = samples.length;
  if (count === 0) return { count: 0, mean: null, stdDev: null, median: null };
  let sum = 0;
  for (const value of samples) sum += value;
  const mean = sum / count;
  let variance = 0;
  for (const value of samples) {
    const delta = value - mean;
    variance += delta * delta;
  }
  const sorted = Array.from(samples).sort((a, b) => a - b);
  const median = count % 2 === 1 ? sorted[(count - 1) >> 1] : (sorted[count / 2 - 1] + sorted[count / 2]) / 2;
  return { count, mean, stdDev: Math.sqrt(variance / count), median };
}

/**
 * The block detail grid with every block whose centre falls in an excluded
 * rectangle set to null. Exact enough for HUD rectangles, which are tens of
 * pixels wide and never the whole frame.
 */
export function worldRegionGrid(luma, excludeRects = []) {
  const { cols, rows, values, detail } = luma;
  const grid = [];
  for (let by = 0; by < rows; by++) {
    const centreY = by * LUMA_BLOCK + LUMA_BLOCK / 2;
    const row = [];
    for (let bx = 0; bx < cols; bx++) {
      const centreX = bx * LUMA_BLOCK + LUMA_BLOCK / 2;
      let excluded = false;
      for (const rect of excludeRects) {
        if (centreX >= rect.x && centreX < rect.x + rect.width && centreY >= rect.y && centreY < rect.y + rect.height) {
          excluded = true;
          break;
        }
      }
      row.push(excluded ? null : { luma: values[by * cols + bx], detail: detail[by * cols + bx] });
    }
    grid.push(row);
  }
  return grid;
}

/** The non-null blocks of a world-region grid, in reading order. */
export function regionBlocks(grid) {
  const blocks = [];
  for (const row of grid) for (const block of row) if (block !== null) blocks.push(block);
  return blocks;
}

/** The mean per-block detail of a world-region grid. */
export function meanDetail(grid) {
  const blocks = regionBlocks(grid);
  if (blocks.length === 0) return 0;
  let sum = 0;
  for (const block of blocks) sum += block.detail;
  return sum / blocks.length;
}

/**
 * Fails when the world region of `luma` is structure-free. Returns the measured
 * statistics on success (or `{ verdict: 'inconclusive' }` when too little of the frame
 * is world), and throws `CAPTURE_VISUAL_CONTENT_UNIFORM` with the numbers when
 * the region has almost no visible structure.
 *
 * `inconclusive` is not a pass: the HUD covered nearly the whole frame, so the world
 * region could not be judged. The capture path records such a frame as inconclusive
 * evidence rather than as proof the world rendered.
 */
export function assertVisualContent({ luma, excludeRects = [], label = 'capture' } = {}) {
  demand(
    luma && Number.isInteger(luma.cols) && luma.cols > 0 && Number.isInteger(luma.rows) && luma.rows > 0
      && luma.values && luma.values.length === luma.cols * luma.rows,
    'VISUAL_CONTENT_LUMA_REQUIRED',
  );
  const grid = worldRegionGrid(luma, excludeRects);
  const blocks = regionBlocks(grid);
  const stats = uniformityStats(blocks.map(block => block.luma));
  if (stats.count < VISUAL_CONTENT.minSamples) {
    return { ...stats, verdict: 'inconclusive', reason: 'only ' + stats.count + ' world samples' };
  }
  const detail = meanDetail(grid);
  if (detail < VISUAL_CONTENT.minDetail) {
    throw new Error('CAPTURE_VISUAL_CONTENT_UNIFORM:' + JSON.stringify({
      label,
      samples: stats.count,
      meanDetail: Number(detail.toFixed(5)),
      stdDev: Number(stats.stdDev.toFixed(5)),
      mean: Number(stats.mean.toFixed(5)),
    }));
  }
  return { ...stats, meanDetail: detail, verdict: 'varied' };
}
