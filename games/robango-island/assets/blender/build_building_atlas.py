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
        normal[ys, xs] = load(os.path.join(src, pid, "nor.jpg"), crop_top=crop)
        rough[ys, xs] = load(os.path.join(src, pid, "rough.jpg"), crop_top=crop)
        print(f"tile {index:2d} {name:8s} mean={albedo[ys, xs].reshape(-1, 3).mean(0).round(3)} target={target}")
    for label, data in (("albedo", albedo), ("normal", normal), ("rough", rough)):
        Image.fromarray((data * 255 + 0.5).astype(np.uint8)).save(os.path.join(root, f"atlas_{label}.png"))
    print("atlas written to", root)


if __name__ == "__main__":
    main()
