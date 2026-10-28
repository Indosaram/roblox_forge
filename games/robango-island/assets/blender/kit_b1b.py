"""B1b biome-kit helpers (swamp, desert, tundra, volcano + their resource nodes).

Follows the A2b recipe (.omo/evidence/robango-durango-gap/a2b-art/REPORT.md):
- CC0 Poly Haven scans supply the surfaces (graded in sRGB pixel space toward the palette);
  geometry is procedural and sized to the asset-catalog budgets.
- 1 Blender unit = 1 stud, pivot at ground centre, +Z up in Blender (exported as +Y up).
- One kit package per biome: a 1024 RGBA vegetation atlas (+ normal), a 512 RGBA grass atlas
  (+ flat normal) and a 1024 rock atlas (albedo + normal + roughness). Alpha cards ship
  albedo + normal so the importer builds a SurfaceAppearance with AlphaMode Transparency.
- Every prop is ONE mesh object with ONE material, named by its catalog key with '.'/'-'
  replaced by '_' (e.g. veg_swamp_dead_bare), so the import yields one named MeshPart per row.

Image arrays here are Blender-ordered: row 0 is the BOTTOM of the image (matches UV v).
"""

import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector, noise

import common as C

# Albedo targets for the B1b biomes (sRGB hex), sampled from R11-3/4/6/7 with the screen
# grade (purple haze, warm cast) removed, the same way common.PALETTE was derived.
C.PALETTE.update(
    {
        "deadwood": "#8a857c",  # bleached grey dead bark (R11-3, R11-4 upper branches)
        "deadwood_dark": "#4a443d",
        "swamp_olive": "#454a2c",
        "swamp_mud": "#4a3d32",
        "sedge": "#6b6a40",
        "cactus": "#5e6b42",
        "cactus_dark": "#3c4529",
        "agave": "#6f7a64",
        "desert_twig": "#8a7f70",  # grey dry bush (R11-7)
        "desert_straw": "#a8915f",
        "sandstone": "#a6764c",
        "sand_rock": "#9a7656",
        "snow": "#d8dde0",
        "frost": "#b9c2c4",
        "frost_straw": "#a89e7e",  # frosted tussock (R11-6)
        "pine": "#33402c",
        "birch_bark": "#b7b1a4",
        "lichen": "#8c8f6a",
        "ice": "#9fb8c4",
        "char": "#231e1b",
        "ash": "#6d6862",
        "burnt_grass": "#5b3a2e",  # burnt maroon grass (R11-4)
        "basalt": "#34302e",
        "obsidian": "#1b1a1d",
        "sulfur": "#b39a3a",
        "ember": "#e0621c",
        "cycad": "#4f5a34",
        "clay_grey": "#8a8070",
        "clay_ochre": "#a07a4a",
        "rust": "#8a4a2a",
        "copper_green": "#4f7a62",
        "cattail": "#5a3a22",
        "samphire": "#5f7a3a",
    }
)

BLENDER_SRC = os.path.join(os.getcwd(), "build", "a2b", "src")


def hexrgb(h):
    h = C.PALETTE.get(h, h).lstrip("#")
    return np.array([int(h[i : i + 2], 16) / 255 for i in (0, 2, 4)], np.float32)


def key_name(key):
    return key.replace(".", "_").replace("-", "_")


# ------------------------------------------------------------------ texture painting


def load_scan(rel, size=None):
    """Load a Poly Haven 1k map -> (H, W, 4) float array (bottom row first)."""
    path = os.path.join(BLENDER_SRC, rel)
    img = C.load_image(path)
    px, w, h = C.image_array(img)
    arr = px.reshape(h, w, 4).copy()
    if size and (size != w or size != h):
        ys = (np.arange(size) * h / size).astype(int)
        xs = (np.arange(size) * w / size).astype(int)
        arr = arr[ys][:, xs]
    return arr


def grade(arr, target, strength=0.8, sat=0.6, mask=None):
    flat = arr.reshape(-1, 4)
    m = None if mask is None else mask.reshape(-1)
    C.grade_pixels(flat, target, strength=strength, sat=sat, mask=m)
    return flat.reshape(arr.shape)


def tile(size, rgb=(0, 0, 0), alpha=0.0):
    t = np.zeros((size, size, 4), np.float32)
    t[..., :3] = rgb
    t[..., 3] = alpha
    return t


def _seg(t, p0, p1, w0, w1, c0, c1, shade=0.0):
    """Draw a tapered segment p0->p1 (pixel coords, y up) with a colour ramp c0->c1."""
    h, w = t.shape[:2]
    x0 = int(max(0, math.floor(min(p0[0], p1[0]) - max(w0, w1) - 1)))
    x1 = int(min(w, math.ceil(max(p0[0], p1[0]) + max(w0, w1) + 2)))
    y0 = int(max(0, math.floor(min(p0[1], p1[1]) - max(w0, w1) - 1)))
    y1 = int(min(h, math.ceil(max(p0[1], p1[1]) + max(w0, w1) + 2)))
    if x1 <= x0 or y1 <= y0:
        return
    yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float32)
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    ll = dx * dx + dy * dy + 1e-6
    s = np.clip(((xx - p0[0]) * dx + (yy - p0[1]) * dy) / ll, 0, 1)
    px_, py_ = p0[0] + s * dx, p0[1] + s * dy
    d = np.sqrt((xx - px_) ** 2 + (yy - py_) ** 2)
    width = w0 + (w1 - w0) * s
    sel = d <= width
    if not sel.any():
        return
    col = c0[None, None, :] * (1 - s[..., None]) + c1[None, None, :] * s[..., None]
    if shade:
        side = ((xx - px_) * -dy + (yy - py_) * dx) / math.sqrt(ll)
        col = col * (1 + shade * np.clip(side / np.maximum(width, 0.5), -1, 1)[..., None])
    sub = t[y0:y1, x0:x1]
    sub[sel, :3] = np.clip(col[sel], 0, 1)
    sub[sel, 3] = 1.0


def paint_blades(t, rng, n, base, tip, height=(0.55, 0.95), width=(1.2, 2.6), lean=0.35, x_spread=0.42):
    """Grass/sedge blades rising from the bottom edge, tapered and curved."""
    s = t.shape[0]
    base, tip = hexrgb(base), hexrgb(tip)
    for _ in range(n):
        x = s * (0.5 + rng.uniform(-x_spread, x_spread))
        hgt = s * rng.uniform(*height)
        ang = rng.uniform(-lean, lean)
        curl = rng.uniform(-0.6, 0.6)
        segs = 6
        wd = rng.uniform(*width) * s / 256
        tone = rng.uniform(0.75, 1.15)
        pts = []
        for k in range(segs + 1):
            u = k / segs
            a = ang + curl * u * u
            pts.append((x + math.sin(a) * hgt * u, 2 + math.cos(a) * hgt * u))
        for k in range(segs):
            u0, u1 = k / segs, (k + 1) / segs
            c0 = (base + (tip - base) * u0) * tone
            c1 = (base + (tip - base) * u1) * tone
            _seg(t, pts[k], pts[k + 1], wd * (1 - u0 * 0.85), wd * (1 - u1 * 0.85), c0, c1, shade=0.25)
    return t


def paint_twigs(t, rng, col, tipcol, trunks=3, depth=5, spread=0.7, thick=3.2, top=0.92):
    """A twig mass (dry bush / fine dead-tree crown): recursive branching from the bottom."""
    s = t.shape[0]
    col, tipcol = hexrgb(col), hexrgb(tipcol)

    def branch(p, ang, length, wd, d):
        q = (p[0] + math.sin(ang) * length, p[1] + math.cos(ang) * length)
        q = (min(max(q[0], 2), s - 3), min(max(q[1], 2), s * top))
        u = 1 - d / depth
        _seg(t, p, q, wd, wd * 0.7, col + (tipcol - col) * u, col + (tipcol - col) * min(1, u + 0.2), shade=0.3)
        if d <= 0 or wd < 0.45:
            return
        for _ in range(rng.integers(2, 4)):
            branch(q, ang + rng.uniform(-spread, spread), length * rng.uniform(0.55, 0.8), wd * 0.66, d - 1)

    for i in range(trunks):
        x = s * (0.5 + rng.uniform(-0.18, 0.18))
        branch((x, 0.0), rng.uniform(-0.35, 0.35), s * rng.uniform(0.22, 0.32), thick * s / 256, depth)
    return t


def paint_strands(t, rng, n, col, tipcol):
    """Hanging moss strands (top edge downward)."""
    s = t.shape[0]
    col, tipcol = hexrgb(col), hexrgb(tipcol)
    for _ in range(n):
        x = s * rng.uniform(0.08, 0.92)
        ln = s * rng.uniform(0.45, 0.97)
        y = s - 1.0
        p = (x, y)
        segs = 8
        for k in range(segs):
            q = (p[0] + rng.uniform(-3, 3) * s / 256, p[1] - ln / segs)
            u = (k + 1) / segs
            _seg(t, p, q, 1.6 * s / 256 * (1 - 0.6 * u), 1.2 * s / 256 * (1 - 0.6 * u), col, col + (tipcol - col) * u)
            p = q
    return t


def paint_blotch(t, rng, col, col2, scale=6.0, cover=0.55, seed=0):
    """Irregular mat (lichen, moss, sulfur crust, ash, snow patch): noise-thresholded disc."""
    s = t.shape[0]
    yy, xx = np.mgrid[0:s, 0:s].astype(np.float32) / s
    r = np.sqrt((xx - 0.5) ** 2 + (yy - 0.5) ** 2) * 2
    off = Vector((seed * 13.1, seed * 7.7, 0))
    g = min(s, 128)
    lin = np.linspace(0, 1, g)
    nz = np.array([[noise.noise(Vector((x * scale, y * scale, 0)) + off) for x in lin] for y in lin], np.float32)
    fine = np.array([[noise.noise(Vector((x * scale * 5, y * scale * 5, 3)) + off) for x in lin] for y in lin], np.float32)
    idx = (np.arange(s) * (g - 1) / (s - 1))
    i0 = np.floor(idx).astype(int)
    i1 = np.minimum(i0 + 1, g - 1)
    fr = (idx - i0).astype(np.float32)

    def up(a):
        a = a[i0] * (1 - fr)[:, None] + a[i1] * fr[:, None]
        return a[:, i0] * (1 - fr)[None, :] + a[:, i1] * fr[None, :]

    nz, fine = up(nz), up(fine)
    field = nz * 0.7 + fine * 0.3 + (cover - r)
    m = field > 0
    c1, c2 = hexrgb(col), hexrgb(col2)
    mixv = np.clip(fine * 1.5 + 0.5, 0, 1)[..., None]
    t[m, :3] = (c1 * (1 - mixv) + c2 * mixv)[m]
    t[m, 3] = 1.0
    return t


def paint_dots(t, rng, n, col, col2, rmin=2.0, rmax=7.0, region=(0.05, 0.95)):
    """Pebbles / cinders / charcoal chunks: shaded discs."""
    s = t.shape[0]
    c1, c2 = hexrgb(col), hexrgb(col2)
    yy, xx = np.mgrid[0:s, 0:s].astype(np.float32)
    for _ in range(n):
        cx, cy = s * rng.uniform(*region), s * rng.uniform(*region)
        r = rng.uniform(rmin, rmax) * s / 256
        d = np.sqrt(((xx - cx) / 1.2) ** 2 + (yy - cy) ** 2)
        m = d < r
        lit = np.clip(((yy - cy) - (xx - cx) * 0.4) / max(r, 1), -1, 1)
        tone = rng.uniform(0.0, 1.0)
        base = c1 * (1 - tone) + c2 * tone
        t[m, :3] = np.clip(base[None, :] * (0.8 + 0.3 * lit[m, None]), 0, 1)
        t[m, 3] = 1.0
    return t


def paint_leaf(t, col, tipcol, spine=None, waist=0.32, teeth=0):
    """One pointed succulent/agave leaf filling the tile (base at bottom)."""
    s = t.shape[0]
    yy, xx = np.mgrid[0:s, 0:s].astype(np.float32) / s
    v = yy
    half = waist * np.sin(np.clip(v, 0, 1) * math.pi * 0.9 + 0.12) * (1 - v) ** 0.35
    if teeth:
        half = half * (1 + 0.08 * np.sign(np.sin(v * teeth * math.pi)))
    m = np.abs(xx - 0.5) < half
    c1, c2 = hexrgb(col), hexrgb(tipcol)
    edge = np.clip(np.abs(xx - 0.5) / np.maximum(half, 1e-3), 0, 1)
    col_ = c1[None, None, :] * (1 - v[..., None]) + c2[None, None, :] * v[..., None]
    col_ = col_ * (1.05 - 0.3 * edge[..., None])
    t[m, :3] = col_[m]
    t[m, 3] = 1.0
    if spine is not None:
        sp = (np.abs(xx - 0.5) < 0.012) & m
        t[sp, :3] = hexrgb(spine)
    return t


def paint_frond(t, rng, rachis, leaflet, tip):
    """Cycad frond: central rachis with paired stiff leaflets (base at bottom)."""
    s = t.shape[0]
    r, lf, tp = hexrgb(rachis), hexrgb(leaflet), hexrgb(tip)
    _seg(t, (s / 2, 0), (s / 2, s * 0.98), 2.6 * s / 256, 1.0 * s / 256, r, r)
    for k in range(26):
        u = 0.06 + k / 28
        y = s * u
        ln = s * 0.42 * math.sin(math.pi * min(1, u * 1.05)) + 4
        for sgn in (-1, 1):
            q = (s / 2 + sgn * ln, y + ln * 0.45)
            c = lf + (tp - lf) * u
            _seg(t, (s / 2, y), q, 2.4 * s / 256, 0.9 * s / 256, c * rng.uniform(0.85, 1.1), c, shade=0.3)
    return t


def cactus_tile(size, rng):
    """Opaque ribbed cactus skin: vertical rib light/dark bands + areole spine dots."""
    t = tile(size, alpha=1.0)
    xx = np.arange(size, dtype=np.float32) / size
    rib = 0.5 + 0.5 * np.cos(xx * math.pi * 2 * 8)
    c1, c2 = hexrgb("cactus_dark"), hexrgb("cactus")
    t[..., :3] = (c1[None, :] * (1 - rib[:, None]) + c2[None, :] * rib[:, None])[None, :, :]
    nz = rng.uniform(0.9, 1.08, (size, size, 1)).astype(np.float32)
    t[..., :3] *= nz
    for k in range(8):
        x = (k + 0.5) / 8 * size
        for y in np.arange(4, size, size / 14):
            _seg(t, (x - 1.5, y), (x + 1.5, y + 1), 1.6, 1.2, hexrgb("#b8ae8a"), hexrgb("#d6ccb0"))
    return t


def snow_overlay(arr, amount=0.55, rng=None):
    """Whiten the upper-facing half of every opaque texel cluster (snow load on needles)."""
    h = arr.shape[0]
    rng = rng or np.random.default_rng(0)
    v = (np.arange(h, dtype=np.float32) / h)[:, None]
    m = arr[..., 3] > 0.5
    lum = arr[..., :3].mean(-1)
    p = np.clip((lum - lum[m].mean()) * 3 + amount + (v - 0.5) * 0.6, 0, 1)
    p = p * (rng.random(arr.shape[:2]) < 0.85)
    snow = hexrgb("snow")
    arr[..., :3] = arr[..., :3] * (1 - p[..., None]) + snow[None, None, :] * p[..., None]
    return arr


def leaf_cluster_tile(size, rng, target, sat=0.6, leaves=16):
    """Stamp scanned shrub_04 single leaves (CC0) into one clustered alpha tile."""
    diff = load_scan(os.path.join("shrub_04", "textures", "shrub_04_diff_1k.jpg"))
    alpha = load_scan(os.path.join("shrub_04", "textures", "shrub_04_alpha_1k.png"))
    m = alpha[..., 0] > 0.5
    diff = grade(diff, target, strength=0.8, sat=sat, mask=m)
    diff[..., 3] = m.astype(np.float32)
    # leaf boxes (Blender rows: bottom-up), from gen_berrybush.LEAF_UV (image px, y down)
    boxes = [(135, 100, 232, 330), (540, 75, 628, 338), (440, 410, 552, 645), (618, 395, 712, 598), (238, 655, 338, 940), (383, 712, 492, 952), (562, 698, 652, 905), (52, 735, 152, 962)]
    out = tile(size)
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    for k in range(leaves):
        x0, y0, x1, y1 = boxes[rng.integers(len(boxes))]
        leaf = diff[1024 - y1 : 1024 - y0, x0:x1]
        sc = size * 0.42 / leaf.shape[0]
        lh, lw = leaf.shape[0] * sc, leaf.shape[1] * sc
        ang = rng.uniform(-1.4, 1.4)
        ca, sa = math.cos(ang), math.sin(ang)
        cx, cy = size / 2 + rng.uniform(-0.15, 0.15) * size, size * 0.35 + rng.uniform(-0.15, 0.2) * size
        dx, dy = xx - cx, yy - cy
        lx = ca * dx - sa * dy + lw / 2
        ly = sa * dx + ca * dy
        ok = (lx >= 0) & (lx < lw) & (ly >= 0) & (ly < lh)
        vals = leaf[(ly[ok] / sc).astype(int).clip(0, leaf.shape[0] - 1), (lx[ok] / sc).astype(int).clip(0, leaf.shape[1] - 1)]
        sel = vals[:, 3] > 0.5
        tgt = out[ok]
        tgt[sel, :3] = vals[sel, :3] * (0.72 + 0.3 * k / leaves)
        tgt[sel, 3] = 1.0
        out[ok] = tgt
    return out


def scan_tile(rel, size, target, strength=0.8, sat=0.6):
    t = load_scan(rel, size)
    t = grade(t, target, strength=strength, sat=sat)
    t[..., 3] = 1.0
    return t


class Atlas:
    """A square RGBA atlas packed from tiles; tiles are placed at explicit pixel cells."""

    def __init__(self, name, size):
        self.name, self.size = name, size
        self.px = np.zeros((size, size, 4), np.float32)
        self.nrm = np.zeros((size, size, 4), np.float32)
        self.nrm[:] = (0.5, 0.5, 1.0, 1.0)
        self.rough = np.full((size, size, 4), 0.85, np.float32)
        self.rough[..., 3] = 1.0
        self.rects = {}

    def put(self, key, x, y, t, normal=None, rough=None, inset=2):
        h, w = t.shape[:2]
        self.px[y : y + h, x : x + w] = t
        if normal is not None:
            self.nrm[y : y + h, x : x + w] = normal
        if rough is not None:
            self.rough[y : y + h, x : x + w] = rough
        s = self.size
        self.rects[key] = ((x + inset) / s, (y + inset) / s, (x + w - inset) / s, (y + h - inset) / s)
        return self.rects[key]

    def mean_hex(self, key):
        u0, v0, u1, v1 = self.rects[key]
        s = self.size
        reg = self.px[int(v0 * s) : int(v1 * s), int(u0 * s) : int(u1 * s)].reshape(-1, 4)
        m = reg[:, 3] > 0.5
        c = (reg[m, :3].mean(0) * 255).astype(int) if m.any() else np.zeros(3, int)
        return "#%02x%02x%02x" % tuple(c)

    def save(self, outdir, alpha=True, with_rough=False):
        px = self.px.reshape(-1, 4).copy()
        if not alpha:
            px[:, 3] = 1.0
        img, path = C.save_rgba(f"{self.name}_albedo", outdir, self.size, self.size, px)
        n_img, n_path = C.save_rgba(f"{self.name}_normal", outdir, self.size, self.size, self.nrm.reshape(-1, 4).copy())
        n_img.colorspace_settings.name = "Non-Color"
        paths = {"albedo": path, "normal": n_path}
        r_img = None
        if with_rough:
            r_img, r_path = C.save_rgba(f"{self.name}_rough", outdir, self.size, self.size, self.rough.reshape(-1, 4).copy())
            r_img.colorspace_settings.name = "Non-Color"
            paths["roughness"] = r_path
        if alpha:
            mat = C.card_material(self.name + "_mat", img, n_img)
        else:
            mat = C.image_material(self.name + "_mat", img, n_img, r_img)
        return mat, paths


def scan_normal(rel, size):
    n = load_scan(rel, size)
    n[..., 3] = 1.0
    return n


def scan_rough(rel, size):
    r = load_scan(rel, size)
    r[..., 3] = 1.0
    return r


# ------------------------------------------------------------------ geometry


class Builder:
    """Accumulates geometry for one prop into one bmesh with a UV layer."""

    def __init__(self):
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.new("UVMap")

    def tube(self, pts, radii, rect, sides=6, v_scale=0.25, cap=False, rib=0.0, ribs=0, jitter=0.0, rng=None, cap_rect=None):
        """Generalised cylinder along pts; UV u wraps around inside rect, v runs along length."""
        u0, v0, u1, v1 = rect
        rings = []
        n = len(pts)
        acc = 0.0
        prev_side = None
        for i, p in enumerate(pts):
            t = (pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]).normalized()
            ref = Vector((0, 0, 1)) if abs(t.z) < 0.95 else Vector((1, 0, 0))
            side = t.cross(ref).normalized() if prev_side is None else (prev_side - t * prev_side.dot(t)).normalized()
            prev_side = side
            up = side.cross(t).normalized()
            if i > 0:
                acc += (pts[i] - pts[i - 1]).length
            ring = []
            for k in range(sides + 1):
                a = 2 * math.pi * (k % sides) / sides
                r = radii[i]
                if ribs:
                    r *= 1 + rib * math.cos(a * ribs)
                if jitter and rng is not None:
                    r *= 1 + jitter * rng.uniform(-1, 1)
                ring.append((self.bm.verts.new(p + (side * math.cos(a) + up * math.sin(a)) * r), k / sides, acc))
            rings.append(ring)
        total = max(acc, 1e-6)
        vmax = min(1.0, total * v_scale)
        for i in range(n - 1):
            for k in range(sides):
                a, b = rings[i][k], rings[i][k + 1]
                c, d = rings[i + 1][k + 1], rings[i + 1][k]
                f = self.bm.faces.new((a[0], b[0], c[0], d[0]))
                for loop, item in zip(f.loops, (a, b, c, d)):
                    vv = item[2] / total * vmax
                    loop[self.uv].uv = (u0 + (u1 - u0) * item[1], v0 + (v1 - v0) * vv)
        if cap:
            cu0, cv0, cu1, cv1 = cap_rect or rect
            for ring, rev in ((rings[-1], False), (rings[0], True)):
                vs = [x[0] for x in ring[:-1]]
                if rev:
                    vs = vs[::-1]
                f = self.bm.faces.new(vs)
                for loop, k in zip(f.loops, range(len(vs))):
                    a = 2 * math.pi * k / len(vs)
                    loop[self.uv].uv = ((cu0 + cu1) / 2 + math.cos(a) * (cu1 - cu0) / 2, (cv0 + cv1) / 2 + math.sin(a) * (cv1 - cv0) / 2)
        return rings

    def card(self, base, up, side, w, h, rect, bend=None, rows=2):
        bend = bend if bend is not None else Vector((0, 0, 0))
        C.bent_card(self.bm, self.uv, base, up.normalized(), side.normalized(), w, h, rect, bend=bend, rows=rows)

    def quad(self, corners, rect):
        C.quad(self.bm, self.uv, corners, rect)

    def crossed(self, base, w, h, rect, n=2, rot=0.0, lean=None, rows=2, bend=0.0):
        for k in range(n):
            a = rot + math.pi * k / n
            side = Vector((math.cos(a), math.sin(a), 0))
            up = Vector((0, 0, 1)) if lean is None else (Vector((0, 0, 1)) + lean).normalized()
            out = Vector((-side.y, side.x, 0))
            self.card(base, up, side, w, h, rect, bend=out * bend if bend else None, rows=rows)

    def disc(self, center, radius, rect, segs=12, rings=2, rng=None, lift=0.04):
        """Flat ground decal (mat / patch): fan rings, slightly domed so it never z-fights."""
        u0, v0, u1, v1 = rect
        cu, cv, ru, rv = (u0 + u1) / 2, (v0 + v1) / 2, (u1 - u0) / 2, (v1 - v0) / 2
        cen = self.bm.verts.new(center + Vector((0, 0, lift * 1.5)))
        prev = None
        all_rings = []
        for r_i in range(1, rings + 1):
            fr = r_i / rings
            ring = []
            for k in range(segs):
                a = 2 * math.pi * k / segs
                jit = 1 + (rng.uniform(-0.12, 0.12) if rng is not None else 0)
                p = center + Vector((math.cos(a) * radius * fr * jit, math.sin(a) * radius * fr * jit, lift * (1.5 - fr)))
                ring.append((self.bm.verts.new(p), cu + math.cos(a) * ru * fr, cv + math.sin(a) * rv * fr))
            all_rings.append(ring)
        first = all_rings[0]
        for k in range(segs):
            a, b = first[k], first[(k + 1) % segs]
            f = self.bm.faces.new((cen, a[0], b[0]))
            for loop, uvv in zip(f.loops, ((cu, cv), (a[1], a[2]), (b[1], b[2]))):
                loop[self.uv].uv = uvv
        for i in range(len(all_rings) - 1):
            A, B = all_rings[i], all_rings[i + 1]
            for k in range(segs):
                q = (A[k], A[(k + 1) % segs], B[(k + 1) % segs], B[k])
                f = self.bm.faces.new([x[0] for x in q])
                for loop, item in zip(f.loops, q):
                    loop[self.uv].uv = (item[1], item[2])

    def rock(self, center, size, rect, rng, sub=3, rough=0.35, flat=0.0, strata=0.0, scale=1.6, shard=False):
        """Noise-displaced icosphere with box-projected UVs into rect. size = (x, y, z) radii."""
        res = bmesh.ops.create_icosphere(self.bm, subdivisions=sub, radius=1.0, matrix=Matrix.Identity(4))
        vs = res["verts"]
        seed = Vector((rng.uniform(0, 100), rng.uniform(0, 100), rng.uniform(0, 100)))
        for v in vs:
            d = v.co.normalized()
            n1 = noise.noise(d * scale + seed)
            n2 = noise.noise(d * scale * 3.1 + seed * 1.7)
            r = 1 + rough * (n1 * 0.75 + n2 * 0.25)
            p = Vector((d.x * size[0], d.y * size[1], d.z * size[2])) * r
            if strata:
                p.z = round(p.z / strata) * strata * 0.6 + p.z * 0.4
            if flat and p.z < 0:
                p.z *= flat
            v.co = center + p
        faces = {f for v in vs for f in v.link_faces}
        self._box_uv(faces, rect, span=max(size) * 2.2)
        return vs

    def _box_uv(self, faces, rect, span):
        u0, v0, u1, v1 = rect
        for f in faces:
            nrm = f.normal
            ax = max(range(3), key=lambda i: abs(nrm[i]))
            for loop in f.loops:
                c = loop.vert.co
                a, b = [(c.y, c.z), (c.x, c.z), (c.x, c.y)][ax]
                uu = (a / span + 0.5) % 1.0
                vv = (b / span + 0.5) % 1.0
                loop[self.uv].uv = (u0 + (u1 - u0) * uu, v0 + (v1 - v0) * vv)

    def prism(self, base, radius, height, sides, rect, rng, tilt=None, top_jit=0.15):
        """A polygonal column (basalt column / ice shard / sandstone layer)."""
        u0, v0, u1, v1 = rect
        axis = Vector((0, 0, 1)) if tilt is None else (Vector((0, 0, 1)) + tilt).normalized()
        ref = Vector((1, 0, 0))
        sx = axis.cross(ref).normalized()
        sy = axis.cross(sx).normalized()
        bot, top = [], []
        for k in range(sides):
            a = 2 * math.pi * k / sides + rng.uniform(-0.1, 0.1)
            off = (sx * math.cos(a) + sy * math.sin(a)) * radius
            bot.append(self.bm.verts.new(base + off))
            top.append(self.bm.verts.new(base + off * 0.92 + axis * height * (1 + rng.uniform(-top_jit, top_jit))))
        for k in range(sides):
            k2 = (k + 1) % sides
            f = self.bm.faces.new((bot[k], bot[k2], top[k2], top[k]))
            ua, ub = u0 + (u1 - u0) * k / sides, u0 + (u1 - u0) * (k + 1) / sides
            for loop, uvv in zip(f.loops, ((ua, v0), (ub, v0), (ub, v1), (ua, v1))):
                loop[self.uv].uv = uvv
        f = self.bm.faces.new(top)
        for loop in f.loops:
            c = loop.vert.co - base
            loop[self.uv].uv = (u0 + (u1 - u0) * (0.5 + c.x / (radius * 4)), v0 + (v1 - v0) * (0.5 + c.y / (radius * 4)))

    def finish(self, name, mat, offset=Vector((0, 0, 0))):
        bmesh.ops.triangulate(self.bm, faces=self.bm.faces[:])
        obj = C.mesh_object(name, self.bm)
        obj.data.materials.append(mat)
        obj.location = offset
        C.finish_mesh(obj, smooth=False)
        return obj


def grow_branches(b, rng, start, direction, length, radius, rect, depth, spread=0.55, sides=5, segs=3, droop=0.0, tips=None, min_r=0.05, gnarl=0.15):
    """Recursive branch skeleton of tapered tubes. Collects branch tips (pos, dir) in `tips`."""
    pts, radii = [start], [radius]
    d = direction.normalized()
    p = start
    for k in range(segs):
        d = (d + Vector((rng.uniform(-gnarl, gnarl), rng.uniform(-gnarl, gnarl), -droop))).normalized()
        p = p + d * (length / segs)
        pts.append(p)
        radii.append(radius * (1 - 0.55 * (k + 1) / segs))
    b.tube(pts, radii, rect, sides=sides, v_scale=0.08)
    end_r = radii[-1]
    if depth <= 0 or end_r < min_r:
        if tips is not None:
            tips.append((p, d))
        return
    n = rng.integers(2, 4)
    for i in range(n):
        a = rng.uniform(0, 2 * math.pi)
        side = Vector((math.cos(a), math.sin(a), 0))
        nd = (d + side * rng.uniform(spread * 0.6, spread * 1.4)).normalized()
        frac = rng.uniform(0.55, 1.0)
        bp = pts[-1] if i == 0 else pts[max(1, int(len(pts) * frac) - 1)]
        grow_branches(b, rng, bp, nd, length * rng.uniform(0.55, 0.75), end_r * rng.uniform(0.8, 1.0), rect, depth - 1, spread, max(3, sides - 1), segs, droop, tips, min_r, gnarl)


def grass_cluster(b, rng, rects, height, radius, pairs, seed_heads=0, skirt=0, width=None):
    """A grass clump of crossed bent cards (A2b grass layout)."""
    width = width or height * 0.75
    for i in range(pairs):
        a = rng.uniform(0, 2 * math.pi)
        r = radius * math.sqrt(rng.random())
        base = Vector((math.cos(a) * r, math.sin(a) * r, 0))
        h = height * rng.uniform(0.75, 1.1)
        lean = Vector((rng.uniform(-0.25, 0.25), rng.uniform(-0.25, 0.25), 0))
        rect = rects[i % len(rects)]
        b.crossed(base, width * rng.uniform(0.8, 1.15), h, rect, n=2, rot=rng.uniform(0, math.pi), lean=lean, rows=1, bend=0.0)
    for i in range(skirt):
        a = 2 * math.pi * i / max(skirt, 1)
        side = Vector((math.cos(a + 1.57), math.sin(a + 1.57), 0))
        out = Vector((math.cos(a), math.sin(a), 0))
        base = out * radius * 0.6
        b.card(base, (out * 0.9 + Vector((0, 0, 1))), side, width * 0.6, height * 0.45, rects[i % len(rects)], rows=1)


def node_states(full_builder_fn, dep_builder_fn, key, mat, x):
    full = full_builder_fn().finish(key_name(key) + "_full", mat, Vector((x, 0, 0)))
    dep = dep_builder_fn().finish(key_name(key) + "_depleted", mat, Vector((x, 8, 0)))
    return [full, dep]


def prop_sheet(name, outdir, objects):
    """One textured workbench preview per prop (others hidden), for the report."""
    paths = []
    for o in objects:
        for other in objects:
            other.hide_render = other is not o
        paths.append(C.preview(f"{name}__{o.name}", outdir, [o]))
    for o in objects:
        o.hide_render = False
    return paths


def export_package(name, outdir, objects, extra=None):
    """Silhouette sheet + preview + FBX of the whole package; prints a JSON-ish report line."""
    sil = C.silhouette(name, outdir, objects)
    pv = C.preview(name, outdir, objects)
    sheet = prop_sheet(name, outdir, objects)
    fbx = C.export_fbx(name, outdir, objects)
    rows = {o.name: C.triangles(o) for o in objects}
    line = {"package": name, "fbx": fbx, "bytes": os.path.getsize(fbx), "preview": pv, "sheet": len(sheet), "silhouettes": sil, "rows": rows}
    if extra:
        line.update(extra)
    print("B1BKIT", repr(line))
    return line


def row_layout(objects, gap=4.0):
    """Lay props out along +X by their bounds so the package import does not overlap them."""
    x = 0.0
    for o in objects:
        bb = [o.matrix_world @ Vector(c) for c in o.bound_box]
        lo = min(v.x for v in bb) - o.location.x
        hi = max(v.x for v in bb) - o.location.x
        o.location.x = x - lo
        x += hi - lo + gap
    bpy.context.view_layer.update()


# ------------------------------------------------------------------ L3 vegetation v2 bridge
# Clustered branch-card crowns (kitlib.branch_tree / sprig) for the B1b builders.

SHRUB4_BOXES = [(135, 100, 232, 330), (540, 75, 628, 338), (440, 410, 552, 645), (618, 395, 712, 598), (238, 655, 338, 940), (383, 712, 492, 952), (562, 698, 652, 905), (52, 735, 152, 962)]


def sprig_tile(size, rng, target, twig, sat=0.55, **kw):
    """Branch-card tile: twig + side twigs + scanned shrub_04 leaves (CC0), base at the bottom."""
    import kitlib

    diff = load_scan(os.path.join("shrub_04", "textures", "shrub_04_diff_1k.jpg"))
    alpha = load_scan(os.path.join("shrub_04", "textures", "shrub_04_alpha_1k.png"))
    m = alpha[..., 0] > 0.5
    diff = grade(diff, target, strength=0.8, sat=sat, mask=m)
    diff[..., 3] = m.astype(np.float32)
    leaves = [diff[1024 - y1 : 1024 - y0, x0:x1].copy() for x0, y0, x1, y1 in SHRUB4_BOXES]
    return kitlib.sprig(rng, leaves, hexrgb(twig), size=size, **kw)


def hero(b, rng, bark, rects, height, trunk_r, crown, **kw):
    """Clustered branch-card tree on a Builder (kitlib.branch_tree)."""
    import kitlib

    return kitlib.branch_tree(lambda pts, radii, sides: b.tube(pts, radii, bark, sides=sides, v_scale=0.05), b.quad, rng, height, trunk_r, crown, rects, **kw)


def bush(b, rng, rx, rz, clusters, cards, card, rects):
    import kitlib

    return kitlib.clustered_shrub(b.quad, rng, rx, rz, clusters, cards, card, rects)
