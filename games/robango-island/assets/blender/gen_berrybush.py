"""Berry bush gather node (hybrid): a dense dome of single-leaf alpha cards cut from the
Poly Haven shrub_04 (CC0) leaf atlas, graded to the olive palette, + clustered red berries.

(The raw shrub_04 scan is 3 sparse plants in a row at 27k tris, unusable as one node.)
Needs build/a2b/src/shrub_04/ (see SOURCES.md).
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

SEED = 4206
NAME = "RobangoBerryBush"
RADIUS = 0.75
HEIGHT_M = 1.25
LEAVES = 150  # catalog node.berry-bush budget 900 tris: leaf CLUSTER cards + berries


def rect(x0, y0, x1, y1, n=1024):
    return (x0 / n, 1 - y1 / n, x1 / n, 1 - y0 / n)


# Single leaves in shrub_04_diff_1k (pixel boxes, y down, tip up / petiole down).
LEAF_UV = [
    rect(135, 100, 232, 330),
    rect(540, 75, 628, 338),
    rect(440, 410, 552, 645),
    rect(618, 395, 712, 598),
    rect(238, 655, 338, 940),
    rect(383, 712, 492, 952),
    rect(562, 698, 652, 905),
    rect(52, 735, 152, 962),
]
BERRY_UV = (0.985, 0.985)
# 4 painted leaf-cluster tiles (each 256x256) in the bottom-left 512x512 of the atlas.
CLUSTER_UV = [(0.0, 0.0, 0.25, 0.25), (0.25, 0.0, 0.5, 0.25), (0.0, 0.25, 0.25, 0.5), (0.25, 0.25, 0.5, 0.5)]


def build_cluster_tiles(img, w, h, src_mask_img):
    """Stamp ~14 scanned single leaves (rotated about the tile centre) into each 256 tile."""
    rng = np.random.default_rng(SEED)
    src = img.copy()
    tiles = np.zeros((512, 512, 4), np.float32)
    for ti, (tu, tv) in enumerate(((0, 0), (256, 0), (0, 256), (256, 256))):
        tile = np.zeros((256, 256, 4), np.float32)
        for k in range(14):
            u0, v0, u1, v1 = LEAF_UV[rng.integers(len(LEAF_UV))]
            x0, x1 = int(u0 * w), int(u1 * w)
            y0, y1 = int(v0 * h), int(v1 * h)
            leaf = src[y0:y1, x0:x1]
            # downscale the leaf to ~45% of the tile height
            sc = 115.0 / leaf.shape[0]
            lh, lw = max(4, int(leaf.shape[0] * sc)), max(3, int(leaf.shape[1] * sc))
            yi = (np.arange(lh) / sc).astype(int).clip(0, leaf.shape[0] - 1)
            xi = (np.arange(lw) / sc).astype(int).clip(0, leaf.shape[1] - 1)
            small = leaf[yi][:, xi]
            ang = rng.uniform(-1.3, 1.3) + (0 if k % 2 else math.pi * 0.0)
            ca, sa = math.cos(ang), math.sin(ang)
            cx, cy = 128 + rng.uniform(-30, 30), 70 + rng.uniform(-25, 40)
            yy, xx = np.mgrid[0:256, 0:256].astype(np.float32)
            # inverse rotate tile coords into leaf coords (leaf base at its bottom row)
            dx, dy = xx - cx, yy - cy
            lx = ca * dx + sa * dy + lw / 2
            ly = -sa * dx + ca * dy
            ok = (lx >= 0) & (lx < lw) & (ly >= 0) & (ly < lh)
            li = ly[ok].astype(int)
            lj = lx[ok].astype(int)
            vals = small[li, lj]
            sel = vals[:, 3] > 0.5
            tgt = tile[ok]
            shade = 0.75 + 0.25 * (k / 14)
            tgt[sel, :3] = vals[sel, :3] * shade
            tgt[sel, 3] = 1.0
            tile[ok] = tgt
        tiles[tv : tv + 256, tu : tu + 256] = tile
    img[0:512, 0:512] = tiles
    return img


def build():
    bm = bmesh.new()
    uvl = bm.loops.layers.uv.new("UVMap")
    # Leaves on a squashed dome, normals roughly outward, slight droop.
    for i in range(LEAVES):
        # Fibonacci-ish direction on the upper hemisphere + a bit below the equator.
        z = random.uniform(-0.25, 1.0)
        a = random.uniform(0, 2 * math.pi)
        r = math.sqrt(max(0.0, 1 - z * z))
        d = Vector((r * math.cos(a), r * math.sin(a), z))
        depth = random.uniform(0.7, 1.0)  # some leaves inside for volume
        c = Vector((d.x * RADIUS, d.y * RADIUS, (d.z * 0.85 + 0.15) * HEIGHT_M * 0.62 + 0.25)) * depth
        c.z = max(c.z, 0.05)
        uv = CLUSTER_UV[random.randrange(len(CLUSTER_UV))]
        aspect = 1.0
        w = random.uniform(0.32, 0.42)  # each card carries a cluster (see build_cluster_tile)
        h = w * aspect
        out = Vector((d.x, d.y, d.z * 0.6 + 0.4)).normalized()
        tangent = out.cross(Vector((0, 0, 1)))
        if tangent.length < 1e-3:
            tangent = Vector((1, 0, 0))
        tangent.normalize()
        rot = Matrix.Rotation(random.uniform(-1.2, 1.2), 3, out)
        side = rot @ tangent
        up = (out.cross(side)).normalized() * -1 if random.random() < 0.0 else out.cross(side).normalized()
        # Leaf points outward-upward: tip = c + mix(out, up).
        tipdir = (out * 0.7 + up * 0.5).normalized()
        side = tipdir.cross(out).normalized()
        C.quad(bm, uvl, [c - side * w / 2, c + side * w / 2, c + side * w / 2 + tipdir * h, c - side * w / 2 + tipdir * h], uv)
    # Crown: near-horizontal cluster cards so the top-down (57 deg) view is not hollow.
    for i in range(26):
        a = random.uniform(0, 2 * math.pi)
        r = RADIUS * math.sqrt(random.random()) * 0.75
        c = Vector((math.cos(a) * r, math.sin(a) * r, HEIGHT_M * 0.78 - r * 0.35 + random.uniform(-0.05, 0.05)))
        w = random.uniform(0.38, 0.5)
        t = Vector((math.cos(a + 1.7), math.sin(a + 1.7), random.uniform(-0.15, 0.15))).normalized()
        s = Vector((-t.y, t.x, 0)).normalized()
        C.quad(bm, uvl, [c - s * w / 2 - t * w / 2, c + s * w / 2 - t * w / 2, c + s * w / 2 + t * w / 2, c - s * w / 2 + t * w / 2], CLUSTER_UV[i % 4])
    # Stems: a few dark twigs at the base.
    for i in range(8):
        a = 2 * math.pi * i / 8
        out = Vector((math.cos(a), math.sin(a), 0))
        C.bent_card(bm, uvl, Vector((0, 0, 0)), Vector((0, 0, 1)), out.cross(Vector((0, 0, 1))), 0.03, 0.55, (0.86, 0.10, 0.87, 0.70), bend=out * 0.4, rows=2)
    # Berry clusters on the outer shell, upper 70%.
    for i in range(16):
        z = random.uniform(0.0, 0.95)
        a = random.uniform(0, 2 * math.pi)
        r = math.sqrt(1 - z * z)
        c = Vector((r * math.cos(a) * RADIUS * 1.02, r * math.sin(a) * RADIUS * 1.02, (z * 0.85 + 0.15) * HEIGHT_M * 0.62 + 0.27))
        for k in range(random.randint(3, 4)):
            p = c + Vector((random.uniform(-0.055, 0.055), random.uniform(-0.055, 0.055), random.uniform(-0.06, 0.02)))
            res = bmesh.ops.create_cone(bm, cap_ends=True, segments=3, radius1=0.045, radius2=0.0, depth=0.07, matrix=Matrix.Translation(p))
            for f in {f for v in res["verts"] for f in v.link_faces}:
                for loop in f.loops:
                    loop[uvl].uv = BERRY_UV
    return C.mesh_object(NAME, bm)


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    src = os.path.join(C.SRC_DIR, "shrub_04")
    diff, w, h = C.image_array(C.load_image(os.path.join(src, "textures", "shrub_04_diff_1k.jpg")))
    alpha, _, _ = C.image_array(C.load_image(os.path.join(src, "textures", "shrub_04_alpha_1k.png"), True))
    mask = alpha[:, 0] > 0.5
    diff = C.grade_pixels(diff, "olive", strength=0.7, sat=0.7, mask=mask)
    diff[:, 3] = np.where(mask, 1.0, 0.0)
    img = diff.reshape(h, w, 4)
    img = build_cluster_tiles(img, w, h, None)
    bh = C.PALETTE["berry"].lstrip("#")
    img[h - 24 :, w - 24 :, :3] = [int(bh[i : i + 2], 16) / 255 for i in (0, 2, 4)]
    img[h - 24 :, w - 24 :, 3] = 1.0
    albedo, apath = C.save_rgba(f"{NAME}_albedo", outdir, w, h, img.reshape(-1, 4))
    normal = C.load_image(os.path.join(src, "textures", "shrub_04_nor_gl_1k.jpg"), True)
    bush = build()
    bush.data.materials.append(C.card_material(NAME + "_mat", albedo, normal))
    C.finish_mesh(bush, smooth=False)
    sil = C.silhouette(NAME, outdir, [bush])
    pv = C.preview(NAME, outdir, [bush])
    fbx = C.export_fbx(NAME, outdir, [bush])
    C.report(NAME, [bush], {"fbx": fbx, "preview": pv, "silhouettes": sil, "albedo": apath}, {"seed": SEED})


main()
