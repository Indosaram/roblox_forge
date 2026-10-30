"""B3 building atlas: 4x4 tiles of graded CC0 Poly Haven surfaces (see SOURCES.md).

Run with plain Python (Pillow + numpy), from the repository root:
    python games/robango-island/assets/blender/build_building_atlas.py build/b3
Inputs:  build/b3/src/<polyhaven id>/{diff,nor,rough}.jpg (1k, CC0).
Outputs: build/b3/atlas_albedo.png, atlas_normal.png, atlas_rough.png (1024).
The tile order is the TILES list; gen_buildings.py uses the same indices.
"""

import os
import sys

import numpy as np
from PIL import Image

SIZE, GRID = 1024, 4
CELL = SIZE // GRID

# (name, polyhaven id or None for a solid, sRGB target mean, saturation kept)
TILES = [
    ("log", "bark_brown_02", "#6a5843", 0.6),
    ("plank", "old_planks_02", "#7d6646", 0.6),
    ("thatch", "reed_roof_04", "#8a7650", 0.6),
    ("canvas", "rough_linen", "#a39272", 0.5),
    ("rope", "hessian_230", "#8c7a55", 0.6),
    ("stone", "stacked_stone_wall", "#6c5c4b", 0.55),
    ("brick", "brick_wall_02", "#8a5a40", 0.7),
    ("clay", "clay_plaster", "#957657", 0.6),
    ("slate", "roof_slates_02", "#4f4a45", 0.5),
    ("tile", "clay_roof_tiles_02", "#8a4e34", 0.7),
    ("metal", "rusty_metal_02", "#5a4636", 0.6),
    ("hide", "rough_linen", "#7b5a3a", 0.8),
    ("char", "stacked_stone_wall", "#2c2622", 0.3),
    ("ember", None, "#ff8a30", 1.0),
    ("teal", "rough_linen", "#2f7a74", 0.9),
    ("seaglass", "stacked_stone_wall", "#3f8a84", 0.9),
]


def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i : i + 2], 16) / 255 for i in (0, 2, 4)], np.float32)


def load(path, mode="RGB", crop_top=0.0):
    image = Image.open(path).convert(mode)
    if crop_top:
        # reed_roof_04 carries a band of grass along its top edge; keep only the reed courses.
        image = image.crop((0, int(image.height * crop_top), image.width, image.height))
    return np.asarray(image.resize((CELL, CELL), Image.LANCZOS), np.float32) / 255


def blur(field, passes):
    for _ in range(passes):
        field = (field + np.roll(field, 1, 0) + np.roll(field, -1, 0) + np.roll(field, 1, 1) + np.roll(field, -1, 1)) / 5
    return field


def weather_cloth(rgb, seed):
    """Canvas / cloth wear so linen does not read as a flat cream fill at the town camera:
    low-frequency mottling, two sewn panel seams with stitch shadows, a grime band along the
    bottom edge (UVs on cloth run world-up) and a couple of darker patches. Tileable in X."""
    rng = np.random.default_rng(seed)
    n = rgb.shape[0]
    mottle = blur(rng.standard_normal((n, n)).astype(np.float32), 40)
    mottle = mottle / (np.abs(mottle).max() + 1e-6)
    shade = 1 + 0.16 * mottle
    y = np.linspace(0, 1, n, dtype=np.float32)[:, None]
    shade *= 1 - 0.22 * np.clip((y - 0.72) / 0.28, 0, 1) ** 1.5  # grime toward the hem
    shade *= 1 - 0.06 * np.clip((0.12 - y) / 0.12, 0, 1)
    x = np.arange(n)[None, :]
    for seam in (n // 3, 2 * n // 3):
        d = np.abs(x - seam)
        shade *= 1 - 0.28 * (d <= 1) - 0.1 * ((d > 1) & (d <= 4))
        stitch = (d == 3) & ((np.arange(n)[:, None] // 5) % 2 == 0)
        shade *= 1 - 0.18 * stitch
    stains = np.zeros((n, n), np.float32)
    yy, xx = np.ogrid[:n, :n]
    for _ in range(3):  # soft water stains
        cy, cx = rng.integers(30, n - 30, 2)
        r = rng.integers(14, 30)
        stains += np.exp(-(((yy - cy) ** 2 + (xx - cx) ** 2) / (2.0 * r * r))).astype(np.float32)
    shade *= 1 - 0.12 * np.clip(stains, 0, 1)
    return np.clip(rgb * shade[..., None], 0, 1)


GRIME_BAND = 0.28  # bottom share of every texture tile (gen_buildings GROUND_BAND): ground grime


def paint(rgb, name, seed):
    """L11 painted pass: turn the photo scan into a hand-painted read at the 57 deg phone camera.
    Roblox adds no AO to a MeshPart texture, so the colour map carries it:
    - scan noise is softened (box blur blend) and the mid-frequency form is kept;
    - cavities darken and raised grain catches a warm highlight (luminance high-pass);
    - shadows lean cool, lights lean warm (a painter's split);
    - the bottom GRIME_BAND of the tile is earth grime: gen_buildings maps faces that touch the
      ground onto it, so every post foot, wall base and bench leg sits in a dark damp band;
    - the top 10% is sun-bleached (post tops, rail tops, roof ridges map there)."""
    rng = np.random.default_rng(seed)
    n = rgb.shape[0]
    soft = rgb.copy()
    for _ in range(3):
        soft = (soft + np.roll(soft, 1, 0) + np.roll(soft, -1, 0) + np.roll(soft, 1, 1) + np.roll(soft, -1, 1)) / 5
    rgb = rgb * 0.45 + soft * 0.55
    lum = (rgb * np.array([0.2126, 0.7152, 0.0722], np.float32)).sum(2)
    cav = lum - blur(lum, 8)
    cav = cav / (np.abs(cav).max() + 1e-6)
    rgb = rgb * (1 + np.where(cav < 0, 0.9, 0.45)[..., None] * cav[..., None])
    lum = (rgb * np.array([0.2126, 0.7152, 0.0722], np.float32)).sum(2, keepdims=True)
    rel = np.clip(lum / (lum.mean() + 1e-6), 0, 2)
    warm = np.array([1.06, 1.0, 0.9], np.float32)
    cool = np.array([0.9, 0.95, 1.06], np.float32)
    t = np.clip((rel - 0.6) / 0.8, 0, 1)
    rgb = rgb * (cool + (warm - cool) * t)
    big = blur(rng.standard_normal((n, n)).astype(np.float32), 30)
    big = big / (np.abs(big).max() + 1e-6)
    rgb = rgb * (1 + 0.1 * big[..., None])  # broad painted value variation
    y = np.linspace(0, 1, n, dtype=np.float32)[:, None]  # 0 = image top = tile top (high V)
    if name not in ("canvas", "teal", "hide"):  # the cloth tiles carry their own hem grime
        from_bottom = 1 - y
        g = np.clip(1 - from_bottom / GRIME_BAND, 0, 1) ** 1.3
        earth = np.array([0.25, 0.2, 0.15], np.float32)
        rgb = rgb * (1 - 0.55 * g[..., None]) + earth * 0.55 * g[..., None] * 0.6
        streak = blur(rng.standard_normal((1, n)).astype(np.float32).repeat(n, 0), 2)
        rgb = rgb * (1 - 0.08 * g[..., None] * (streak[..., None] > 0))
    bleach = np.clip(1 - y / 0.1, 0, 1)
    rgb = rgb + (np.array([0.9, 0.86, 0.76], np.float32) - rgb) * 0.12 * bleach[..., None]
    return np.clip(rgb, 0, 1)


def rope_tile(n, seed):
    """Twisted hemp rope wraps: diagonal plies with dark gaps, read as lashing at any orientation."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[:n, :n].astype(np.float32)
    period = n / 16
    phase = ((xx + yy * 0.8) % period) / period
    ply = np.sin(phase * np.pi) ** 0.6
    fibre = blur(rng.standard_normal((n, n)).astype(np.float32), 1)
    fibre = fibre / (np.abs(fibre).max() + 1e-6)
    base = hexrgb("#7f6c4a")
    shade = 0.68 + 0.38 * ply + 0.08 * fibre
    return np.clip(base[None, None, :] * shade[..., None], 0, 1)


def hide_tile(rgb, seed):
    """Scraped animal hide: hair-direction streaks, darker blotches, a pale scraped centre."""
    rng = np.random.default_rng(seed)
    n = rgb.shape[0]
    streak = rng.standard_normal((n, n)).astype(np.float32)
    for _ in range(6):
        streak = (streak + np.roll(streak, 1, 0) + np.roll(streak, -1, 0)) / 3  # long along V
    streak = streak / (np.abs(streak).max() + 1e-6)
    blot = blur(rng.standard_normal((n, n)).astype(np.float32), 24)
    blot = blot / (np.abs(blot).max() + 1e-6)
    yy, xx = np.mgrid[:n, :n].astype(np.float32) / n
    centre = np.exp(-(((xx - 0.5) ** 2 + (yy - 0.5) ** 2) / 0.08))
    shade = 1 + 0.18 * streak - 0.22 * np.clip(blot, 0, 1) + 0.14 * centre
    return np.clip(rgb * shade[..., None], 0, 1)


def thatch_courses(rgb):
    """Bundled thatch: four darker course lines across the tile (U), each course lighter at its
    butt edge, so a roof plane reads as layered reed bundles from the phone camera."""
    n = rgb.shape[0]
    y = np.linspace(0, 1, n, dtype=np.float32)[:, None]
    f = (y * 4) % 1.0  # 0 at each course top, 1 at its butt
    shade = 0.78 + 0.32 * f ** 1.5
    shade = np.where(f > 0.94, 0.62, shade)
    return np.clip(rgb * shade[..., None], 0, 1)


def grade(rgb, target, sat):
    lum = (rgb * np.array([0.2126, 0.7152, 0.0722], np.float32)).sum(2, keepdims=True)
    rgb = lum + (rgb - lum) * sat
    mean = rgb.reshape(-1, 3).mean(0)
    return np.clip(rgb * (hexrgb(target) / np.maximum(mean, 1e-3)), 0, 1)


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "build/b3")
    src = os.path.join(root, "src")
    albedo = np.zeros((SIZE, SIZE, 3), np.float32)
    normal = np.zeros((SIZE, SIZE, 3), np.float32)
    rough = np.zeros((SIZE, SIZE, 3), np.float32)
    for index, (name, pid, target, sat) in enumerate(TILES):
        row, col = divmod(index, GRID)
        ys, xs = slice(row * CELL, (row + 1) * CELL), slice(col * CELL, (col + 1) * CELL)
        if pid is None:
            # solid quarters: ember | leaf / flower | glow (gen_buildings.SOLIDS)
            half = CELL // 2
            for (qx, qy), colour in (((0, 0), target), ((1, 0), "#5f6638"), ((0, 1), "#b0603a"), ((1, 1), "#bff4e6")):
                albedo[row * CELL + qy * half : row * CELL + (qy + 1) * half, col * CELL + qx * half : col * CELL + (qx + 1) * half] = hexrgb(colour)
            normal[ys, xs] = (0.5, 0.5, 1.0)
            rough[ys, xs] = 0.9
            continue
        crop = 0.1 if name == "thatch" else 0.0
        albedo[ys, xs] = grade(load(os.path.join(src, pid, "diff.jpg"), crop_top=crop), target, sat)
        if name in ("canvas", "teal", "hide"):
            albedo[ys, xs] = weather_cloth(albedo[ys, xs], index)
        if name == "hide":
            albedo[ys, xs] = hide_tile(albedo[ys, xs], index)
        if name == "thatch":
            albedo[ys, xs] = thatch_courses(albedo[ys, xs])
        if name == "rope":
            albedo[ys, xs] = rope_tile(CELL, index)
        if name not in ("seaglass",):
            albedo[ys, xs] = paint(albedo[ys, xs], name, index + 100)
        normal[ys, xs] = load(os.path.join(src, pid, "nor.jpg"), crop_top=crop)
        rough[ys, xs] = load(os.path.join(src, pid, "rough.jpg"), crop_top=crop)
        print(f"tile {index:2d} {name:8s} mean={albedo[ys, xs].reshape(-1, 3).mean(0).round(3)} target={target}")
    for label, data in (("albedo", albedo), ("normal", normal), ("rough", rough)):
        Image.fromarray((data * 255 + 0.5).astype(np.uint8)).save(os.path.join(root, f"atlas_{label}.png"))
    print("atlas written to", root)


if __name__ == "__main__":
    main()
