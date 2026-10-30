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


# ------------------------------------------------------------------ L3 vegetation v2
# Durango-like crowns (R11-1/2/8): a forked, tapered trunk (optional buttress roots) carries a few
# primary branches; each ends in a spread of small twig + branch-card clusters with sky gaps
# between them, instead of one dense ball of leaf quads on a straight pole.


def line(tile, p0, p1, w0, w1, col, shade=0.25):
    """Tapered segment p0 -> p1 (pixel coords, bottom-up rows) painted opaque into tile."""
    h, w = tile.shape[:2]
    pad = max(w0, w1) + 2
    x0, x1 = int(max(0, min(p0[0], p1[0]) - pad)), int(min(w, max(p0[0], p1[0]) + pad))
    y0, y1 = int(max(0, min(p0[1], p1[1]) - pad)), int(min(h, max(p0[1], p1[1]) + pad))
    if x1 <= x0 or y1 <= y0:
        return
    yy, xx = np.mgrid[y0:y1, x0:x1].astype(F32)
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    ll = dx * dx + dy * dy + 1e-6
    s = np.clip(((xx - p0[0]) * dx + (yy - p0[1]) * dy) / ll, 0, 1)
    px_, py_ = p0[0] + s * dx, p0[1] + s * dy
    d = np.sqrt((xx - px_) ** 2 + (yy - py_) ** 2)
    width = w0 + (w1 - w0) * s
    sel = d <= width
    side = ((xx - px_) * -dy + (yy - py_) * dx) / math.sqrt(ll)
    lit = 1 + shade * np.clip(side / np.maximum(width, 0.5), -1, 1)
    sub = tile[y0:y1, x0:x1]
    sub[sel, :3] = np.clip(col[None, :] * lit[sel][:, None], 0, 1)
    sub[sel, 3] = 1.0


def sprig(rng, leaf_srcs, twig, size=256, leaves=22, leaf_h=64, sides=4, spread=0.95, reach=0.38):
    """Branch-card tile: a twig with side twigs and leaves stamped along them, base at the bottom
    centre. The open silhouette (gaps between twigs) is what gives a crown its negative space."""
    t = np.zeros((size, size, 4), F32)
    k = size / 256
    bx = size / 2 + rng.uniform(-8, 8) * k
    tx = size / 2 + rng.uniform(-36, 36) * k
    main = [(bx + (tx - bx) * (u * u), 2 + u * size * 0.86) for u in np.linspace(0, 1, 7)]
    polys = [main]
    for i in range(6):
        line(t, main[i], main[i + 1], 3.2 * k * (1 - i / 7), 3.2 * k * (1 - (i + 1) / 7) + 0.6, twig)
    for j in range(sides):
        u = rng.uniform(0.22, 0.78)
        i = int(u * 6)
        p = main[i]
        sgn = -1 if j % 2 else 1
        ang = sgn * rng.uniform(0.45, spread)
        ln = size * reach * rng.uniform(0.7, 1.1) * (1 - 0.35 * u)
        pts = [p]
        for s in range(1, 4):
            a = ang * (1 - 0.15 * s)
            q = pts[-1]
            pts.append((q[0] + math.sin(a) * ln / 3, q[1] + math.cos(a) * ln / 3))
        for s in range(3):
            line(t, pts[s], pts[s + 1], 1.8 * k * (1 - s / 4), 1.8 * k * (1 - (s + 1) / 4) + 0.4, twig)
        polys.append(pts)
    for n in range(leaves):
        poly = polys[n % len(polys)]
        u = rng.uniform(0.35, 1.0)
        f = u * (len(poly) - 1)
        i = min(int(f), len(poly) - 2)
        a0, a1 = poly[i], poly[i + 1]
        fr = f - i
        cx, cy = a0[0] + (a1[0] - a0[0]) * fr, a0[1] + (a1[1] - a0[1]) * fr
        dx, dy = a1[0] - a0[0], a1[1] - a0[1]
        ang = math.atan2(-dx, dy) + rng.choice([-1, 1]) * rng.uniform(0.35, 1.0)
        leaf = leaf_srcs[int(rng.uniform(0, len(leaf_srcs) - 1e-6))]
        stamp(t, leaf, cx, cy, ang, leaf_h * k * rng.uniform(0.7, 1.1), rng.uniform(0.72, 1.05))
    return t


def _pick(rng, seq):
    return seq[int(rng.uniform(0, len(seq) - 1e-6))]


def crown_points(rng, n, centre, rx, ry, rz, mind, depth=(0.5, 1.0), zmin=-0.35):
    """Up to n cluster centres in a crown ellipsoid, at least `mind` apart (the gaps)."""
    pts = []
    for _ in range(n * 80):
        if len(pts) >= n:
            break
        z = rng.uniform(zmin, 1.0)
        a = rng.uniform(0, 2 * math.pi)
        r = math.sqrt(max(0.0, 1 - z * z))
        d = rng.uniform(*depth)
        p = centre + Vector((r * math.cos(a) * rx, r * math.sin(a) * ry, z * rz)) * d
        if all((p - q).length >= mind for q in pts):
            pts.append(p)
    return pts


def card_cluster(quad, rng, p, out, uvs, cards, size, flat=0.5):
    """`cards` branch cards fanned from p: tips outward/up, some near-flat for the top-down camera."""
    up = Vector((0, 0, 1))
    for k in range(cards):
        jitter = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-0.6, 1)))
        horizontal = Vector((out.x, out.y, 0))
        if horizontal.length < 1e-3:
            horizontal = Vector((math.cos(k), math.sin(k), 0))
        horizontal.normalize()
        if k < cards * flat:
            d = (horizontal + jitter * 0.6 + up * rng.uniform(-0.1, 0.35)).normalized()
        else:
            d = (out * 0.6 + up * 0.7 + jitter * 0.55).normalized()
        side = d.cross(up)
        if side.length < 1e-3:
            side = Vector((1, 0, 0))
        side = (Matrix.Rotation(rng.uniform(-0.7, 0.7), 3, d) @ side.normalized()).normalized()
        w = size * rng.uniform(0.8, 1.2)
        b = p - d * w * 0.3
        quad([b - side * w / 2, b + side * w / 2, b + side * w / 2 + d * w, b - side * w / 2 + d * w], _pick(rng, uvs))


def branch_tree(tube, quad, rng, height, trunk_r, crown, uvs, *, fork=0.45, leaders=2, groups=7, clusters=30,
                cards=8, card=3.0, roots=0, root_reach=2.6, root_h=2.0, lean=(0.0, 0.0), sides=8, mind=None,
                zmin=-0.35, depth=(0.5, 1.0), flat=0.5, twigs=True, hang=None, trunk_draw=True):
    """Clustered branch-card tree. tube(pts, radii, sides); quad(corners, uv).
    crown = (rx, ry, rz); the crown top sits at `height`. Returns the cluster centres."""
    rx, ry, rz = crown
    lx, ly = lean
    centre = Vector((lx * height, ly * height, height - rz))
    F = Vector((lx * height * fork * 0.6, ly * height * fork * 0.6, height * fork))
    trunk = [Vector((0, 0, -0.3)), Vector((0, 0, 0.6)), F * 0.35 + Vector((rng.uniform(-0.2, 0.2), rng.uniform(-0.2, 0.2), 0)),
             F * 0.7 + Vector((rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), 0)), F]
    if trunk_draw:
        tube(trunk, [trunk_r * 1.55, trunk_r * 1.2, trunk_r, trunk_r * 0.86, trunk_r * 0.72], sides)
    for i in range(roots):
        a = 2 * math.pi * i / roots + rng.uniform(-0.25, 0.25)
        o = Vector((math.cos(a), math.sin(a), 0))
        reach = root_reach * rng.uniform(0.8, 1.2)
        tube([o * trunk_r * 0.3 + Vector((0, 0, root_h)), o * trunk_r * 1.2 + Vector((0, 0, root_h * 0.4)),
              o * trunk_r * reach + Vector((0, 0, -0.2))], [trunk_r * 0.5, trunk_r * 0.36, trunk_r * 0.1], 4)
    pts = crown_points(rng, clusters, centre, rx, ry, rz, mind or card * 1.15, depth, zmin)
    # Groups by azimuth around the crown centre; each group is one primary branch.
    def az(p):
        return math.atan2(p.y - centre.y, p.x - centre.x)
    order = sorted(pts, key=az)
    off = int(rng.uniform(0, len(order) or 1))
    order = order[off:] + order[:off]
    per = max(1, math.ceil(len(order) / groups))
    chunks = [order[i : i + per] for i in range(0, len(order), per)]
    ends = []
    for j in range(leaders):
        mine = [c for gi, c in enumerate(chunks) if gi % leaders == j]
        flatpts = [p for c in mine for p in c] or [centre]
        m = sum(flatpts, Vector()) / len(flatpts)
        end = F + (m - F) * 0.45
        end.z = max(end.z, F.z + (centre.z - F.z) * 0.55)
        mid = (F + end) / 2 + Vector((rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4), 0.3))
        if trunk_draw:
            tube([F, mid, end], [trunk_r * 0.72, trunk_r * 0.55, trunk_r * 0.4], max(5, sides - 2))
        else:
            # upper shelf: leaders from its own fork point (tiered_tree joins it to the lower fork)
            tube([F, mid, end], [trunk_r * 0.5, trunk_r * 0.4, trunk_r * 0.3], max(4, sides - 3))
        ends.append(end)
    for gi, chunk in enumerate(chunks):
        if not chunk:
            continue
        L = ends[gi % leaders]
        cg = sum(chunk, Vector()) / len(chunk)
        bg = cg * 0.8 + centre * 0.2
        mid = (L + bg) / 2 + Vector((0, 0, (bg - L).length * 0.12))
        tube([L, mid, bg], [trunk_r * 0.38, trunk_r * 0.26, trunk_r * 0.15], 5)
        for p in chunk:
            out = (p - centre)
            out = Vector((out.x / max(rx, 1e-3), out.y / max(ry, 1e-3), out.z / max(rz, 1e-3)))
            out = out.normalized() if out.length > 1e-3 else Vector((0, 0, 1))
            if twigs and (p - bg).length > card * 0.4:
                tube([bg, p], [trunk_r * 0.12, trunk_r * 0.05], 3)
            card_cluster(quad, rng, p, out, uvs, cards, card, flat)
            if hang is not None:
                hang(p)
    return pts


def clustered_shrub(quad, rng, rx, rz, clusters, cards, card, uvs, z0=0.0):
    """Shrub as clumps of branch cards with gaps (replaces the uniform leaf-quad ball)."""
    centre = Vector((0, 0, z0 + rz * 0.55))
    pts = crown_points(rng, clusters, centre, rx, rx, rz * 0.55, card * 0.8, (0.45, 1.0), -0.5)
    for p in pts:
        out = p - centre
        out = out.normalized() if out.length > 1e-3 else Vector((0, 0, 1))
        card_cluster(quad, rng, p, out, uvs, cards, card, 0.35)
    return pts



# ------------------------------------------------------------------ L12 environment pass
# Painted bark, lit/shaded crown layers and rock strata (R11-1/2/3/8 at the 57 degree camera).
# Everything here is opt-in: builders call it explicitly, so rows that do not ask keep their
# L3 geometry and atlas tiles byte for byte.


def paint_bark(w, h, rng, base, dark, light, moss=None, plates=11, fissure=0.55, knots=3, moss_cover=0.0):
    """Hand-painted bark column (bottom-up RGBA, opaque): vertical plates split by dark fissures,
    a warm lit edge on each plate, a few knots and an optional moss wash rising from the base.
    Reads at phone zoom where a 1k scan graded to one colour turns into flat brown noise."""
    t = np.zeros((h, w, 4), F32)
    t[..., 3] = 1
    yy, xx = np.mgrid[0:h, 0:w].astype(F32)
    n_lo = noise2(rng, h, w, max(8, h // 10))
    n_hi = noise2(rng, h, w, 6)
    # plate boundaries wander along v so fissures read as split bark, not stripes
    wob = (noise2(rng, h, 4, max(8, h // 6))[:, :1] - 0.5) * (w / plates) * 0.9
    u = ((xx + wob) / (w / plates)) % 1.0
    edge = np.minimum(u, 1 - u) * 2  # 0 at fissure, 1 mid-plate
    fiss = np.clip(1 - edge / fissure, 0, 1) ** 1.6
    lit = np.clip((u - 0.55) * 3.0, 0, 1) * (1 - fiss)  # right edge of each plate catches light
    col = base[None, None, :] * (0.82 + 0.3 * n_lo[..., None] + 0.12 * (n_hi[..., None] - 0.5))
    col = col * (1 - fiss[..., None]) + dark[None, None, :] * fiss[..., None]
    col = col + (light - base)[None, None, :] * (lit * 0.55)[..., None]
    # horizontal checks across the plates
    checks = (noise2(rng, h, w, 3) > 0.83) & (edge > 0.3)
    col[checks] = col[checks] * 0.72
    for _ in range(knots):
        cx, cy = rng.uniform(0.1, 0.9) * w, rng.uniform(0.15, 0.85) * h
        rx, ry = rng.uniform(0.05, 0.09) * w, rng.uniform(0.02, 0.035) * h
        d = ((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2
        ring = (d < 1.0) & (d > 0.45)
        col[ring] = dark * 1.05
        col[d <= 0.45] = base * 0.7
    if moss is not None and moss_cover > 0:
        v = yy / h
        m = np.clip((moss_cover - v) * 4 + (n_lo - 0.5) * 1.6, 0, 1) * (1 - fiss * 0.6)
        col = col * (1 - m[..., None]) + moss[None, None, :] * (0.8 + 0.4 * n_hi[..., None]) * m[..., None]
    t[..., :3] = np.clip(col, 0, 1)
    return t


def light_tips(tile, amount=0.22, warm=(1.03, 1.0, 0.93)):
    """Paint the crown light into a leaf/sprig tile: texels towards the tile top (the card tip,
    which faces out and up) are lifted and warmed, the base darkened. Alpha is untouched."""
    h = tile.shape[0]
    v = (np.arange(h, dtype=F32) / h)[:, None, None]
    k = (1 - amount) + 2 * amount * v
    out = tile.copy()
    out[..., :3] = np.clip(tile[..., :3] * k * np.array(warm, F32)[None, None, :] ** v, 0, 1)
    return out


def shade_tile(tile, amount=0.55, cool=(0.86, 0.95, 0.9)):
    """Inner-canopy variant of a leaf tile: darker and slightly cooler (the self-shadow under the
    lit outer clusters, which Roblox will not compute for alpha cards)."""
    out = tile.copy()
    out[..., :3] = np.clip(tile[..., :3] * amount * np.array(cool, F32)[None, None, :], 0, 1)
    return out


def canopy_core(quad, rng, centre, crown, uv, cards=10, size=3.0):
    """Shade layer: a few large dark cards inside the crown so the gaps between lit clusters read
    as depth (dark inner leaves) instead of sky, and the crown keeps its layered silhouette."""
    rx, ry, rz = crown
    for k in range(cards):
        z = rng.uniform(-0.55, 0.35)
        a = rng.uniform(0, 2 * math.pi)
        r = rng.uniform(0.15, 0.55)
        c = centre + Vector((math.cos(a) * rx * r, math.sin(a) * ry * r, z * rz))
        t = Vector((math.cos(a + 1.3), math.sin(a + 1.3), rng.uniform(-0.25, 0.25))).normalized()
        s = Vector((-t.y, t.x, 0)).normalized()
        w = size * rng.uniform(0.85, 1.25)
        quad([c - s * w / 2 - t * w / 2, c + s * w / 2 - t * w / 2, c + s * w / 2 + t * w / 2, c - s * w / 2 + t * w / 2], uv)


def tiered_tree(tube, quad, rng, height, trunk_r, crown, uvs, shade_uv, *, tiers=2, core=10, core_size=3.2, **kw):
    """Layered canopy (R11-8 oaks, R11-2 jungle giants): the crown is split into `tiers` stacked
    shelves, each a branch_tree cluster layer with its own spread, plus a dark core layer. The
    shelves give the crown a stepped, painterly silhouette at the top-down camera instead of one
    round ball."""
    rx, ry, rz = crown
    pts_all = []
    prev_fork = None
    clusters = kw.pop("clusters", 30)
    groups = kw.pop("groups", 7)
    lean = kw.get("lean", (0.0, 0.0))
    for i in range(tiers):
        f = i / max(tiers - 1, 1)
        top = height - rz * 0.9 * (1 - f) if tiers > 1 else height
        spread = 1.0 - 0.42 * f
        sub = dict(kw)
        if i > 0:
            sub["roots"] = 0
        sub["trunk_draw"] = i == 0
        fork = kw.get("fork", 0.45)
        F = Vector((lean[0] * top * fork * 0.6, lean[1] * top * fork * 0.6, top * fork))
        if i > 0:
            # trunk continues from the lower shelf's fork up to this shelf's fork
            tube([prev_fork, (prev_fork + F) / 2, F], [trunk_r * 0.7, trunk_r * 0.62, trunk_r * 0.55], max(5, kw.get("sides", 8) - 2))
        prev_fork = F
        pts = branch_tree(tube, quad, rng, top, trunk_r * (1 - 0.18 * i), (rx * spread, ry * spread, rz * (0.55 if tiers > 1 else 1)),
                          uvs, clusters=max(6, int(clusters * (0.58 - 0.16 * f) * (2 if tiers == 1 else 1))),
                          groups=max(3, groups - i), **sub)
        pts_all += pts
    centre = Vector((lean[0] * height, lean[1] * height, height - rz))
    canopy_core(quad, rng, centre, crown, shade_uv, core, core_size)
    return pts_all


def strata(obj, step=0.9, amount=0.35, tilt=(0.08, 0.04)):
    """Rock strata on a decimated scan rock: vertices are partly snapped to tilted bedding planes
    every `step` studs, so the silhouette and the baked/painted bands read as layered rock."""
    tx, ty = tilt
    cx = sum(v.co.x for v in obj.data.vertices) / len(obj.data.vertices)
    cy = sum(v.co.y for v in obj.data.vertices) / len(obj.data.vertices)
    for v in obj.data.vertices:
        p = v.co
        plane = p.z + p.x * tx + p.y * ty
        f = (plane / step) % 1.0
        snapped = round(plane / step) * step
        v.co.z = p.z + (snapped - plane) * amount
        # each bed's upper lip juts out a little and its foot tucks in: a ledge with a shadow line
        k = 1 + 0.07 * amount * math.cos(f * 2 * math.pi)
        v.co.x = cx + (p.x - cx) * k
        v.co.y = cy + (p.y - cy) * k
    obj.data.update()


def paint_strata(px, rng, z_of_row=None, step=48, dark=0.5, light=1.06, warm=(0.98, 0.97, 0.95)):
    """Bands on a rock albedo atlas slot (bottom-up RGBA): alternating lighter beds and dark
    seams with a soft top light, so a baked scan rock carries layered strata in its colour too."""
    h, w = px.shape[:2]
    n = noise2(rng, h, w, 24)
    v = np.arange(h, dtype=F32)[:, None] + (n - 0.5) * step * 0.8
    band = (v / step) % 1.0
    seam = np.clip(1 - np.minimum(band, 1 - band) * 7, 0, 1)
    bed = np.where((v // step) % 2 == 0, light, 1.0)
    k = bed * (1 - seam * (1 - dark))
    out = px.copy()
    out[..., :3] = np.clip(px[..., :3] * k[..., None] * np.array(warm, F32)[None, None, :], 0, 1)
    return out


def top_light(px, amount=0.25):
    """Lift the upper half of an opaque rock tile (sky light on top faces in a box-projected UV
    tile is the tile top); keeps the scan detail."""
    h = px.shape[0]
    v = (np.arange(h, dtype=F32) / h)[:, None, None]
    out = px.copy()
    out[..., :3] = np.clip(px[..., :3] * ((1 - amount) + 2 * amount * v), 0, 1)
    return out
