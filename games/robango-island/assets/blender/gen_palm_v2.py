"""Jungle palm (hybrid): Poly Haven palm_tree_bark (CC0) scan on a leaning trunk + procedurally
painted alpha frond cards (green + dry), drooping dead fronds and an orange fruit cluster (R11-2).

One 1024 RGBA atlas: x 0-511 bark, 512-767 green frond, 768-1023 dry frond, fruit swatch in a corner.
Needs build/a2b/src/palm_tree_bark/ (see SOURCES.md).
"""

import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

import common as C

SEED = 4201
NAME = "RobangoPalmV2"
HEIGHT = 7.0
N = 1024

UV_BARK = (0.0, 0.06, 0.5, 1.0)
UV_GREEN = (0.5, 0.0, 0.75, 1.0)
UV_DRY = (0.75, 0.0, 1.0, 1.0)
UV_FRUIT = (0.01, 0.005, 0.04, 0.04)


def hexrgb(name):
    h = C.PALETTE.get(name, name).lstrip("#")
    return np.array([int(h[i : i + 2], 16) / 255 for i in (0, 2, 4)], np.float32)


def paint_frond(w, h, light, dark, rng, broken=0.0):
    """Pinnate frond, rachis vertical (bottom = base). Returns (h, w, 4) sRGB float."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    v = y / h  # 0 bottom (Blender rows bottom-up) .. 1 tip
    cx = w / 2
    d = np.abs(x - cx)
    # Leaflets slant toward the tip: the leaflet through (x,y) started at y0 on the rachis.
    slope = 0.55
    y0 = y - d * slope
    spacing = 13.0
    phase = (y0 / spacing) % 1.0
    v0 = np.clip(y0 / h, 0, 1)
    length = (w * 0.48) * np.sin(np.pi * np.clip(v0 * 1.05, 0.04, 1.0)) ** 0.7
    length *= 1.0 - 0.25 * ((np.floor(y0 / spacing) * 7.31) % 1.0)  # ragged lengths
    t = d / np.maximum(length, 1)
    width = 0.78 * (1 - t) ** 0.5
    leaf = (phase < width) & (t < 1.0) & (y0 > h * 0.05)
    if broken:
        gap = ((np.floor(y0 / spacing) * 3.7) % 1.0) < broken
        leaf &= ~gap
    rachis = (d < 3.5 * (1 - 0.7 * v)) & (v > 0.0)
    mask = leaf | rachis
    shade = np.clip(0.55 + 0.45 * (1 - phase / np.maximum(width, 1e-3)), 0, 1)[..., None]
    col = dark + (light - dark) * shade
    col = col * (0.85 + 0.15 * t[..., None])  # tips a touch lighter (sun-bleached)
    noise = rng.normal(0, 0.035, (h, w, 1)).astype(np.float32)
    col = np.clip(col + noise, 0, 1)
    col[rachis] = dark * 0.9
    out = np.zeros((h, w, 4), np.float32)
    out[..., :3] = col
    out[..., 3] = mask.astype(np.float32)
    return out


def build_atlas(outdir):
    rng = np.random.default_rng(SEED)
    atlas = np.zeros((N, N, 4), np.float32)
    bark, bw, bh = C.image_array(C.load_image(os.path.join(C.SRC_DIR, "palm_tree_bark", "palm_tree_bark_diff_1k.png")))
    bark = bark.reshape(bh, bw, 4)
    # 1024x2048 -> 512x1024 by 2x2 average.
    bark = bark.reshape(bh // 2, 2, bw // 2, 2, 4).mean((1, 3))
    flat = C.grade_pixels(bark.reshape(-1, 4).copy(), "bark", strength=0.8, sat=0.7)
    atlas[:, 0:512] = flat.reshape(N, 512, 4)
    atlas[:, 0:512, 3] = 1.0
    atlas[:, 512:768] = paint_frond(256, N, hexrgb("olive_light"), hexrgb("olive_dark"), rng)
    atlas[:, 768:1024] = paint_frond(256, N, hexrgb("straw"), hexrgb("straw_dry") * 0.75, rng, broken=0.35)
    fr = (slice(int(UV_FRUIT[1] * N), int(UV_FRUIT[3] * N)), slice(int(UV_FRUIT[0] * N), int(UV_FRUIT[2] * N)))
    atlas[fr[0], fr[1], :3] = hexrgb("fruit")
    atlas[fr[0], fr[1], 3] = 1.0
    img, path = C.save_rgba(f"{NAME}_albedo", outdir, N, N, atlas.reshape(-1, 4))
    # Normal: bark scan normal in the trunk half, flat elsewhere.
    nb, nw, nh = C.image_array(C.load_image(os.path.join(C.SRC_DIR, "palm_tree_bark", "palm_tree_bark_nor_gl_1k.png"), True))
    nb = nb.reshape(nh, nw, 4).reshape(nh // 2, 2, nw // 2, 2, 4).mean((1, 3))
    nrm = np.zeros((N, N, 4), np.float32)
    nrm[...] = (0.5, 0.5, 1.0, 1.0)
    nrm[:, 0:512] = nb
    nimg, npath = C.save_rgba(f"{NAME}_normal", outdir, N, N, nrm.reshape(-1, 4))
    nimg.colorspace_settings.name = "Non-Color"
    return img, path, nimg, npath


def trunk_curve(t):
    return Vector((1.1 * math.sin(t * 1.3) * t, 0.3 * t * t, HEIGHT * t))


def build(bm, uvl):
    rings, sides = 22, 10
    prev = None
    for i in range(rings + 1):
        t = i / rings
        c = trunk_curve(t)
        r = 0.30 * (1 - 0.35 * t) + (0.035 if i % 2 == 0 else 0.0)
        if i == 0:
            r = 0.42
        ring = []
        for k in range(sides + 1):  # duplicate seam column for clean UVs
            a = 2 * math.pi * k / sides
            ring.append(bm.verts.new(c + Vector((math.cos(a) * r, math.sin(a) * r, 0))))
        if prev:
            for k in range(sides):
                f = bm.faces.new((prev[k], prev[k + 1], ring[k + 1], ring[k]))
                u0, v0, u1, v1 = UV_BARK
                tp = (i - 1) / rings
                uv = lambda kk, tt: (u0 + (u1 - u0) * kk / sides, v0 + (v1 - v0) * ((tt * 3.0) % 1.0001))
                # 3 vertical bark repeats; keep each quad inside one repeat.
                rep0 = math.floor(tp * 3)
                a0 = tp * 3 - rep0
                a1 = t * 3 - rep0
                for loop, (kk, aa) in zip(f.loops, ((k, a0), (k + 1, a0), (k + 1, a1), (k, a1))):
                    loop[uvl].uv = (u0 + (u1 - u0) * kk / sides, v0 + (v1 - v0) * min(aa, 1.0))
        prev = ring
    top = trunk_curve(1.0)
    up = Vector((0, 0, 1))
    # Live fronds: arched card strips, crossed by a second card rolled 35 deg for volume.
    count = 15
    for f in range(count):
        yaw = 2 * math.pi * f / count + random.uniform(-0.18, 0.18)
        pitch = random.uniform(0.1, 0.8)
        length = random.uniform(3.4, 4.6)
        frond(bm, uvl, top, yaw, pitch, length, UV_GREEN, droop=random.uniform(1.6, 2.4))
    # Dead fronds hanging against the trunk (shaggy skirt).
    for f in range(7):
        yaw = 2 * math.pi * f / 7 + random.uniform(-0.3, 0.3)
        frond(bm, uvl, top - Vector((0, 0, 0.35)), yaw, -0.9, random.uniform(2.2, 2.9), UV_DRY, droop=0.6, width=0.9)
    # Frond boots: short dry cards around the upper trunk.
    for i in range(18):
        t = random.uniform(0.62, 0.97)
        c = trunk_curve(t)
        a = random.uniform(0, 2 * math.pi)
        out = Vector((math.cos(a), math.sin(a), 0))
        base = c + out * 0.22
        side = Vector((-math.sin(a), math.cos(a), 0))
        uv = (UV_DRY[0], 0.0, UV_DRY[2], 0.22)
        C.bent_card(bm, uvl, base, (up + out * 0.8).normalized(), side, 0.45, 0.75, uv, bend=out * 0.25, rows=2)
    # Fruit cluster under the crown.
    for i in range(16):
        a = random.uniform(0, 2 * math.pi)
        r = random.uniform(0.25, 0.55)
        c = top + Vector((math.cos(a) * r, math.sin(a) * r, -random.uniform(0.35, 1.0)))
        res = bmesh.ops.create_icosphere(bm, subdivisions=1, radius=random.uniform(0.07, 0.1), matrix=Matrix.Translation(c))
        faces = {f for v in res["verts"] for f in v.link_faces}
        cu = (UV_FRUIT[0] + UV_FRUIT[2]) / 2
        cv = (UV_FRUIT[1] + UV_FRUIT[3]) / 2
        for fc in faces:
            for loop in fc.loops:
                loop[uvl].uv = (cu, cv)


def frond(bm, uvl, top, yaw, pitch, length, uv_rect, droop=2.0, width=1.4):
    d = Vector((math.cos(yaw), math.sin(yaw), 0))
    side = d.cross(Vector((0, 0, 1))).normalized()
    steps = 7
    pts = []
    for s in range(steps + 1):
        u = s / steps
        z = math.sin(pitch) * length * u - droop * (u**2) * length / 4
        pts.append(top + d * (math.cos(pitch) * length * u + 0.1) + Vector((0, 0, z)))
    u0, v0, u1, v1 = uv_rect
    for roll in (0.0, 0.6):
        s2 = (side * math.cos(roll) + Vector((0, 0, 1)) * math.sin(roll)).normalized()
        prev = None
        for s, p in enumerate(pts):
            w = width * (0.55 + 0.45 * math.sin(math.pi * min(1.0, 0.2 + s / steps)))
            row = (bm.verts.new(p - s2 * w / 2), bm.verts.new(p + s2 * w / 2))
            if prev:
                f = bm.faces.new((prev[0], prev[1], row[1], row[0]))
                ta, tb = (s - 1) / steps, s / steps
                for loop, uv in zip(f.loops, ((u0, v0 + (v1 - v0) * ta), (u1, v0 + (v1 - v0) * ta), (u1, v0 + (v1 - v0) * tb), (u0, v0 + (v1 - v0) * tb))):
                    loop[uvl].uv = uv
            prev = row


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    albedo, apath, normal, npath = build_atlas(outdir)
    bm = bmesh.new()
    uvl = bm.loops.layers.uv.new("UVMap")
    build(bm, uvl)
    obj = C.mesh_object(NAME, bm)
    obj.data.materials.append(C.card_material(NAME + "_mat", albedo, normal))
    C.finish_mesh(obj, smooth=False)
    sil = C.silhouette(NAME, outdir, [obj])
    pv = C.preview(NAME, outdir, [obj])
    fbx = C.export_fbx(NAME, outdir, [obj])
    C.report(NAME, [obj], {"fbx": fbx, "preview": pv, "silhouettes": sil, "albedo": apath, "normal": npath}, {"seed": SEED})


main()
