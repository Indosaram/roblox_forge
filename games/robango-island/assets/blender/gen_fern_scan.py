"""Fern clump (approach 1, photoscan cards, catalog budget 600 tris): 14 arched frond strips
textured with single fronds cut from the Poly Haven fern_02 (CC0) alpha atlas, graded olive.

(The raw fern_02 scan is 6.2k tris, 10x the veg.jungle.ground-fern budget.)
Needs build/a2b/src/fern_02/ (see SOURCES.md).
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

SEED = 4203
NAME = "RobangoFernScan"


def rect(x0, y0, x1, y1, n=1024):
    return (x0 / n, 1 - y1 / n, x1 / n, 1 - y0 / n)


# Single fronds in fern_02_diff_1k (pixel boxes, y down; tips at the top).
FRONDS = [rect(92, 110, 240, 965), rect(330, 25, 465, 785), rect(555, 25, 675, 505), rect(525, 520, 640, 985), rect(735, 110, 870, 900)]


def frond(bm, uvl, yaw, pitch, length, width, uv):
    d = Vector((math.cos(yaw), math.sin(yaw), 0))
    side = d.cross(Vector((0, 0, 1))).normalized()
    roll = random.uniform(0.15, 0.45)  # slight V so the frond is not paper-flat from above
    steps = 5
    u0, v0, u1, v1 = uv
    prev = None
    for s in range(steps + 1):
        t = s / steps
        z = math.sin(pitch) * length * t - 0.9 * t * t * length * 0.75
        p = d * (math.cos(pitch) * length * t + 0.03) + Vector((0, 0, z + 0.02))
        sv = (side + Vector((0, 0, 1)) * roll).normalized()
        row = (bm.verts.new(p - sv * width / 2), bm.verts.new(p + side * width / 2))
        if prev:
            f = bm.faces.new((prev[0], prev[1], row[1], row[0]))
            ta, tb = (s - 1) / steps, t
            # Frond base at the bottom of the atlas rect (v0), tip at the top (v1).
            for loop, uvp in zip(f.loops, ((u0, v0 + (v1 - v0) * ta), (u1, v0 + (v1 - v0) * ta), (u1, v0 + (v1 - v0) * tb), (u0, v0 + (v1 - v0) * tb))):
                loop[uvl].uv = uvp
        prev = row


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    src = os.path.join(C.SRC_DIR, "fern_02")
    diff, w, h = C.image_array(C.load_image(os.path.join(src, "textures", "fern_02_diff_1k.jpg")))
    alpha, _, _ = C.image_array(C.load_image(os.path.join(src, "textures", "fern_02_alpha_1k.png"), True))
    mask = alpha[:, 0] > 0.5
    diff = C.grade_pixels(diff, "olive", strength=0.7, sat=0.6, mask=mask)
    diff[:, 3] = np.where(mask, 1.0, 0.0)
    albedo, apath = C.save_rgba(f"{NAME}_albedo", outdir, w, h, diff)
    normal = C.load_image(os.path.join(src, "textures", "fern_02_nor_gl_1k.jpg"), True)
    bm = bmesh.new()
    uvl = bm.loops.layers.uv.new("UVMap")
    count = 22
    for i in range(count):
        yaw = 2 * math.pi * i / count + random.uniform(-0.2, 0.2)
        inner = i % 3 == 0
        pitch = random.uniform(0.9, 1.25) if inner else random.uniform(0.45, 0.85)
        length = random.uniform(0.75, 1.0) if inner else random.uniform(1.0, 1.4)
        uv = random.choice(FRONDS)
        aspect = (uv[2] - uv[0]) / (uv[3] - uv[1])
        frond(bm, uvl, yaw, pitch, length, length * aspect * 1.25, uv)
    obj = C.mesh_object(NAME, bm)
    obj.data.materials.append(C.card_material(NAME + "_mat", albedo, normal))
    C.finish_mesh(obj, smooth=False)
    sil = C.silhouette(NAME, outdir, [obj])
    pv = C.preview(NAME, outdir, [obj])
    fbx = C.export_fbx(NAME, outdir, [obj])
    C.report(NAME, [obj], {"fbx": fbx, "preview": pv, "silhouettes": sil, "albedo": apath}, {"seed": SEED})


main()
