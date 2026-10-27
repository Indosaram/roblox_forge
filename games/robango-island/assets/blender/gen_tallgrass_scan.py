"""Tall grass, head height (approach 1, photoscan cards): alpha cards cut from the Poly Haven
grass_medium_01 (CC0) atlas, graded olive -> straw, arranged as a dense crossed-card clump.

Needs build/a2b/src/grass_medium_01/ (see SOURCES.md).
"""

import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
import numpy as np
from mathutils import Vector

import common as C

SEED = 4204
NAME = "RobangoTallGrassScan"


def rect(x0, y0, x1, y1, n=1024):
    """Atlas pixel rect (y down) -> UV rect (u0, v0, u1, v1), v up."""
    return (x0 / n, 1 - y1 / n, x1 / n, 1 - y0 / n)


# Regions of grass_medium_01_diff_1k (measured on the atlas).
TUFTS = [rect(200, 760, 500, 905), rect(600, 770, 830, 882), rect(30, 890, 200, 1012), rect(250, 900, 505, 1020), rect(590, 885, 812, 1020)]
BLADES = [rect(0, 0, 420, 740), rect(420, 0, 840, 740)]  # painted thin-blade cards (see paint_blades)
HEADS = [rect(850, 15, 1000, 330), rect(950, 230, 1010, 600), rect(495, 315, 600, 600)]  # seed heads


def build():
    bm = bmesh.new()
    uvl = bm.loops.layers.uv.new("UVMap")
    up = Vector((0, 0, 1))
    # Tall layer: 12 crossed pairs of wide multi-blade cards, 1.5-2.2 m (catalog budget 128 tris total).
    for i in range(12):
        r = 0.55 * math.sqrt(random.random())
        a = random.uniform(0, 2 * math.pi)
        base = Vector((math.cos(a) * r, math.sin(a) * r, -0.02))
        h = random.uniform(1.5, 2.2)
        yaw = random.uniform(0, math.pi)
        lean = Vector((math.cos(a), math.sin(a), 0)) * random.uniform(0.15, 0.45) * h
        for k in (0, 1):
            side = Vector((math.cos(yaw + k * math.pi / 2), math.sin(yaw + k * math.pi / 2), 0))
            C.bent_card(bm, uvl, base, up, side, random.uniform(1.2, 1.6), h, BLADES[k], bend=lean, rows=2)
    # Seed heads poking above.
    for i in range(4):
        r = 0.45 * math.sqrt(random.random())
        a = random.uniform(0, 2 * math.pi)
        base = Vector((math.cos(a) * r, math.sin(a) * r, 0.9))
        side = Vector((math.cos(a + 1.3), math.sin(a + 1.3), 0))
        uv = random.choice(HEADS)
        C.bent_card(bm, uvl, base, up, side, 0.32, random.uniform(0.9, 1.3), uv, bend=Vector((math.cos(a), math.sin(a), 0)) * 0.3, rows=1)
    # Low tuft skirt that hides the base.
    for i in range(12):
        a = 2 * math.pi * i / 12 + random.uniform(-0.2, 0.2)
        r = random.uniform(0.35, 0.75)
        base = Vector((math.cos(a) * r, math.sin(a) * r, -0.02))
        side = Vector((-math.sin(a), math.cos(a), 0))
        uv = random.choice(TUFTS)
        w = random.uniform(0.7, 1.0)
        aspect = (uv[3] - uv[1]) / (uv[2] - uv[0])
        C.bent_card(bm, uvl, base, up, side, w, w * aspect * 1.6, uv, bend=Vector((math.cos(a), math.sin(a), 0)) * 0.15, rows=1)
    obj = C.mesh_object(NAME, bm)
    return obj


def paint_blades(w, h, rng, n=48):
    """Thin arching grass blades rooted along the bottom; returns (h, w, 4) sRGB, rows bottom-up."""
    out = np.zeros((h, w, 4), np.float32)
    olive = np.array([int(C.PALETTE["olive"][i : i + 2], 16) / 255 for i in (1, 3, 5)])
    dark = np.array([int(C.PALETTE["olive_dark"][i : i + 2], 16) / 255 for i in (1, 3, 5)])
    straw = np.array([int(C.PALETTE["straw"][i : i + 2], 16) / 255 for i in (1, 3, 5)])
    for b in range(n):
        x0 = rng.uniform(0.4, 0.6) * w
        height = rng.uniform(0.55, 0.98) * h
        lean = rng.uniform(-0.32, 0.32) * w
        width0 = rng.uniform(5, 9)
        dry = rng.uniform(0, 1)
        steps = int(height)
        for s in range(0, steps, 1):
            t = s / steps
            x = x0 + lean * t * t
            hw = width0 * (1 - t) ** 0.8 + 0.6
            xa, xb = int(max(0, x - hw)), int(min(w, x + hw + 1))
            if xa >= xb:
                continue
            col = dark + (olive - dark) * min(1, t * 1.6)
            col = col * (1 - dry * t) + straw * (dry * t)
            # midrib highlight
            shade = 1.0 - 0.25 * np.abs(np.arange(xa, xb) - x) / max(hw, 1)
            out[s, xa:xb, :3] = col[None, :] * shade[:, None]
            out[s, xa:xb, 3] = 1.0
    return out


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    src = os.path.join(C.SRC_DIR, "grass_medium_01")
    diff, w, h = C.image_array(C.load_image(os.path.join(src, "grass_medium_01_diff_1k.png")))
    alpha, _, _ = C.image_array(C.load_image(os.path.join(src, "grass_medium_01_alpha_1k.png"), True))
    mask = alpha[:, 0] > 0.45
    # Two-tone grade: greener base, straw upper blades (R03-3 tall grass reads straw-olive).
    diff = C.grade_pixels(diff, "olive", strength=0.65, sat=0.55, mask=mask)
    rows = np.repeat(np.arange(h), w)[:, None] / h  # 0 bottom .. 1 top (Blender pixels are bottom-up)
    straw = np.array([int(C.PALETTE["straw"][i : i + 2], 16) / 255 for i in (1, 3, 5)])
    lum = (diff[:, :3] * np.array([0.2126, 0.7152, 0.0722])).sum(1, keepdims=True)
    tint = lum / max(float(lum[mask].mean()), 1e-3) * straw
    k = np.clip((rows - 0.35) * 0.9, 0, 0.55)
    diff[:, :3] = diff[:, :3] * (1 - k) + tint * k
    diff[:, 3] = np.where(mask, 1.0, 0.0)
    # Overwrite the unused top-left of the atlas (pixel y 0-740, x 0-840) with painted blade cards.
    img = diff.reshape(h, w, 4)
    rng = np.random.default_rng(SEED)
    for i, (xa, xb) in enumerate(((0, 420), (420, 840))):
        img[h - 740 :, xa:xb] = paint_blades(xb - xa, 740, rng)
    diff = img.reshape(-1, 4)
    albedo, apath = C.save_rgba(f"{NAME}_albedo", outdir, w, h, diff, size=512)
    normal = C.flat_normal(outdir, f"{NAME}_normal")
    obj = build()
    obj.data.materials.append(C.card_material(NAME + "_mat", albedo, normal))
    C.finish_mesh(obj, smooth=False)
    sil = C.silhouette(NAME, outdir, [obj])
    pv = C.preview(NAME, outdir, [obj])
    fbx = C.export_fbx(NAME, outdir, [obj])
    C.report(NAME, [obj], {"fbx": fbx, "preview": pv, "silhouettes": sil, "albedo": apath}, {"seed": SEED})


main()
