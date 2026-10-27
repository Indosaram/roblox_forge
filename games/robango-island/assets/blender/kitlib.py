"""Shared builders for the Wave B biome-kit and node generators (B1a).

Recipe: .omo/evidence/robango-durango-gap/a2b-art/REPORT.md (A2b).
- Units: 1 Blender unit = 1 stud (asset catalog section 0); pivot at ground centre.
- Albedo atlases are sRGB RGBA with binary alpha, bled (common.bleed); every card
  material ships albedo + normal, so the Roblox importer builds a SurfaceAppearance
  with AlphaMode Transparency.
- Scanned CC0 plant atlases are used only as texture sources, never as meshes.
- Rock scans: weld (remove_doubles 0.002) and strip UVs before collapse decimation,
  then selected-to-active bake.
"""

import math
import os
import random

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

import common as C

F32 = np.float32


def hexrgb(name):
    h = C.PALETTE.get(name, name).lstrip("#")
    return np.array([int(h[i : i + 2], 16) / 255 for i in (0, 2, 4)], F32)


def src(*parts):
    return os.path.join(C.SRC_DIR, *parts)


def load_px(path, non_color=False):
    img = C.load_image(path, non_color)
    a, w, h = C.image_array(img)
    return a.reshape(h, w, 4).copy()


def resize(a, h, w):
    """Area-ish resize by nearest sampling of a pre-blurred image (h, w, 4)."""
    sh, sw = a.shape[:2]
    if sh >= 2 * h and sw >= 2 * w:
        fy, fx = sh // h, sw // w
        a = a[: h * fy, : w * fx].reshape(h, fy, w, fx, 4).mean((1, 3))
        return a.astype(F32)
    yi = (np.arange(h) * sh / h).astype(int).clip(0, sh - 1)
    xi = (np.arange(w) * sw / w).astype(int).clip(0, sw - 1)
    return a[yi][:, xi].astype(F32)


def crop(path, alpha_path, rect):
    """Pixel rect (x0, y0, x1, y1), y down as seen in an image viewer -> bottom-up RGBA patch."""
    img = load_px(path)
    h = img.shape[0]
    x0, y0, x1, y1 = rect
    patch = img[h - y1 : h - y0, x0:x1].copy()
    if alpha_path:
        al = load_px(alpha_path, True)
        patch[..., 3] = (al[h - y1 : h - y0, x0:x1, 0] > 0.5).astype(F32)
    else:
        patch[..., 3] = 1.0
    return patch


def grade(tile, target, strength=0.75, sat=0.6):
    flat = tile.reshape(-1, 4)
    mask = flat[:, 3] > 0.5
    if mask.any():
        C.grade_pixels(flat, target, strength=strength, sat=sat, mask=mask)
    return flat.reshape(tile.shape)


def noise2(rng, h, w, cell):
    """Smooth value noise in 0..1, (h, w)."""
    gh, gw = h // cell + 2, w // cell + 2
    g = rng.random((gh, gw)).astype(F32)
    y = np.arange(h) / cell
    x = np.arange(w) / cell
    y0, x0 = y.astype(int), x.astype(int)
    fy, fx = (y - y0)[:, None], (x - x0)[None, :]
    fy, fx = fy * fy * (3 - 2 * fy), fx * fx * (3 - 2 * fx)
    a = g[y0][:, x0]
    b = g[y0][:, x0 + 1]
    c = g[y0 + 1][:, x0]
    d = g[y0 + 1][:, x0 + 1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def stamp(tile, leaf, cx, cy, ang, height, shade=1.0):
    """Rotate-and-scale a bottom-up RGBA leaf (base at row 0) into tile at (cx, cy)."""
    th, tw = tile.shape[:2]
    sc = height / leaf.shape[0]
    lh, lw = max(4, int(leaf.shape[0] * sc)), max(3, int(leaf.shape[1] * sc))
    small = resize(leaf, lh, lw)
    small[..., 3] = (small[..., 3] > 0.5).astype(F32)
    ca, sa = math.cos(ang), math.sin(ang)
    yy, xx = np.mgrid[0:th, 0:tw].astype(F32)
    dx, dy = xx - cx, yy - cy
    lx = ca * dx + sa * dy + lw / 2
    ly = -sa * dx + ca * dy
    ok = (lx >= 0) & (lx < lw) & (ly >= 0) & (ly < lh)
    vals = small[ly[ok].astype(int), lx[ok].astype(int)]
    sel = vals[:, 3] > 0.5
    tgt = tile[ok]
    tgt[sel, :3] = vals[sel, :3] * shade
    tgt[sel, 3] = 1.0
    tile[ok] = tgt


# ------------------------------------------------------------------ painted tiles
def blades(w, h, rng, n, base, mid, tip, wmin=2.2, wmax=4.0, lean=0.3, heads=None, hmin=0.55):
    """Thin arching blades rooted along the bottom (A2b blades, ~40% narrower, straw tips)."""
    out = np.zeros((h, w, 4), F32)
    for _ in range(n):
        x0 = rng.uniform(0.3, 0.7) * w
        height = rng.uniform(hmin, 0.98) * h
        bend = rng.uniform(-lean, lean) * w
        w0 = rng.uniform(wmin, wmax)
        dry = rng.uniform(0.2, 1.0)
        steps = int(height)
        for s in range(steps):
            t = s / steps
            x = x0 + bend * t * t
            hw = w0 * (1 - t) ** 0.9 + 0.45
            xa, xb = int(max(0, x - hw)), int(min(w, x + hw + 1))
            if xa >= xb:
                continue
            col = base + (mid - base) * min(1, t * 1.7)
            col = col * (1 - dry * t * t) + tip * (dry * t * t)
            shade = 1.0 - 0.3 * np.abs(np.arange(xa, xb) - x) / max(hw, 1)
            out[s, xa:xb, :3] = col[None, :] * shade[:, None]
            out[s, xa:xb, 3] = 1.0
        if heads is not None and rng.random() < 0.35:
            # Seed head: a slim spindle of grains at the blade tip.
            for g in range(int(h * 0.12)):
                y = steps - 1 - g
                x = x0 + bend + rng.normal(0, 1.2)
                if 0 <= y < h and 0 <= int(x) < w:
                    out[y, max(0, int(x) - 1) : int(x) + 2, :3] = heads * rng.uniform(0.8, 1.1)
                    out[y, max(0, int(x) - 1) : int(x) + 2, 3] = 1.0
    out[..., :3] += rng.normal(0, 0.02, (h, w, 1)).astype(F32) * out[..., 3:4]
    return np.clip(out, 0, 1)


def frond(w, h, light, dark, rng, broken=0.0, spacing=13.0):
    """Pinnate palm frond, rachis vertical, base at the bottom (from gen_palm_v2)."""
    y, x = np.mgrid[0:h, 0:w].astype(F32)
    v = y / h
    d = np.abs(x - w / 2)
    y0 = y - d * 0.55
    phase = (y0 / spacing) % 1.0
    v0 = np.clip(y0 / h, 0, 1)
    length = (w * 0.48) * np.sin(np.pi * np.clip(v0 * 1.05, 0.04, 1.0)) ** 0.7
    length *= 1.0 - 0.25 * ((np.floor(y0 / spacing) * 7.31) % 1.0)
    t = d / np.maximum(length, 1)
    width = 0.7 * (1 - t) ** 0.5
    leaf = (phase < width) & (t < 1.0) & (y0 > h * 0.05)
    if broken:
        leaf &= ~(((np.floor(y0 / spacing) * 3.7) % 1.0) < broken)
    rachis = d < 2.5 * (1 - 0.7 * v)
    shade = np.clip(0.55 + 0.45 * (1 - phase / np.maximum(width, 1e-3)), 0, 1)[..., None]
    col = dark + (light - dark) * shade
    col = col * (0.85 + 0.15 * t[..., None])
    col = np.clip(col + rng.normal(0, 0.03, (h, w, 1)).astype(F32), 0, 1)
    col[rachis] = dark * 0.9
    out = np.zeros((h, w, 4), F32)
    out[..., :3] = col
    out[..., 3] = (leaf | rachis).astype(F32)
    return out


def fan(w, h, light, dark, rng):
    """Ragged fan-palm leaf: radial segments from the bottom centre over ~160 degrees."""
    y, x = np.mgrid[0:h, 0:w].astype(F32)
    dx, dy = x - w / 2, y + 2
    r = np.sqrt(dx * dx + dy * dy) / (h * 0.98)
    a = np.arctan2(dx, dy)
    seg = 22
    k = (a / math.radians(80) + 1) / 2 * seg
    frac = k % 1.0
    idx = np.floor(k)
    ragged = 0.82 + 0.18 * ((idx * 5.13) % 1.0)
    leaf = (np.abs(a) < math.radians(80)) & (r < ragged) & (np.abs(frac - 0.5) < 0.42 - 0.25 * np.clip(r - 0.6, 0, 1))
    leaf &= r > 0.05
    shade = (0.6 + 0.4 * (1 - np.abs(frac - 0.5) * 2))[..., None]
    col = dark + (light - dark) * shade
    col = np.clip(col + rng.normal(0, 0.03, (h, w, 1)).astype(F32), 0, 1)
    out = np.zeros((h, w, 4), F32)
    out[..., :3] = col
    out[..., 3] = leaf.astype(F32)
    return out


def flowers(w, h, rng, colors, n=14, leafcol=None):
    out = np.zeros((h, w, 4), F32)
    yy, xx = np.mgrid[0:h, 0:w].astype(F32)
    if leafcol is not None:
        out[...] = 0
        g = blades(w, h, rng, 26, leafcol * 0.7, leafcol, leafcol * 1.1, 1.6, 3.0, 0.25, hmin=0.3)
        out = g
    for _ in range(n):
        cx, cy = rng.uniform(0.15, 0.85) * w, rng.uniform(0.35, 0.92) * h
        rad = rng.uniform(0.045, 0.08) * w
        col = colors[rng.integers(len(colors))]
        ang = np.arctan2(yy - cy, xx - cx)
        dist = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
        petal = dist < rad * (0.65 + 0.35 * np.abs(np.cos(ang * 2.5)))
        out[petal, :3] = col * (0.75 + 0.25 * (1 - dist[petal] / rad))[:, None]
        out[petal, 3] = 1
        centre = dist < rad * 0.25
        out[centre, :3] = hexrgb("straw") * 1.1
    return np.clip(out, 0, 1)


def bracts(w, h, rng, red, stem):
    """Red ginger: stacked red bracts on a stem, base at the bottom."""
    out = np.zeros((h, w, 4), F32)
    yy, xx = np.mgrid[0:h, 0:w].astype(F32)
    cx = w / 2
    stemmask = (np.abs(xx - cx) < 2.5) & (yy < h * 0.55)
    out[stemmask, :3] = stem
    out[stemmask, 3] = 1
    for i in range(9):
        cy = h * (0.45 + i * 0.055)
        side = -1 if i % 2 else 1
        ex, ey = cx + side * w * 0.07, cy
        m = ((xx - ex) / (w * 0.16)) ** 2 + ((yy - ey) / (h * 0.06)) ** 2 < 1
        out[m, :3] = red * rng.uniform(0.75, 1.05)
        out[m, 3] = 1
    return out


def lily(w, h, rng, green):
    out = np.zeros((h, w, 4), F32)
    yy, xx = np.mgrid[0:h, 0:w].astype(F32)
    cx, cy = w / 2, h / 2
    dist = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / (w * 0.47)
    ang = np.arctan2(yy - cy, xx - cx)
    pad = (dist < 1) & ~((np.abs(ang - 0.5) < 0.18) & (dist > 0.05))
    vein = (np.abs(np.sin(ang * 9)) < 0.08) & pad
    col = green * (0.8 + 0.3 * dist[..., None])
    out[..., :3] = np.clip(col, 0, 1)
    out[vein, :3] = green * 0.65
    out[..., 3] = pad.astype(F32)
    return out


def strands(w, h, rng, leaf, n=16):
    """Hanging strands of narrow leaves (willow, jungle vines); top of the tile is the hang point."""
    out = np.zeros((h, w, 4), F32)
    for _ in range(n):
        x = rng.uniform(0.08, 0.92) * w
        length = rng.uniform(0.6, 1.0) * h
        for s in range(int(length)):
            y = h - 1 - s
            xx = x + 3 * math.sin(s / 17.0)
            out[y, int(max(0, xx - 0.8)) : int(min(w, xx + 1.8)), :3] = leaf * 0.7
            out[y, int(max(0, xx - 0.8)) : int(min(w, xx + 1.8)), 3] = 1
            if s % 9 == 0:
                for side in (-1, 1):
                    for k in range(9):
                        lx = int(xx + side * k * 0.9)
                        ly = y - k // 2
                        if 0 <= lx < w and 0 <= ly < h:
                            out[ly, max(0, lx - 1) : lx + 1, :3] = leaf * rng.uniform(0.85, 1.15)
                            out[ly, max(0, lx - 1) : lx + 1, 3] = 1
    return np.clip(out, 0, 1)


def blob_alpha(rng, h, w, fill=0.75):
    """Irregular ground-clutter blob mask (0/1)."""
    yy, xx = np.mgrid[0:h, 0:w].astype(F32)
    r = np.sqrt(((xx - w / 2) / (w / 2)) ** 2 + ((yy - h / 2) / (h / 2)) ** 2)
    n = noise2(rng, h, w, max(4, w // 10))
    return ((1 - r) * 1.3 + (n - 0.5) * 0.9 > (1 - fill)).astype(F32)


def textured_blob(path, rng, h, w, target, sat=0.6, fill=0.7):
    img = resize(load_px(path), h, w)
    img[..., 3] = blob_alpha(rng, h, w, fill)
    return grade(img, target, 0.7, sat)


# ------------------------------------------------------------------ atlas
class Atlas:
    def __init__(self, name, size):
        self.name = name
        self.size = size
        self.px = np.zeros((size, size, 4), F32)
        self.nrm = np.zeros((size, size, 4), F32)
        self.nrm[...] = (0.5, 0.5, 1.0, 1.0)
        self.uv = {}

    def put(self, key, x, y, tile, normal=None):
        """Place a bottom-up tile with its left-bottom corner at pixel (x, y)."""
        h, w = tile.shape[:2]
        self.px[y : y + h, x : x + w] = tile
        if normal is not None:
            self.nrm[y : y + h, x : x + w] = normal
        s = self.size
        self.uv[key] = (x / s, y / s, (x + w) / s, (y + h) / s)

    def save(self, outdir):
        albedo, apath = C.save_rgba(f"{self.name}_albedo", outdir, self.size, self.size, self.px.reshape(-1, 4))
        nimg = bpy.data.images.new(f"{self.name}_normal", self.size, self.size, alpha=True)
        nimg.pixels.foreach_set(self.nrm.ravel())
        npath = os.path.join(outdir, f"{self.name}_normal.png")
        nimg.filepath_raw = npath
        nimg.file_format = "PNG"
        nimg.save()
        nimg.colorspace_settings.name = "Non-Color"
        self.material = C.card_material(self.name + "_mat", albedo, nimg)
        self.paths = {"albedo": apath, "normal": npath}
        return self.material

    def opaque_mean(self, key):
        u0, v0, u1, v1 = self.uv[key]
        s = self.size
        t = self.px[int(v0 * s) : int(v1 * s), int(u0 * s) : int(u1 * s)].reshape(-1, 4)
        m = t[:, 3] > 0.5
        return "#%02x%02x%02x" % tuple(int(c * 255) for c in t[m, :3].mean(0)) if m.any() else "-"


# ------------------------------------------------------------------ mesh helpers
class Mesh:
    def __init__(self, name):
        self.name = name
        self.bm = bmesh.new()
        self.uvl = self.bm.loops.layers.uv.new("UVMap")

    def quad(self, corners, uv):
        C.quad(self.bm, self.uvl, corners, uv)

    def card(self, base, up, side, width, height, uv, bend=None, rows=2):
        C.bent_card(self.bm, self.uvl, base, up, side, width, height, uv, bend=bend if bend is not None else 0.0, rows=rows)

    def tube(self, pts, radii, sides, uv, twist=0.0):
        """Ring tube along a polyline; bark UV u around, v along the whole length."""
        u0, v0, u1, v1 = uv
        total = sum((pts[i + 1] - pts[i]).length for i in range(len(pts) - 1)) or 1
        acc = 0
        prev = None
        for i, c in enumerate(pts):
            if i:
                acc += (pts[i] - pts[i - 1]).length
            t = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
            a = t.orthogonal().normalized()
            b = t.cross(a).normalized()
            ring = []
            for k in range(sides + 1):
                ang = 2 * math.pi * k / sides + twist * i
                ring.append(self.bm.verts.new(c + (a * math.cos(ang) + b * math.sin(ang)) * radii[i]))
            if prev:
                va, vb = v0 + (v1 - v0) * (acc_prev / total), v0 + (v1 - v0) * (acc / total)
                for k in range(sides):
                    f = self.bm.faces.new((prev[k], prev[k + 1], ring[k + 1], ring[k]))
                    ua, ub = u0 + (u1 - u0) * k / sides, u0 + (u1 - u0) * (k + 1) / sides
                    for loop, uvp in zip(f.loops, ((ua, va), (ub, va), (ub, vb), (ua, vb))):
                        loop[self.uvl].uv = uvp
            prev = ring
            acc_prev = acc

    def strip(self, pts, widths, side_fn, uv):
        """Ribbon along pts with UV v along the strip (frond / fern / blade)."""
        u0, v0, u1, v1 = uv
        n = len(pts)
        prev = None
        for i, p in enumerate(pts):
            side = side_fn(i)
            row = (self.bm.verts.new(p - side * widths[i] / 2), self.bm.verts.new(p + side * widths[i] / 2))
            if prev:
                ta, tb = (i - 1) / (n - 1), i / (n - 1)
                f = self.bm.faces.new((prev[0], prev[1], row[1], row[0]))
                for loop, uvp in zip(f.loops, ((u0, v0 + (v1 - v0) * ta), (u1, v0 + (v1 - v0) * ta), (u1, v0 + (v1 - v0) * tb), (u0, v0 + (v1 - v0) * tb))):
                    loop[self.uvl].uv = uvp
            prev = row

    def blob(self, centre, radius, subdiv, uv, squash=(1, 1, 1), jitter=0.15):
        """Lumpy icosphere with every face mapped into one uv rect (planar xz projection)."""
        res = bmesh.ops.create_icosphere(self.bm, subdivisions=subdiv, radius=1.0)
        u0, v0, u1, v1 = uv
        verts = res["verts"]
        for v in verts:
            k = 1 + random.uniform(-jitter, jitter)
            v.co = Vector((v.co.x * squash[0] * radius * k, v.co.y * squash[1] * radius * k, v.co.z * squash[2] * radius * k)) + centre
        faces = {f for v in verts for f in v.link_faces}
        for f in faces:
            for loop in f.loops:
                p = loop.vert.co - centre
                loop[self.uvl].uv = (
                    u0 + (u1 - u0) * (0.5 + 0.5 * p.x / (radius * max(squash[0], 1e-3) * 1.2)),
                    v0 + (v1 - v0) * (0.5 + 0.5 * (p.z + p.y * 0.5) / (radius * 1.5)),
                )
        return verts

    def swatch_ball(self, centre, radius, uvpt, subdiv=1):
        res = bmesh.ops.create_icosphere(self.bm, subdivisions=subdiv, radius=radius, matrix=Matrix.Translation(centre))
        for f in {f for v in res["verts"] for f in v.link_faces}:
            for loop in f.loops:
                loop[self.uvl].uv = uvpt

    def box(self, centre, size, uv, yaw=0.0):
        res = bmesh.ops.create_cube(self.bm, size=1.0)
        rot = Matrix.Rotation(yaw, 3, "Z")
        u0, v0, u1, v1 = uv
        for v in res["verts"]:
            v.co = rot @ Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2])) + centre
        for f in {f for v in res["verts"] for f in v.link_faces}:
            for loop, uvp in zip(f.loops, ((u0, v0), (u1, v0), (u1, v1), (u0, v1))):
                loop[self.uvl].uv = uvp

    def finish(self, material):
        obj = C.mesh_object(self.name, self.bm)
        obj.data.materials.append(material)
        C.finish_mesh(obj, smooth=False)
        return obj


def outward_cards(m, uv_list, n, centre, rx, ry, rz, size, zmin=-0.2, top_cards=0, top_z=None, rng=random):
    """Leaf-cluster cards on an ellipsoid shell, tips outward-up, plus near-flat crown cards."""
    for i in range(n):
        z = rng.uniform(zmin, 1.0)
        a = rng.uniform(0, 2 * math.pi)
        r = math.sqrt(max(0.0, 1 - z * z))
        d = Vector((r * math.cos(a), r * math.sin(a), z))
        depth = rng.uniform(0.65, 1.0)
        c = centre + Vector((d.x * rx, d.y * ry, d.z * rz)) * depth
        out = Vector((d.x, d.y, d.z * 0.6 + 0.4)).normalized()
        tangent = out.cross(Vector((0, 0, 1)))
        if tangent.length < 1e-3:
            tangent = Vector((1, 0, 0))
        tangent.normalize()
        side = Matrix.Rotation(rng.uniform(-1.2, 1.2), 3, out) @ tangent
        up = out.cross(side).normalized()
        tip = (out * 0.6 + up * 0.55).normalized()
        side = tip.cross(out).normalized()
        w = size * rng.uniform(0.8, 1.2)
        uv = uv_list[i % len(uv_list)]
        m.quad([c - side * w / 2, c + side * w / 2, c + side * w / 2 + tip * w, c - side * w / 2 + tip * w], uv)
    for i in range(top_cards):
        a = rng.uniform(0, 2 * math.pi)
        r = math.sqrt(rng.random()) * 0.75
        c = centre + Vector((math.cos(a) * r * rx, math.sin(a) * r * ry, (top_z if top_z is not None else rz * 0.8) - r * rz * 0.3))
        w = size * rng.uniform(1.0, 1.3)
        t = Vector((math.cos(a + 1.7), math.sin(a + 1.7), rng.uniform(-0.15, 0.15))).normalized()
        s = Vector((-t.y, t.x, 0)).normalized()
        m.quad([c - s * w / 2 - t * w / 2, c + s * w / 2 - t * w / 2, c + s * w / 2 + t * w / 2, c - s * w / 2 + t * w / 2], uv_list[i % len(uv_list)])


def grass_cluster(m, uvs, pairs, hmin, hmax, width, radius, lean=0.35, rows=1, rng=random):
    """Crossed bent card pairs; each pair is 2 cards x rows quads."""
    up = Vector((0, 0, 1))
    for i in range(pairs):
        r = radius * math.sqrt(rng.random())
        a = rng.uniform(0, 2 * math.pi)
        base = Vector((math.cos(a) * r, math.sin(a) * r, -0.05))
        h = rng.uniform(hmin, hmax)
        yaw = rng.uniform(0, math.pi)
        bend = Vector((math.cos(a), math.sin(a), 0)) * rng.uniform(0.1, lean) * h
        for k in (0, 1):
            side = Vector((math.cos(yaw + k * math.pi / 2), math.sin(yaw + k * math.pi / 2), 0))
            m.card(base, up, side, width * rng.uniform(0.85, 1.15), h, uvs[(i + k) % len(uvs)], bend=bend, rows=rows)


def frond_strip(m, top, yaw, pitch, length, width, uv, droop=2.0, steps=6, roll=0.0):
    d = Vector((math.cos(yaw), math.sin(yaw), 0))
    side = d.cross(Vector((0, 0, 1))).normalized()
    s2 = (side * math.cos(roll) + Vector((0, 0, 1)) * math.sin(roll)).normalized()
    pts, widths = [], []
    for s in range(steps + 1):
        u = s / steps
        z = math.sin(pitch) * length * u - droop * (u**2) * length / 4
        pts.append(top + d * (math.cos(pitch) * length * u + 0.05) + Vector((0, 0, z)))
        widths.append(width * (0.55 + 0.45 * math.sin(math.pi * min(1.0, 0.2 + u))))
    m.strip(pts, widths, lambda i: s2, uv)


# ------------------------------------------------------------------ rock scans
def scan_rock(gltf, name, size, tris, target, outdir, squash=1.0, sat=0.6, bake_size=512):
    """A2b rock rule: weld + strip UVs before decimation, then selected-to-active bake (512)."""
    parts = C.import_gltf(gltf)
    high = C.join(parts, name + "_high") if len(parts) > 1 else parts[0]
    bpy.ops.object.select_all(action="DESELECT")
    high.select_set(True)
    bpy.context.view_layer.objects.active = high
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    dims = high.dimensions
    s = size / max(dims.x, dims.y)
    high.scale = (s, s, s * squash)
    bpy.ops.object.transform_apply(scale=True)
    cx = sum(v.co.x for v in high.data.vertices) / len(high.data.vertices)
    cy = sum(v.co.y for v in high.data.vertices) / len(high.data.vertices)
    zmin = min(v.co.z for v in high.data.vertices)
    for v in high.data.vertices:
        v.co.x -= cx
        v.co.y -= cy
        v.co.z -= zmin
    low = high.copy()
    low.data = high.data.copy()
    low.name = name
    C.link(low)
    low.modifiers.clear()
    bm = bmesh.new()
    bm.from_mesh(low.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.002 * size)
    bm.to_mesh(low.data)
    bm.free()
    while low.data.uv_layers:
        low.data.uv_layers.remove(low.data.uv_layers[0])
    got = C.decimate_to(low, tris)
    if got > tris * 1.08:
        got = C.decimate_to(low, tris)
    C.finish_mesh(low)
    C.unwrap(low, 0.01)
    maps, images = C.bake_to_low(low, high, name, outdir, size=bake_size, extrusion=0.04 * size / 2.6)
    px, w, h = C.image_array(images["albedo"])
    px = C.grade_pixels(px, target, strength=0.8, sat=sat)
    bpy.data.objects.remove(high)
    out = {}
    for kind, img in images.items():
        a, iw, ih = C.image_array(img)
        out[kind] = (px if kind == "albedo" else a).reshape(ih, iw, 4).copy()
        out[kind][..., 3] = 1.0
    return low, out


def remap_uv(obj, rect):
    u0, v0, u1, v1 = rect
    for loop_uv in obj.data.uv_layers.active.data:
        u, v = loop_uv.uv
        loop_uv.uv = (u0 + (u1 - u0) * u, v0 + (v1 - v0) * v)


def assign(obj, material):
    obj.data.materials.clear()
    obj.data.materials.append(material)


def copies(obj, name, placements):
    """Join transformed copies of obj (shared UVs): placements = [(loc, rot_z, scale_xyz)]."""
    objs = []
    for loc, rz, sc in placements:
        o = obj.copy()
        o.data = obj.data.copy()
        C.link(o)
        o.location = loc
        o.rotation_euler = (0, 0, rz)
        o.scale = sc
        objs.append(o)
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    j = C.join(objs, name)
    return j


def ground(obj):
    """Pivot at ground centre: shift so min z = 0 and xy bbox centre = origin."""
    vs = obj.data.vertices
    xs = [v.co.x for v in vs]
    ys = [v.co.y for v in vs]
    zmin = min(v.co.z for v in vs)
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    for v in vs:
        v.co.x -= cx
        v.co.y -= cy
        v.co.z -= zmin
    obj.location = (0, 0, 0)
    return obj


# ------------------------------------------------------------------ packaging
def layout_row(objs, gap=4.0):
    """Spread objects along +X so the package and previews read; the runtime uses bounding boxes."""
    x = 0.0
    for o in objs:
        w = o.dimensions.x
        o.location = (x + w / 2, 0, 0)
        x += w + gap


def sheet(paths, out, cols=6, cell=192):
    """Contact sheet of silhouette renders (moderation pre-screen)."""
    rows = (len(paths) + cols - 1) // cols
    canvas = np.ones((rows * cell, cols * cell, 4), F32)
    for i, p in enumerate(paths):
        a = resize(load_px(p), cell, cell)
        r, c = divmod(i, cols)
        canvas[(rows - 1 - r) * cell : (rows - r) * cell, c * cell : (c + 1) * cell] = a
    canvas[..., 3] = 1
    img = bpy.data.images.new(os.path.basename(out), cols * cell, rows * cell, alpha=True)
    img.pixels.foreach_set(canvas.ravel())
    img.filepath_raw = out
    img.file_format = "PNG"
    img.save()
    return out


def silhouettes_and_previews(name, outdir, objs):
    sil = []
    for o in objs:
        for other in objs:
            other.hide_render = other is not o
        sil += C.silhouette(o.name.replace(".", "_"), outdir, [o], views=("front", "top"))
    for o in objs:
        o.hide_render = False
    sheet(sil, os.path.join(outdir, f"{name}_silhouettes.png"))
    pv = C.preview(name, outdir, objs)
    for p in sil:
        os.remove(p)
    return pv


def report_rows(objs, budgets):
    rows = []
    for o in objs:
        t = C.triangles(o)
        b = budgets.get(o.name)
        rows.append({"key": o.name, "tris": t, "budget": b, "fits": b is None or t <= b, "size": [round(v, 1) for v in o.dimensions]})
    return rows
