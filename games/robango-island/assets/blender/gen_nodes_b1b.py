"""B1b resource-node package: the 10 catalog node rows owned by B1b, each as a `full`
and a `depleted` (~30% triangles) Model, sharing one 1024 node atlas.

blender -b --factory-startup --python gen_nodes_b1b.py -- <outdir>
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from mathutils import Vector

import common as C
import kit_b1b as K

SEED = 4341
PACKAGE = "RobangoNodesB1b"


def atlas(outdir, rng):
    import kitlib

    A = K.Atlas(PACKAGE + "_atlas", 1024)
    # opaque rock/earth half (bottom 512 rows), alpha plant half (top)
    clay = kitlib.paint_strata(K.scan_tile("brown_mud/textures/brown_mud_diff_1k.jpg", 256, "#9a8a72", 0.85, 0.4), rng, step=22, dark=0.6, light=1.15)
    A.put("clay", 0, 0, clay, K.scan_normal("brown_mud/textures/brown_mud_nor_gl_1k.jpg", 256))
    A.put("clay_ochre", 256, 0, K.scan_tile("brown_mud/textures/brown_mud_diff_1k.jpg", 256, "clay_ochre", 0.85, 0.5), K.scan_normal("brown_mud/textures/brown_mud_nor_gl_1k.jpg", 256))
    iron = K.scan_tile("rock_face/textures/rock_face_diff_1k.jpg", 256, "#5e534a", 0.85, 0.4)
    K.paint_blotch(iron, rng, "rust", "#a85a30", scale=8, cover=0.35, seed=21)
    # L12: bright rust-red ore seams across the host rock so the vein reads at phone zoom (R05)
    K.paint_twigs(iron, rng, "#b0582a", "#d88a4a", trunks=3, depth=3, spread=1.3, thick=2.6)
    iron = kitlib.top_light(iron, 0.15)
    iron[..., 3] = 1
    A.put("iron", 512, 0, iron, K.scan_normal("rock_face/textures/rock_face_nor_gl_1k.jpg", 256))
    cu = K.scan_tile("rock_face/textures/rock_face_diff_1k.jpg", 256, "#5a5650", 0.85, 0.4)
    K.paint_blotch(cu, rng, "copper_green", "#6a9a7a", scale=8, cover=0.35, seed=23)
    K.paint_twigs(cu, rng, "#4a9a7e", "#8ad0b0", trunks=3, depth=3, spread=1.3, thick=2.6)
    cu = kitlib.top_light(cu, 0.15)
    cu[..., 3] = 1
    A.put("copper", 768, 0, cu, K.scan_normal("rock_face/textures/rock_face_nor_gl_1k.jpg", 256))
    A.put("basalt", 0, 256, K.scan_tile("dark_rock/textures/dark_rock_diff_1k.jpg", 256, "basalt", 0.85, 0.4), K.scan_normal("dark_rock/textures/dark_rock_nor_gl_1k.jpg", 256))
    vent = K.scan_tile("burned_ground_01/textures/burned_ground_01_diff_1k.jpg", 256, "#2c2624", 0.85, 0.4)
    K.paint_twigs(vent, rng, "#7a2a10", "ember", trunks=3, depth=3, spread=1.2, thick=1.4)
    K.paint_dots(vent, rng, 14, "sulfur", "#d8c060", 2, 5, (0.3, 0.7))
    vent[..., 3] = 1
    A.put("vent", 256, 256, vent, K.scan_normal("burned_ground_01/textures/burned_ground_01_nor_gl_1k.jpg", 256))
    char = K.scan_tile("dead_tree_trunk/textures/dead_tree_trunk_diff_1k.jpg", 256, "char", 0.9, 0.2)
    A.put("char", 512, 256, char, K.scan_normal("dead_tree_trunk/textures/dead_tree_trunk_nor_gl_1k.jpg", 256))
    coal = K.tile(256, K.hexrgb("#2a2420"), 1.0)
    K.paint_dots(coal, rng, 60, "#141110", "#3a3430", 6, 16)
    A.put("coal", 768, 256, coal)
    A.put("reed", 0, 512, kitlib.light_tips(K.paint_blades(K.tile(256), rng, 70, "#5a5a34", "#b8a46a", height=(0.7, 0.98), width=(1.6, 2.6), lean=0.2), 0.25))
    cat = K.paint_blades(K.tile(256), rng, 40, "#4a5a2e", "#7a7a46", height=(0.6, 0.95), width=(2.0, 3.2), lean=0.15)
    for k in range(7):  # brown cattail heads on straight stems
        x = 30 + k * 32
        K._seg(cat, (x, 0), (x, 200), 1.6, 1.4, K.hexrgb("#6a6a3a"), K.hexrgb("#6a6a3a"))
        K._seg(cat, (x, 160), (x, 215), 6.0, 6.0, K.hexrgb("cattail"), K.hexrgb("#6a4228"), shade=0.3)
    A.put("cattail", 256, 512, kitlib.light_tips(cat, 0.2))
    A.put("cord", 512, 512, K.paint_blades(K.tile(256), rng, 80, "#4c4f2c", "straw", height=(0.5, 0.95), width=(1.4, 2.6), lean=0.5))
    sam = K.tile(256)
    for k in range(40):  # samphire: jointed green succulent stems
        x = rng.uniform(20, 236)
        y = 0.0
        ang = rng.uniform(-0.4, 0.4)
        for j in range(5):
            q = (x + math.sin(ang) * 18, y + 18)
            K._seg(sam, (x, y), q, 3.2, 3.0, K.hexrgb("samphire") * rng.uniform(0.8, 1.1), K.hexrgb("#7a9a4a"), shade=0.3)
            x, y = q
            ang += rng.uniform(-0.3, 0.3)
    A.put("samphire", 768, 512, sam)
    mud = K.tile(256)
    K.paint_blotch(mud, rng, "swamp_mud", "#3a3a2a", scale=4, cover=0.85, seed=31)
    A.put("mudpatch", 0, 768, mud)
    stump = K.tile(256)
    K.paint_blotch(stump, rng, "#3a3028", "#5a4a38", scale=5, cover=0.8, seed=33)
    A.put("stubble", 256, 768, K.paint_blades(stump, rng, 60, "#5a4a30", "#7a6440", height=(0.08, 0.2), width=(1.6, 2.4), lean=0.4))
    # L12 ore chip swatches (bright, so the chips glint against the host rock)
    A.put("iron_chip", 512, 768, K.tile(128, K.hexrgb("#c46a34"), 1.0))
    A.put("copper_chip", 640, 768, K.tile(128, K.hexrgb("#5ab894"), 1.0))
    mat, paths = A.save(outdir, alpha=True)
    return A, mat, paths


def rock_node(rect, size, n, rng, sub=2, rough=0.3, flat=0.5):
    b = K.Builder()
    for i in range(n):
        a = 2 * math.pi * i / max(n, 1) + rng.uniform(-0.3, 0.3)
        r = 0 if i == 0 else size[0] * 0.8
        s = (size[0] * rng.uniform(0.6, 1.0), size[1] * rng.uniform(0.6, 1.0), size[2] * rng.uniform(0.7, 1.0))
        b.rock(Vector((math.cos(a) * r, math.sin(a) * r, s[2] * 0.6)), s, rect, rng, sub=sub, rough=rough, flat=flat)
    return b


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    rng = np.random.default_rng(SEED)
    A, mat, paths = atlas(outdir, rng)
    R = A.rects
    objs = []

    def add(key, full, dep):
        objs.append(full.finish(K.key_name(key) + "_full", mat))
        objs.append(dep.finish(K.key_name(key) + "_depleted", mat))

    def stand(rects, h, rad, pairs, width):
        b = K.Builder()
        K.grass_cluster(b, rng, rects, h, rad, pairs, width=width)
        return b

    def with_mud(b, r):
        b.disc(Vector((0, 0, 0)), r, R["mudpatch"], segs=10, rings=1, rng=rng, lift=0.03)
        return b

    add("node.cattail-stand", with_mud(stand([R["cattail"]], 5.0, 2.0, 32, 2.2), 2.6), with_mud(stand([R["stubble"]], 0.6, 1.6, 6, 1.4), 2.6))
    # L12: a cut clay bank (bedded face + slumped ochre lumps + a few dug blocks) instead of two blobs
    b = K.Builder()
    b.rock(Vector((0, 0, 0.9)), (2.8, 1.8, 1.5), R["clay"], rng, sub=3, rough=0.15, flat=0.5, strata=0.4)
    b.rock(Vector((1.7, 0.6, 0.4)), (1.6, 1.2, 0.8), R["clay_ochre"], rng, sub=2, rough=0.2)
    b.rock(Vector((-1.9, 0.9, 0.3)), (1.1, 0.9, 0.5), R["clay_ochre"], rng, sub=2, rough=0.2)
    for i in range(3):
        b.prism(Vector((rng.uniform(-1.2, 1.2), -2.1 - i * 0.2, 0.0)), 0.45, 0.55, 4, R["clay_ochre"], rng, top_jit=0.05)
    add("node.clay-bank", b, rock_node(R["clay"], (2.6, 1.6, 0.5), 1, rng, sub=2, rough=0.15, flat=0.3))
    add("node.cordgrass-tussock", stand([R["cord"]], 3.0, 1.0, 50, 2.0), stand([R["stubble"]], 0.5, 1.0, 8, 1.2))
    add("node.reed-bed", with_mud(stand([R["reed"]], 6.0, 2.6, 38, 2.6), 3.2), with_mud(stand([R["stubble"]], 0.6, 2.2, 10, 1.6), 3.2))
    sam = K.Builder()
    for i in range(45):
        a = rng.uniform(0, 2 * math.pi)
        r = 2.2 * math.sqrt(rng.random())
        sam.crossed(Vector((math.cos(a) * r, math.sin(a) * r, 0)), 1.2, 0.9, R["samphire"], n=2, rot=rng.uniform(0, 3), rows=1)
    sam.disc(Vector((0, 0, 0)), 2.6, R["mudpatch"], segs=10, rings=1, rng=rng, lift=0.03)
    add("node.samphire-flat", sam, with_mud(stand([R["stubble"]], 0.4, 2.0, 8, 1.2), 2.6))
    def vein(rect, chip):
        # L12: bedded host outcrop + protruding ore chips (R05 "ore" reads as a mineral face, not a ball)
        b = K.Builder()
        b.rock(Vector((0, 0, 1.2)), (2.6, 2.0, 2.0), rect, rng, sub=3, rough=0.32, strata=0.5)
        b.rock(Vector((2.0, 0.8, 0.6)), (1.4, 1.2, 1.0), rect, rng, sub=2, rough=0.3, strata=0.5)
        for i in range(7):
            a = rng.uniform(-1.2, 1.2)
            base = Vector((math.cos(a) * 2.1, -abs(math.sin(a)) * 1.6 - 0.2, rng.uniform(0.4, 2.2)))
            b.prism(base, rng.uniform(0.18, 0.32), rng.uniform(0.6, 1.2), 5, chip, rng, tilt=Vector((math.cos(a), -0.6, 0.2)) * 0.9, top_jit=0.2)
        return b
    add("node.iron-vein", vein(R["iron"], R["iron_chip"]), rock_node(R["iron"], (2.4, 1.8, 0.8), 2, rng, sub=2, flat=0.3))
    add("node.copper-vein", vein(R["copper"], R["copper_chip"]), rock_node(R["copper"], (2.4, 1.8, 0.8), 2, rng, sub=2, flat=0.3))
    bf = K.Builder()
    for i in range(10):
        bf.prism(Vector((rng.uniform(-3, 3), rng.uniform(-1, 1), -0.2)), rng.uniform(0.6, 0.9), rng.uniform(2, 6), 6, R["basalt"], rng, top_jit=0.05)
    for i in range(4):
        bf.rock(Vector((rng.uniform(-3, 3), rng.uniform(1.5, 2.5), 0.4)), (0.7, 0.6, 0.5), R["basalt"], rng, sub=2, rough=0.2)
    bd = K.Builder()
    for i in range(8):
        bd.prism(Vector((rng.uniform(-3, 3), rng.uniform(-1, 1), -0.2)), rng.uniform(0.6, 0.9), rng.uniform(0.6, 1.4), 6, R["basalt"], rng, top_jit=0.05)
    add("node.basalt-face", bf, bd)
    vf = K.Builder()
    vf.rock(Vector((0, 0, 0.6)), (3.0, 3.0, 1.4), R["vent"], rng, sub=3, rough=0.25)
    vf.tube([Vector((0, 0, 1.4)), Vector((0, 0, 2.2))], [1.0, 0.6], R["coal"], sides=10, v_scale=0.3, cap=True, cap_rect=R["vent"])
    add("node.volcanic-vent", vf, rock_node(R["vent"], (3.0, 3.0, 0.5), 1, rng, sub=2, flat=0.3))
    cf = K.Builder()
    cf.disc(Vector((0, 0, 0)), 2.5, R["coal"], segs=12, rings=2, rng=rng, lift=0.08)
    cf.tube([Vector((0, 0, -0.2)), Vector((0, 0, 1.2)), Vector((0.1, 0, 1.6))], [0.9, 0.8, 0.6], R["char"], sides=10, v_scale=0.3, cap=True, cap_rect=R["coal"])
    for i in range(8):
        a = rng.uniform(0, 2 * math.pi)
        cf.rock(Vector((math.cos(a) * 1.7, math.sin(a) * 1.7, 0.25)), (0.4, 0.3, 0.25), R["coal"], rng, sub=1, rough=0.3)
    cd = K.Builder()
    cd.disc(Vector((0, 0, 0)), 2.5, R["coal"], segs=12, rings=2, rng=rng, lift=0.04)
    cd.tube([Vector((0, 0, -0.2)), Vector((0, 0, 0.5))], [0.9, 0.8], R["char"], sides=8, v_scale=0.3, cap=True, cap_rect=R["coal"])
    add("node.charcoal-pit", cf, cd)
    K.row_layout(objs, gap=3.0)
    K.export_package(PACKAGE, outdir, objs, {"seed": SEED, "atlas_means": {k: A.mean_hex(k) for k in R}, "maps": paths})


main()
