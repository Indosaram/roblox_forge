"""L7b tool and gear atlas: 16 hand-painted tiles (4x4 in one 1024 colour map), no scan input.

Run with plain Python (Pillow + numpy), from the repository root:
    python games/robango-island/assets/blender/build_tool_atlas.py build/l7b
Output: build/l7b/tool_atlas.png (1024, sRGB). gen_tools.py maps every face into one tile (TILES
order below is the tile index; keep both lists in sync).

Every tile is painted procedurally from a fixed seed: base colour, low-frequency mottling, the
feature that makes the material read at the 50-stud phone camera (wood grain, wrapped lashing,
knapped facets, bone pores, hammered copper, wicker weave, fur, wool twill, plaited straw, palm
leaf), and painted shading (Roblox adds no ambient occlusion to a MeshPart texture). UV
convention from gen_tools: U runs around a tube, V along it; planar heads map their outline onto
the tile, so the tile border is the worked edge.
"""

import os
import sys

import numpy as np
from PIL import Image

SIZE, GRID = 1024, 4
N = SIZE // GRID
SEED = 4372

TILES = ["wood", "wood_dark", "lash", "leather", "flint", "bone", "copper", "cobble",
         "wicker", "ember", "fur", "wool", "straw", "palm", "hide", "cord"]

yy, xx = np.mgrid[0:N, 0:N].astype(np.float32) / N  # yy = V (0 top row), xx = U


def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i : i + 2], 16) / 255 for i in (0, 2, 4)], np.float32)


def blur(f, passes, axis=None):
    for _ in range(passes):
        if axis is None:
            f = (f + np.roll(f, 1, 0) + np.roll(f, -1, 0) + np.roll(f, 1, 1) + np.roll(f, -1, 1)) / 5
        else:
            f = (f + np.roll(f, 1, axis) + np.roll(f, -1, axis)) / 3
    return f


def noise(rng, passes, axis=None):
    f = blur(rng.standard_normal((N, N)).astype(np.float32), passes, axis)
    return f / (np.abs(f).max() + 1e-6)


def lerp(a, b, t):
    t = np.clip(t, 0, 1)[..., None] if np.ndim(t) else t
    return a * (1 - t) + b * t


def voronoi(rng, cells):
    pts = rng.random((cells, 2)).astype(np.float32)
    d = np.full((N, N), 9.0, np.float32)
    d2 = np.full((N, N), 9.0, np.float32)
    idx = np.zeros((N, N), np.int32)
    for i, (px, py) in enumerate(pts):
        for ox in (-1, 0, 1):  # tileable
            for oy in (-1, 0, 1):
                dist = np.sqrt((xx - px - ox) ** 2 + (yy - py - oy) ** 2)
                closer = dist < d
                d2 = np.where(closer, d, np.minimum(d2, dist))
                idx = np.where(closer, i, idx)
                d = np.where(closer, dist, d)
    return d, d2, idx


def shade(rgb, s):
    return np.clip(rgb * s[..., None], 0, 1)


def wood(rng, base, dark):
    # Grain runs along V (the haft): streaks stretched along V, a few knots, painted light ridge.
    streak = noise(rng, 60, axis=0) * 0.6 + noise(rng, 6, axis=0) * 0.4
    ring = np.sin((xx * 7 + streak * 1.6) * np.pi * 2)
    line = np.clip(1 - np.abs(np.sin((xx * 16 + streak * 3.0) * np.pi)) / 0.18, 0, 1)
    rgb = lerp(hexrgb(base), hexrgb(dark), 0.35 + 0.3 * ring + 0.12 * noise(rng, 12) + 0.45 * line)
    s = 1 + 0.12 * noise(rng, 25)
    s *= 1 + 0.18 * np.cos((xx - 0.3) * np.pi * 2)  # painted light band down one side
    for _ in range(3):
        cx, cy = rng.random(2)
        r = np.sqrt(((xx - cx) * 3.0) ** 2 + (yy - cy) ** 2 * 0.6)
        s *= 1 - 0.35 * np.exp(-(r / 0.05) ** 2)
    s *= 1 - 0.25 * np.clip(1 - np.minimum(yy, 1 - yy) / 0.06, 0, 1)  # worn dark ends
    return shade(rgb, s)


def lash(rng):
    # Rawhide thong wrapped round the haft: diagonal turns with dark gaps and a lit crown.
    phase = (xx * 1.0 + yy * 7.0) % 1.0
    crown = np.sin(phase * np.pi)
    rgb = lerp(hexrgb("#6e5232"), hexrgb("#c9a978"), crown ** 0.7)
    rgb = lerp(rgb, hexrgb("#8a6a42"), 0.25 + 0.25 * noise(rng, 8))
    s = 0.35 + 0.75 * crown ** 0.5
    fibre = noise(rng, 1, axis=1)
    return shade(rgb, s * (1 + 0.08 * fibre))


def leather(rng):
    rgb = lerp(hexrgb("#7a5233"), hexrgb("#5a3a22"), 0.5 + 0.5 * noise(rng, 18))
    s = 1 + 0.15 * noise(rng, 6) - 0.2 * (np.abs(noise(rng, 3)) < 0.04)
    stitch = (np.abs(yy - 0.12) < 0.012) & ((xx * 24) % 1 < 0.55)
    s = s * (1 - 0.45 * stitch)
    return shade(rgb, s)


def flint(rng):
    # Knapped stone: conchoidal facets (voronoi cells), each with its own tilt; lighter worked edge.
    d, d2, idx = voronoi(rng, 22)
    tilt = rng.random(22).astype(np.float32)
    facet = tilt[idx] * 0.35 + (d / (d2 + 1e-6)) * 0.25
    rgb = lerp(hexrgb("#4a4846"), hexrgb("#8c8a84"), facet + 0.15 * noise(rng, 10))
    ridge = np.clip(1 - (d2 - d) / 0.012, 0, 1) * 0.6
    edge = np.clip(1 - np.minimum(np.minimum(xx, 1 - xx), np.minimum(yy, 1 - yy)) / 0.12, 0, 1)
    s = (1 - 0.35 * ridge) * (1 + 0.35 * edge)
    return shade(rgb, s)


def bone(rng):
    rgb = lerp(hexrgb("#e6dcc2"), hexrgb("#b8a47c"), 0.35 + 0.35 * noise(rng, 20))
    pores = noise(rng, 1) > 0.55
    s = 1 - 0.18 * pores + 0.06 * noise(rng, 4, axis=0)
    centre = np.sqrt((xx - 0.5) ** 2 + (yy - 0.5) ** 2)
    rgb = lerp(rgb, hexrgb("#9c8058"), np.clip((centre - 0.35) * 2.0, 0, 1) * 0.6)  # stained socket
    return shade(rgb, s)


def copper(rng):
    d, d2, _ = voronoi(rng, 40)
    dimple = np.clip(d / 0.12, 0, 1)
    rgb = lerp(hexrgb("#9a5228"), hexrgb("#e8a462"), 0.45 + 0.25 * dimple + 0.2 * noise(rng, 20))
    patina = np.clip((noise(rng, 30) - 0.6) * 3, 0, 1) * 0.5
    rgb = lerp(rgb, hexrgb("#4f9a84"), patina)
    edge = np.clip(1 - np.minimum(np.minimum(xx, 1 - xx), np.minimum(yy, 1 - yy)) / 0.1, 0, 1)
    rgb = lerp(rgb, hexrgb("#ffd09a"), edge * 0.6)  # bright ground edge
    return rgb


def cobble(rng):
    rgb = lerp(hexrgb("#6a645c"), hexrgb("#a49a8a"), 0.5 + 0.5 * noise(rng, 30))
    speck = noise(rng, 0) > 0.7
    s = 1 - 0.2 * speck + 0.1 * noise(rng, 5)
    return shade(rgb, s)


def wicker(rng):
    # Over-under weave: horizontal weavers across vertical stakes.
    row = (yy * 12) % 1.0
    col = np.floor(xx * 10)
    over = (np.floor(yy * 12) + col) % 2
    weaver = np.sin(row * np.pi) ** 0.6
    s = 0.45 + 0.6 * weaver * (0.75 + 0.25 * over)
    s *= 1 - 0.25 * (np.abs((xx * 10) % 1 - 0.5) < 0.06)
    rgb = lerp(hexrgb("#8d6a3a"), hexrgb("#d1ad6e"), 0.4 + 0.4 * noise(rng, 6, axis=1))
    return shade(rgb, s)


def ember(rng):
    t = np.clip(1 - yy + 0.2 * noise(rng, 6), 0, 1)
    return lerp(hexrgb("#ff5a1a"), hexrgb("#ffe08a"), t)


def fur(rng):
    strands = noise(rng, 2, axis=0)
    rgb = lerp(hexrgb("#9a8a72"), hexrgb("#efe6d2"), 0.5 + 0.5 * strands)
    tips = np.clip(yy * 1.2, 0, 1)
    s = 0.7 + 0.35 * (0.5 + 0.5 * strands) - 0.15 * tips
    return shade(rgb, s)


def wool(rng):
    twill = np.sin(((xx + yy) * 40) * np.pi * 2) * 0.5 + 0.5
    rgb = lerp(hexrgb("#5e6a4a"), hexrgb("#7f8a62"), 0.4 + 0.3 * noise(rng, 20))
    s = 0.85 + 0.15 * twill
    hem = np.clip((yy - 0.9) / 0.1, 0, 1)
    s *= 1 - 0.3 * hem
    s *= 1 - 0.35 * ((np.abs(yy - 0.86) < 0.008) & ((xx * 30) % 1 < 0.5))
    return shade(rgb, s)


def straw(rng):
    a = ((xx * 6 + yy * 6) % 1.0)
    b = ((xx * 6 - yy * 6) % 1.0)
    plait = np.where((np.floor(xx * 6 + yy * 6) + np.floor(xx * 6 - yy * 6)) % 2 == 0, np.sin(a * np.pi), np.sin(b * np.pi))
    rgb = lerp(hexrgb("#a8884a"), hexrgb("#ead08a"), 0.5 * plait + 0.3 + 0.2 * noise(rng, 6))
    return shade(rgb, 0.65 + 0.4 * plait)


def palm(rng):
    # Overlapping palm leaf blades hanging along V, midrib and a dry tip.
    blade = (xx * 7) % 1.0
    rib = np.abs(blade - 0.5) < 0.04
    edge = np.sin(blade * np.pi)
    rgb = lerp(hexrgb("#3f6a2a"), hexrgb("#8ab050"), edge * 0.7 + 0.15 * noise(rng, 6, axis=0))
    rgb = lerp(rgb, hexrgb("#b89a58"), np.clip((yy - 0.75) * 3.5, 0, 1) * 0.7)
    s = (0.55 + 0.5 * edge) * (1 + 0.25 * rib)
    return shade(rgb, s)


def hide(rng):
    rgb = lerp(hexrgb("#8a6a4a"), hexrgb("#b89470"), 0.5 + 0.5 * noise(rng, 25))
    rgb = lerp(rgb, hexrgb("#5a4030"), np.clip(noise(rng, 40) - 0.4, 0, 1) * 1.2)
    s = 1 + 0.1 * noise(rng, 3)
    return shade(rgb, s)


def cord(rng):
    twist = np.sin(((yy * 30 + xx * 2) % 1.0) * np.pi)
    rgb = lerp(hexrgb("#6a5236"), hexrgb("#b89a6a"), twist)
    return rgb


PAINT = {
    "wood": lambda r: wood(r, "#9a6a3c", "#5e3c20"),
    "wood_dark": lambda r: wood(r, "#7a4e2c", "#3e2814"),
    "lash": lash, "leather": leather, "flint": flint, "bone": bone, "copper": copper,
    "cobble": cobble, "wicker": wicker, "ember": ember, "fur": fur, "wool": wool,
    "straw": straw, "palm": palm, "hide": hide, "cord": cord,
}


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "build/l7b")
    os.makedirs(root, exist_ok=True)
    atlas = np.zeros((SIZE, SIZE, 3), np.float32)
    for i, name in enumerate(TILES):
        rng = np.random.default_rng(SEED + i)
        tile = np.clip(PAINT[name](rng), 0, 1)
        row, col = divmod(i, GRID)
        atlas[row * N : (row + 1) * N, col * N : (col + 1) * N] = tile
    path = os.path.join(root, "tool_atlas.png")
    Image.fromarray((atlas * 255 + 0.5).astype(np.uint8)).save(path)
    print("wrote", path)


if __name__ == "__main__":
    main()
