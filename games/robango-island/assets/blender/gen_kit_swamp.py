"""B1b swamp kit (R11-3): bleached dead trees, mangrove, cypress with moss, swamp bush,
marsh fern, cordgrass and sedge cards, mud stone, rotting log, litter clutter.

blender -b --factory-startup --python gen_kit_swamp.py -- <outdir>
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from mathutils import Vector

import common as C
import kit_b1b as K

SEED = 4301
PACKAGE = "RobangoKitSwamp"


def atlases(outdir, rng):
    veg = K.Atlas(PACKAGE + "_veg", 1024)
    bark = K.scan_tile("dead_tree_trunk/textures/dead_tree_trunk_diff_1k.jpg", 512, "deadwood", strength=0.85, sat=0.35)
    veg.put("bark_dead", 0, 0, bark[:, :256], K.scan_normal("dead_tree_trunk/textures/dead_tree_trunk_nor_gl_1k.jpg", 512)[:, :256])
    # L12: painted dark wet bark with a moss wash rising from the waterline (R11-3).
    wb = K.painted_bark(512, rng, "#4a3e30", "#18130e", "#6e604a", "#4a5428", cover=0.5, plates=11)
    veg.put("bark_dark", 256, 0, wb, K.scan_normal("bark_willow/textures/bark_willow_nor_gl_1k.jpg", 512)[:, :256])
    veg.put("twigs", 512, 0, K.paint_twigs(K.tile(256), rng, "deadwood_dark", "deadwood", trunks=3, depth=6))
    veg.put("moss", 768, 0, K.paint_strands(K.tile(256), rng, 34, "#5c5f3a", "#7a7a52"))
    veg.put("bush_a", 512, 256, K.sprig_tile(256, rng, "swamp_olive", "#3e3428", sat=0.55, leaves=44, leaf_h=58, sides=5))
    veg.put("bush_b", 768, 256, K.sprig_tile(256, rng, "olive_dark", "#3e3428", sat=0.5, leaves=44, leaf_h=58, sides=5))
    veg.put("fern", 0, 512, K.paint_frond(K.tile(256), rng, "#3d3a26", "#4f5a30", "#6a7040"))
    veg.put("cypress_leaf", 256, 512, K.sprig_tile(256, rng, "#3f4a2a", "#3b3026", sat=0.5, lit=0.2, leaves=70, leaf_h=40, sides=7, reach=0.4))
    # L3: branch-card sprigs (twig + leaves with gaps) instead of solid leaf-cluster tiles.
    mleaf = K.sprig_tile(256, rng, "olive", "#3e3428", sat=0.6, lit=0.2, leaves=60, leaf_h=50, sides=6, reach=0.42)
    veg.put("mangrove_leaf", 512, 512, mleaf)
    import kitlib
    veg.put("shade", 0, 768, kitlib.shade_tile(mleaf, 0.5))
    litter = K.tile(256)
    K.paint_blotch(litter, rng, "swamp_mud", "#5a4a38", scale=5.0, cover=0.75, seed=3)
    K.paint_twigs(litter, rng, "deadwood_dark", "deadwood", trunks=2, depth=3, thick=1.6)
    K.paint_dots(litter, rng, 22, "#6a5a40", "#8a7a5a", 3, 7, (0.2, 0.8))
    veg.put("litter", 768, 512, litter)
    veg_mat, veg_paths = veg.save(outdir, alpha=True)

    grass = K.Atlas(PACKAGE + "_grass", 512)
    grass.put("cord", 0, 0, K.paint_blades(K.tile(256), rng, 130, "#4c4f2c", "straw", height=(0.6, 0.97), width=(0.8, 1.6)))
    grass.put("cord2", 256, 0, K.paint_blades(K.tile(256), rng, 115, "#55552f", "#8f8558", height=(0.5, 0.95), width=(0.8, 1.5)))
    grass.put("sedge", 0, 256, K.paint_blades(K.tile(256), rng, 150, "#3f4626", "sedge", height=(0.35, 0.8), width=(0.6, 1.2), lean=0.6))
    grass.put("sedge2", 256, 256, K.paint_blades(K.tile(256), rng, 140, "#4a4a2a", "#7d7650", height=(0.3, 0.7), width=(0.6, 1.2), lean=0.7))
    grass_mat, grass_paths = grass.save(outdir, alpha=True)

    rock = K.Atlas(PACKAGE + "_rock", 1024)
    rock.put("mud", 0, 0, K.scan_tile("brown_mud/textures/brown_mud_diff_1k.jpg", 512, "swamp_mud", 0.8, 0.6), K.scan_normal("brown_mud/textures/brown_mud_nor_gl_1k.jpg", 512), K.scan_rough("brown_mud/textures/brown_mud_rough_1k.jpg", 512))
    rock.put("stone", 512, 0, K.scan_tile("lichen_rock/textures/lichen_rock_diff_1k.jpg", 512, "#5b5443", 0.85, 0.45), K.scan_normal("lichen_rock/textures/lichen_rock_nor_gl_1k.jpg", 512), K.scan_rough("lichen_rock/textures/lichen_rock_rough_1k.jpg", 512))
    logb = K.scan_tile("dead_tree_trunk/textures/dead_tree_trunk_diff_1k.jpg", 512, "#4e4636", 0.85, 0.5)
    rock.put("log", 0, 512, logb, K.scan_normal("dead_tree_trunk/textures/dead_tree_trunk_nor_gl_1k.jpg", 512))
    end = K.tile(512, alpha=1.0)
    yy, xx = np.mgrid[0:512, 0:512].astype(np.float32) / 512
    rr = np.sqrt((xx - 0.5) ** 2 + (yy - 0.5) ** 2)
    ringv = 0.5 + 0.5 * np.sin(rr * 90)
    end[..., :3] = K.hexrgb("#6b5a44") * (0.75 + 0.25 * ringv[..., None])
    end[rr > 0.45, :3] = K.hexrgb("#3b2f25")
    rock.put("logend", 512, 512, end)
    rock_mat, rock_paths = rock.save(outdir, alpha=False, with_rough=True)
    return (veg, veg_mat, veg_paths), (grass, grass_mat, grass_paths), (rock, rock_mat, rock_paths)


def dead_bare(rng, V, mat):
    b = K.Builder()
    h = 19.0
    pts = [Vector((0, 0, -0.5)), Vector((0.2, 0, 4)), Vector((0.5, 0.3, 9)), Vector((0.3, 0.6, 13))]
    b.tube(pts, [0.9, 0.62, 0.45, 0.3], V.rects["bark_dead"], sides=7, v_scale=0.05)
    tips = []
    for i in range(4):
        a = i * 1.7 + rng.uniform(-0.3, 0.3)
        d = Vector((math.cos(a), math.sin(a), 1.3))
        K.grow_branches(b, rng, pts[1 + min(i, 2)] + Vector((0, 0, 1.5)), d, 6.0, 0.36, V.rects["bark_dead"], 3, spread=0.75, sides=5, segs=3, tips=tips, gnarl=0.22, min_r=0.06)
    K.grow_branches(b, rng, pts[-1], Vector((0.1, 0.1, 1)), 6.0, 0.3, V.rects["bark_dead"], 3, spread=0.6, sides=5, segs=3, tips=tips, min_r=0.06)
    for p, d in tips[::2]:
        b.crossed(p - d * 0.6, 3.0, 2.8, V.rects["twigs"], n=1, rot=rng.uniform(0, 3), lean=d * 0.6)
    return b.finish("veg_swamp_dead_bare", mat), h


def mangrove(rng, V, mat, variant=0, name="veg_swamp_mangrove"):
    b = K.Builder()
    rk = V.rects["bark_dark"]
    base_z = (4.0, 3.2)[variant]
    for i in range(9 - variant):
        a = 2 * math.pi * i / (9 - variant) + rng.uniform(-0.2, 0.2)
        out = Vector((math.cos(a), math.sin(a), 0))
        rr = rng.uniform(3.6, 5.2)
        pts = [Vector((0, 0, base_z)) + out * 0.4]
        for k in range(1, 6):
            u = k / 5
            pts.append(out * (0.4 + rr * u) + Vector((0, 0, base_z * (1 - u) + 1.8 * math.sin(u * math.pi) - 0.3 * u)))
        b.tube(pts, [0.32, 0.28, 0.24, 0.2, 0.17, 0.15], rk, sides=5, v_scale=0.08)
    # L3: forked trunk over the prop roots, crown of separated branch-card clusters.
    K.tiered(b, rng, rk, [V.rects["mangrove_leaf"]], V.rects["shade"], (15.5, 13.5)[variant], 0.62, ((6.5, 6.0, 3.6), (5.5, 6.5, 3.2))[variant],
           core=7, core_size=3.0, fork=0.55, leaders=(3, 2)[variant], groups=6, clusters=(30, 26)[variant], cards=7, card=3.2, mind=2.4, sides=7,
           lean=((0.02, 0.0), (-0.04, 0.03))[variant], depth=(0.45, 1.0))
    return b.finish(name, mat), 16


def cypress(rng, V, mat, variant=0, name="veg_swamp_cypress"):
    b = K.Builder()
    rk = V.rects["bark_dark"]
    h = (26.0, 22.0)[variant]
    # Fluted, flared base (buttress) and knees, then a forked crown of cypress clusters with moss.
    pts = [Vector((0, 0, -0.5)), Vector((0, 0, 1.2)), Vector((0.1, 0, 3)), Vector((0.2, 0.1, 8))]
    b.tube(pts, [2.2, 1.5, 0.95, 0.75], rk, sides=10, v_scale=0.04, rib=0.18, ribs=5)
    for i in range(7 - 2 * variant):
        a = rng.uniform(0, 2 * math.pi)
        r = rng.uniform(2.8, 4.8)
        c = Vector((math.cos(a) * r, math.sin(a) * r, -0.2))
        b.tube([c, c + Vector((0, 0, rng.uniform(0.8, 1.6)))], [0.32, 0.08], rk, sides=5, v_scale=0.1)
    moss = V.rects["moss"]

    def drape(p):
        if rng.uniform(0, 1) < 0.45:
            s = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), 0)).normalized()
            ln = rng.uniform(3.0, 5.5)
            b.card(p - Vector((0, 0, ln)), Vector((0, 0, 1)), s, 1.4, ln, moss, rows=2)

    K.tiered(b, rng, rk, [V.rects["cypress_leaf"]], V.rects["shade"], h, 0.75, ((6.0, 5.5, 7.5), (6.5, 5.0, 6.0))[variant], tiers=3,
           core=8, core_size=3.0, fork=0.42, leaders=2, groups=6, clusters=(36, 30)[variant], cards=7, card=3.0, mind=2.4, sides=8,
           lean=((0.01, 0.01), (0.04, -0.02))[variant], hang=drape)
    return b.finish(name, mat), 27


def swamp_bush(rng, V, mat):
    b = K.Builder()
    # L3: separated branch-card clumps instead of a 420-quad ball.
    K.bush(b, rng, 2.6, 4.2, 20, 12, 2.0, [V.rects["bush_a"], V.rects["bush_b"]])
    for i in range(10):
        a = 2 * math.pi * i / 10
        b.card(Vector((0, 0, 0)), Vector((math.cos(a) * 0.6, math.sin(a) * 0.6, 1)), Vector((-math.sin(a), math.cos(a), 0)), 0.5, 1.6, V.rects["twigs"], rows=1)
    return b.finish("veg_swamp_swamp_bush", mat), 5


def marsh_fern(rng, V, mat):
    b = K.Builder()
    for i in range(48):
        a = 2 * math.pi * i / 48 + rng.uniform(-0.1, 0.1)
        out = Vector((math.cos(a), math.sin(a), 0))
        side = Vector((-out.y, out.x, 0))
        ln = rng.uniform(1.8, 2.8)
        up = (out * rng.uniform(0.4, 0.9) + Vector((0, 0, 1))).normalized()
        b.card(Vector((0, 0, 0)), up, side, ln * 0.55, ln, V.rects["fern"], bend=out * ln * 0.5 - Vector((0, 0, ln * 0.35)), rows=5)
    return b.finish("veg_swamp_marsh_fern", mat), 3


def cordgrass(rng, G, mat):
    b = K.Builder()
    K.grass_cluster(b, rng, [G.rects["cord"], G.rects["cord2"]], 4.0, 1.0, 32, skirt=0, width=1.4)
    return b.finish("veg_swamp_cordgrass", mat), 4


def sedge(rng, G, mat):
    b = K.Builder()
    K.grass_cluster(b, rng, [G.rects["sedge"], G.rects["sedge2"]], 3.0, 0.9, 28, width=1.5)
    return b.finish("veg_swamp_sedge_card", mat), 3


def mud_stone(rng, R, mat):
    b = K.Builder()
    b.rock(Vector((0, 0, 0.6)), (2.6, 2.2, 1.7), R.rects["stone"], rng, sub=3, rough=0.25, flat=0.4, strata=0.55)
    b.rock(Vector((0.4, 0.2, -0.1)), (3.2, 2.8, 0.7), R.rects["mud"], rng, sub=2, rough=0.3, flat=0.3)
    return b.finish("rock_swamp_mud_stone", mat), 2.5


def rotting_log(rng, R, mat):
    b = K.Builder()
    pts = [Vector((-6, 0, 0.0)), Vector((-3, 0.2, 0.45)), Vector((0, 0.1, 0.6)), Vector((3, -0.2, 0.5)), Vector((6, 0, 0.15))]
    b.tube(pts, [0.95, 1.0, 0.95, 0.85, 0.75], R.rects["log"], sides=16, v_scale=0.08, jitter=0.06, rng=rng, cap=True, cap_rect=R.rects["logend"])
    # stub branches
    for i in range(4):
        x = rng.uniform(-4, 4)
        a = rng.uniform(0.3, 2.8)
        b.tube([Vector((x, 0, 0.8)), Vector((x + 0.5, math.cos(a) * 1.6, 0.8 + math.sin(a) * 1.6))], [0.28, 0.12], R.rects["log"], sides=6, v_scale=0.1)
    return b.finish("rock_swamp_rotting_log", mat), 2


def dead_lean(rng, V, mat):
    """Biome2 (R11-3 dead forest): a bare leaning snag, low-poly (about 300 tris) so groves of it
    fit the island triangle budget; same bark/twig rects as dead_bare (no new atlas tiles)."""
    b = K.Builder()
    lean = Vector((0.42, 0.12, 1)).normalized()
    pts = [Vector((0, 0, -0.5)), lean * 4.0, lean * 8.5 + Vector((0.3, 0, 0)), lean * 12.5 + Vector((0.9, 0.2, 0))]
    b.tube(pts, [0.7, 0.5, 0.36, 0.2], V.rects["bark_dead"], sides=6, v_scale=0.05)
    tips = []
    for i in range(3):
        a = i * 2.1 + rng.uniform(-0.3, 0.3)
        d = Vector((math.cos(a) * 0.9, math.sin(a) * 0.9, 1.0))
        K.grow_branches(b, rng, pts[1 + i], d, 4.2, 0.24, V.rects["bark_dead"], 1, spread=0.7, sides=4, segs=2, tips=tips, gnarl=0.3, min_r=0.06)
    for p, d in tips[::3]:
        b.crossed(p - d * 0.4, 2.2, 2.0, V.rects["twigs"], n=1, rot=rng.uniform(0, 3), lean=d * 0.6)
    return b.finish("veg_swamp_dead_lean", mat), 13


def reed_clump(rng, G, mat):
    """Biome2: tall reed/cordgrass clump for pool rims (grass atlas, about 60 tris)."""
    b = K.Builder()
    K.grass_cluster(b, rng, [G.rects["cord"], G.rects["sedge"]], 5.5, 1.1, 14, width=1.2)
    return b.finish("veg_swamp_reed_clump", mat), 5.5


def litter(rng, V, mat):
    b = K.Builder()
    b.disc(Vector((0, 0, 0)), 3.0, V.rects["litter"], segs=14, rings=2, rng=rng, lift=0.05)
    return b.finish("clutter_swamp_litter", mat), 0.1


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    rng = np.random.default_rng(SEED)
    (V, vm, vp), (G, gm, gp), (R, rm, rp) = atlases(outdir, rng)
    objs = []
    for fn, at, m in (
        (dead_bare, V, vm),
        (mangrove, V, vm),
        (lambda r, a, mm: mangrove(r, a, mm, 1, "veg_swamp_mangrove_b"), V, vm),
        (cypress, V, vm),
        (lambda r, a, mm: cypress(r, a, mm, 1, "veg_swamp_cypress_b"), V, vm),
        (swamp_bush, V, vm),
        (marsh_fern, V, vm),
        (cordgrass, G, gm),
        (sedge, G, gm),
        (mud_stone, R, rm),
        (rotting_log, R, rm),
        (litter, V, vm),
        (dead_lean, V, vm),
        (reed_clump, G, gm),
    ):
        o, _ = fn(rng, at, m)
        objs.append(o)
    K.row_layout(objs)
    means = {k: V.mean_hex(k) for k in V.rects}
    means.update({k: G.mean_hex(k) for k in G.rects})
    means.update({k: R.mean_hex(k) for k in R.rects})
    K.export_package(PACKAGE, outdir, objs, {"seed": SEED, "atlas_means": means, "maps": {"veg": vp, "grass": gp, "rock": rp}})


main()
