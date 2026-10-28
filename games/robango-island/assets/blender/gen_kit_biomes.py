"""B1b desert (R11-7), tundra (R11-6) and volcano (R11-4) kits: one package per biome.

blender -b --factory-startup --python gen_kit_biomes.py -- <outdir> [desert|tundra|volcano]
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from mathutils import Vector

import common as C
import kit_b1b as K

SEEDS = {"desert": 4311, "tundra": 4321, "volcano": 4331}


def leafy(b, rng, rect, center, radius, height, n, w=(1.0, 1.4)):
    for i in range(n):
        z = rng.uniform(-0.2, 1.0)
        a = rng.uniform(0, 2 * math.pi)
        r = math.sqrt(max(0, 1 - z * z))
        d = Vector((r * math.cos(a), r * math.sin(a), z))
        c = center + Vector((d.x * radius, d.y * radius, max(0.15, (d.z * 0.8 + 0.2) * height))) * rng.uniform(0.7, 1.0)
        out = Vector((d.x, d.y, d.z * 0.6 + 0.4)).normalized()
        tip = (out * 0.7 + Vector((0, 0, 0.5))).normalized()
        side = tip.cross(out)
        side = side.normalized() if side.length > 1e-3 else Vector((1, 0, 0))
        s = rng.uniform(*w)
        b.quad([c - side * s / 2, c + side * s / 2, c + side * s / 2 + tip * s, c - side * s / 2 + tip * s], rect)


def snag(b, rng, rect, twig, h, r0, depth, tw=2.6, every=2):
    pts = [Vector((0, 0, -0.4)), Vector((0.2, 0, h * 0.35)), Vector((0.4, 0.2, h * 0.65))]
    b.tube(pts, [r0, r0 * 0.7, r0 * 0.5], rect, sides=7, v_scale=0.05)
    tips = []
    for i in range(4):
        a = i * 1.6 + rng.uniform(-0.3, 0.3)
        K.grow_branches(b, rng, pts[1 + i % 2], Vector((math.cos(a), math.sin(a), 1.2)), h * 0.32, r0 * 0.42, rect, depth, spread=0.75, sides=5, segs=3, tips=tips, gnarl=0.25, min_r=0.05)
    if twig:
        for p, d in tips[::every]:
            b.crossed(p - d * 0.5, tw, tw * 0.9, twig, n=1, rot=rng.uniform(0, 3), lean=d * 0.6)


def mat_patch(b, rng, rect, radius):
    b.disc(Vector((0, 0, 0)), radius, rect, segs=14, rings=3, rng=rng, lift=0.06)


# ------------------------------------------------------------------ desert


def desert(rng, outdir):
    V = K.Atlas("RobangoKitDesert_veg", 1024)
    V.put("cactus", 0, 0, K.cactus_tile(512, rng))
    V.put("bark", 512, 0, K.scan_tile("dead_tree_trunk/textures/dead_tree_trunk_diff_1k.jpg", 512, "#8a7c6a", 0.85, 0.3)[:, :256], K.scan_normal("dead_tree_trunk/textures/dead_tree_trunk_nor_gl_1k.jpg", 512)[:, :256])
    V.put("twigs", 768, 0, K.paint_twigs(K.tile(256), rng, "#6e6458", "desert_twig", trunks=4, depth=6, spread=0.8))
    V.put("twigs2", 768, 256, K.paint_twigs(K.tile(256), rng, "#7a6a58", "#a09484", trunks=3, depth=6, spread=0.9))
    V.put("agave", 0, 512, K.paint_leaf(K.tile(256), "agave", "#8f9a80", spine="#3a3324", waist=0.3, teeth=14))
    V.put("agave2", 256, 512, K.paint_leaf(K.tile(256), "#5f6a52", "#a0a07a", spine="#3a3324", waist=0.26, teeth=12))
    clut = K.tile(256)
    K.paint_dots(clut, rng, 70, "#7a5e44", "#b08a62", 2, 6)
    V.put("pebbles", 512, 512, clut)
    bones = K.tile(256)
    K.paint_twigs(bones, rng, "#c9bca0", "#e0d6c0", trunks=2, depth=2, spread=1.2, thick=4.0)
    V.put("dry_twig_litter", 768, 512, bones)
    V.put("desert_leaf", 0, 768, K.leaf_cluster_tile(256, rng, "#6a6a44", sat=0.4, leaves=18))
    vm, vp = V.save(outdir, alpha=True)
    G = K.Atlas("RobangoKitDesert_grass", 512)
    G.put("dry", 0, 0, K.paint_blades(K.tile(256), rng, 70, "#8a7448", "desert_straw", height=(0.3, 0.8), width=(0.6, 1.1), lean=0.8))
    G.put("dry2", 256, 0, K.paint_blades(K.tile(256), rng, 56, "#7a6440", "#c2a878", height=(0.25, 0.6), width=(0.6, 1.0), lean=0.9))
    gm, gp = G.save(outdir, alpha=True)
    R = K.Atlas("RobangoKitDesert_rock", 1024)
    R.put("sandstone", 0, 0, K.scan_tile("sandstone_cracks/textures/sandstone_cracks_diff_1k.jpg", 512, "sandstone", 0.8, 0.6), K.scan_normal("sandstone_cracks/textures/sandstone_cracks_nor_gl_1k.jpg", 512), K.scan_rough("sandstone_cracks/textures/sandstone_cracks_rough_1k.jpg", 512))
    R.put("rockface", 512, 0, K.scan_tile("rock_face/textures/rock_face_diff_1k.jpg", 512, "sand_rock", 0.85, 0.5), K.scan_normal("rock_face/textures/rock_face_nor_gl_1k.jpg", 512), K.scan_rough("rock_face/textures/rock_face_rough_1k.jpg", 512))
    rm, rp = R.save(outdir, alpha=False, with_rough=True)

    objs = []
    b = K.Builder()  # column cactus with arms
    b.tube([Vector((0, 0, -0.3)), Vector((0, 0, 3)), Vector((0, 0, 6)), Vector((0, 0, 9)), Vector((0, 0, 11.5)), Vector((0, 0, 12.2))], [0.85, 0.84, 0.82, 0.78, 0.7, 0.2], V.rects["cactus"], sides=24, v_scale=0.06, rib=0.08, ribs=12)
    for a, z, ln in ((0.4, 4.5, 3.2), (3.4, 6.0, 2.6)):
        o = Vector((math.cos(a), math.sin(a), 0))
        p0 = Vector((0, 0, z))
        b.tube([p0, p0 + o * 1.8 + Vector((0, 0, 0.3)), p0 + o * 2.0 + Vector((0, 0, 1.2)), p0 + o * 2.0 + Vector((0, 0, ln + 1.2)), p0 + o * 2.0 + Vector((0, 0, ln + 1.6))], [0.5, 0.5, 0.5, 0.45, 0.12], V.rects["cactus"], sides=16, v_scale=0.06, rib=0.08, ribs=8)
    objs.append(b.finish("veg_desert_column_cactus", vm))
    b = K.Builder()
    snag(b, rng, V.rects["bark"], V.rects["twigs"], 13, 0.55, 3)
    objs.append(b.finish("veg_desert_dead_snag", vm))
    b = K.Builder()  # L3 variant: shorter, wider-spread snag
    snag(b, rng, V.rects["bark"], V.rects["twigs2"], 10, 0.5, 3, tw=2.2)
    objs.append(b.finish("veg_desert_dead_snag_b", vm))
    b = K.Builder()  # barrel cactus
    b.tube([Vector((0, 0, -0.2)) + Vector((0, 0, z)) for z in (0, 0.6, 1.4, 2.1, 2.5)], [0.9, 1.15, 1.15, 0.9, 0.35], V.rects["cactus"], sides=20, v_scale=0.12, rib=0.1, ribs=10)
    for i in range(3):
        a = i * 2.1
        b.tube([Vector((math.cos(a) * 1.4, math.sin(a) * 1.4, -0.1)), Vector((math.cos(a) * 1.5, math.sin(a) * 1.5, 0.8)), Vector((math.cos(a) * 1.5, math.sin(a) * 1.5, 1.1))], [0.45, 0.42, 0.1], V.rects["cactus"], sides=10, v_scale=0.15, rib=0.1, ribs=5)
    objs.append(b.finish("veg_desert_barrel_cactus", vm))
    b = K.Builder()  # dry grey bush: fan of twig cards
    for i in range(40):
        a = math.pi * i / 40
        lean = Vector((math.cos(a * 2) * 0.35, math.sin(a * 2) * 0.35, 0))
        b.crossed(Vector((rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4), 0)), rng.uniform(3.0, 4.2), rng.uniform(2.6, 3.6), V.rects["twigs" if i % 2 else "twigs2"], n=1, rot=a, lean=lean, rows=4, bend=0.5)
    objs.append(b.finish("veg_desert_dry_bush", vm))
    b = K.Builder()  # agave rosette
    for ring, (cnt, ln, tilt) in enumerate(((14, 2.3, 0.9), (12, 2.0, 0.55), (10, 1.5, 0.25), (6, 1.0, 0.08))):
        for i in range(cnt):
            a = 2 * math.pi * (i + ring * 0.5) / cnt
            o = Vector((math.cos(a), math.sin(a), 0))
            up = (o * tilt + Vector((0, 0, 1))).normalized()
            b.card(o * 0.15, up, Vector((-o.y, o.x, 0)), 0.75, ln, V.rects["agave" if i % 2 else "agave2"], bend=o * 0.4, rows=4)
    objs.append(b.finish("veg_desert_agave", vm))
    b = K.Builder()
    K.grass_cluster(b, rng, [G.rects["dry"], G.rects["dry2"]], 1.5, 0.7, 20, width=1.0)
    objs.append(b.finish("veg_desert_sparse_dry", gm))
    b = K.Builder()  # second shrub type: low creosote-like bush, leaf clusters on twigs
    for i in range(16):
        a = math.pi * i / 16
        b.crossed(Vector((0, 0, 0)), rng.uniform(2.0, 2.8), rng.uniform(1.8, 2.4), V.rects["twigs2"], n=1, rot=a, lean=Vector((math.cos(2 * a) * 0.3, math.sin(2 * a) * 0.3, 0)), rows=3, bend=0.3)
    leafy(b, rng, V.rects["desert_leaf"], Vector((0, 0, 0.3)), 1.3, 1.6, 50, (0.6, 0.9))
    objs.append(b.finish("clutter_desert_creosote", vm))
    b = K.Builder()  # layered sandstone chunk
    for i, (h, s) in enumerate(((1.4, 4.6), (1.2, 3.8), (1.0, 2.8))):
        b.rock(Vector((rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), i * 1.05 + 0.4)), (s, s * 0.8, h * 0.6), R.rects["sandstone"], rng, sub=3, rough=0.12, flat=0.6, scale=1.0)
    objs.append(b.finish("rock_desert_sandstone_chunk", rm))
    b = K.Builder()  # wind-carved boulder: undercut mushroom shape
    b.rock(Vector((0, 0, 1.4)), (3.0, 2.6, 1.8), R.rects["rockface"], rng, sub=3, rough=0.25)
    b.rock(Vector((0.3, 0, 4.4)), (5.2, 4.2, 2.0), R.rects["rockface"], rng, sub=3, rough=0.3)
    objs.append(b.finish("rock_desert_wind_boulder", rm))
    b = K.Builder()
    mat_patch(b, rng, V.rects["pebbles"], 3.0)
    objs.append(b.finish("clutter_desert_pebbles", vm))
    b = K.Builder()
    mat_patch(b, rng, V.rects["dry_twig_litter"], 2.6)
    objs.append(b.finish("clutter_desert_twig_litter", vm))
    return objs, (V, G, R), {"veg": vp, "grass": gp, "rock": rp}


# ------------------------------------------------------------------ tundra


def tundra(rng, outdir):
    V = K.Atlas("RobangoKitTundra_veg", 1024)
    V.put("pine_bark", 0, 0, K.scan_tile("pine_bark/textures/pine_bark_diff_1k.jpg", 512, "bark_dark", 0.85, 0.5)[:, :256], K.scan_normal("pine_bark/textures/pine_bark_nor_gl_1k.jpg", 512)[:, :256])
    V.put("birch_bark", 256, 0, K.scan_tile("bark_willow/textures/bark_willow_diff_1k.jpg", 512, "birch_bark", 0.9, 0.2)[:, :256], K.scan_normal("bark_willow/textures/bark_willow_nor_gl_1k.jpg", 512)[:, :256])
    tw = K.load_scan("fir_tree_01/textures/fir_tree_01_twig_diff_1k.jpg")
    al = K.load_scan("fir_tree_01/textures/fir_tree_01_twig_alpha_1k.jpg")
    m = al[..., 0] > 0.5
    tw = K.grade(tw, "pine", 0.8, 0.55, mask=m)
    tw[..., 3] = m
    tw = tw.reshape(512, 2, 512, 2, 4).mean((1, 3))
    tw[..., 3] = (tw[..., 3] > 0.5).astype(np.float32)
    snowy = K.snow_overlay(tw.copy(), 0.5, rng)
    V.put("needles_snow", 512, 0, snowy)
    V.put("frost_twigs", 0, 512, K.paint_twigs(K.tile(256), rng, "#5a4a3e", "frost", trunks=4, depth=6, spread=0.85))
    fr = K.paint_twigs(K.tile(256), rng, "#4a3e34", "#8a7a6a", trunks=3, depth=6)
    V.put("frost_twigs2", 256, 512, K.snow_overlay(fr, 0.35, rng))
    lic = K.tile(256)
    K.paint_blotch(lic, rng, "lichen", "#a8a07a", scale=7, cover=0.7, seed=5)
    K.paint_dots(lic, rng, 25, "#b0442e", "#8a7a5a", 1.5, 3, (0.25, 0.75))
    V.put("lichen", 0, 768, lic)
    sn = K.tile(256)
    K.paint_blotch(sn, rng, "snow", "#c4ccd2", scale=5, cover=0.75, seed=9)
    K.paint_dots(sn, rng, 12, "#5a5450", "#7a746c", 3, 8, (0.25, 0.75))
    V.put("snowpatch", 256, 768, sn)
    leaves = K.sprig_tile(256, rng, "#6a6a3a", "#8a8070", sat=0.5, leaves=50, leaf_h=44, sides=6)
    V.put("birch_leaf", 512, 768, K.snow_overlay(leaves, 0.2, rng))
    vm, vp = V.save(outdir, alpha=True)
    G = K.Atlas("RobangoKitTundra_grass", 512)
    for i, (x, y) in enumerate(((0, 0), (256, 0))):
        t = K.paint_blades(K.tile(256), rng, 140, "#7a7058", "frost_straw", height=(0.4, 0.9), width=(0.6, 1.2), lean=0.7)
        G.put(f"tussock{i}", x, y, K.snow_overlay(t, 0.15 + 0.15 * i, rng))
    gm, gp = G.save(outdir, alpha=True)
    R = K.Atlas("RobangoKitTundra_rock", 1024)
    lr = K.scan_tile("lichen_rock/textures/lichen_rock_diff_1k.jpg", 512, "#6e6c66", 0.8, 0.4)
    R.put("rock", 0, 0, lr, K.scan_normal("lichen_rock/textures/lichen_rock_nor_gl_1k.jpg", 512), K.scan_rough("lichen_rock/textures/lichen_rock_rough_1k.jpg", 512))
    R.put("snow", 512, 0, K.scan_tile("snow_02/textures/snow_02_diff_1k.jpg", 512, "snow", 0.7, 0.5), K.scan_normal("snow_02/textures/snow_02_nor_gl_1k.jpg", 512), K.scan_rough("snow_02/textures/snow_02_rough_1k.jpg", 512))
    ice = K.scan_tile("rock_face/textures/rock_face_diff_1k.jpg", 512, "ice", 0.9, 0.5)
    R.put("ice", 0, 512, ice, K.scan_normal("rock_face/textures/rock_face_nor_gl_1k.jpg", 512), np.full((512, 512, 4), 0.25, np.float32))
    rm, rp = R.save(outdir, alpha=False, with_rough=True)

    objs = []
    def pine(name, h, tiers, r0, per):
        # Snow-loaded pine: trunk + tiers of drooping needle cards; L3 adds a second, slimmer variant.
        b = K.Builder()
        b.tube([Vector((0, 0, -0.4)), Vector((0, 0, h * 0.45)), Vector((0, 0, h))], [0.6, 0.38, 0.08], V.rects["pine_bark"], sides=7, v_scale=0.05)
        for t in range(tiers):
            z = 3.0 + t * (h - 4.0) / tiers
            rad = r0 * (1 - t / (tiers + 1)) + 0.5
            for i in range(per):
                a = 2 * math.pi * (i + t * 0.37) / per + rng.uniform(-0.15, 0.15)
                o = Vector((math.cos(a), math.sin(a), 0))
                b.card(Vector((0, 0, z)), (o + Vector((0, 0, 0.15))).normalized(), Vector((-o.y, o.x, 0)), rad * 0.85, rad, V.rects["needles_snow"], bend=Vector((0, 0, -rad * 0.35)), rows=2)
        objs.append(b.finish(name, vm))

    pine("veg_tundra_snow_pine", 22, 12, 4.8, 11)
    pine("veg_tundra_snow_pine_b", 18, 10, 3.6, 9)

    def birch(name, h, lean, clusters):
        # L3: twisted dwarf birch with a clustered branch-card crown (gaps between clumps).
        b = K.Builder()
        K.hero(b, rng, V.rects["birch_bark"], [V.rects["birch_leaf"]], h, 0.32, (3.2, 3.0, 2.6), fork=0.4, leaders=3, groups=5,
               clusters=clusters, cards=6, card=1.9, mind=1.4, sides=6, lean=lean)
        objs.append(b.finish(name, vm))

    birch("veg_tundra_dwarf_birch", 8.0, (0.05, 0.02), 16)
    birch("veg_tundra_dwarf_birch_b", 6.5, (-0.06, 0.04), 13)
    b = K.Builder()  # frost shrub
    for i in range(16):
        a = math.pi * i / 16
        b.crossed(Vector((rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), 0)), rng.uniform(2.6, 3.6), rng.uniform(2.4, 3.4), V.rects["frost_twigs" if i % 2 else "frost_twigs2"], n=1, rot=a, lean=Vector((math.cos(2 * a) * 0.3, math.sin(2 * a) * 0.3, 0)), rows=4, bend=0.4)
    leafy(b, rng, V.rects["birch_leaf"], Vector((0, 0, 0.2)), 1.2, 2.2, 40, (0.6, 0.9))
    objs.append(b.finish("veg_tundra_frost_shrub", vm))
    b = K.Builder()
    mat_patch(b, rng, V.rects["lichen"], 3.0)
    objs.append(b.finish("veg_tundra_lichen_mat", vm))
    b = K.Builder()
    K.grass_cluster(b, rng, [G.rects["tussock0"], G.rects["tussock1"]], 2.5, 0.8, 28, width=1.3)
    objs.append(b.finish("veg_tundra_frost_tussock", gm))
    b = K.Builder()  # snowy ice-crusted boulder: rock + snow cap
    b.rock(Vector((0, 0, 1.6)), (3.2, 2.7, 2.2), R.rects["rock"], rng, sub=3, rough=0.3)
    b.rock(Vector((0.1, 0.1, 3.0)), (2.7, 2.2, 0.9), R.rects["snow"], rng, sub=3, rough=0.2, flat=0.2)
    objs.append(b.finish("rock_tundra_ice_boulder", rm))
    b = K.Builder()  # blue ice shard cluster
    for i in range(9):
        a = rng.uniform(0, 2 * math.pi)
        r = rng.uniform(0, 1.8)
        b.prism(Vector((math.cos(a) * r, math.sin(a) * r, -0.3)), rng.uniform(0.5, 1.0), rng.uniform(3, 8), 5, R.rects["ice"], rng, tilt=Vector((math.cos(a), math.sin(a), 0)) * rng.uniform(0.1, 0.5), top_jit=0.3)
    objs.append(b.finish("rock_tundra_ice_shard", rm))
    b = K.Builder()
    mat_patch(b, rng, V.rects["snowpatch"], 3.2)
    objs.append(b.finish("clutter_tundra_snow_patch", vm))
    return objs, (V, G, R), {"veg": vp, "grass": gp, "rock": rp}


# ------------------------------------------------------------------ volcano


def volcano(rng, outdir):
    V = K.Atlas("RobangoKitVolcano_veg", 1024)
    ch = K.scan_tile("dead_tree_trunk/textures/dead_tree_trunk_diff_1k.jpg", 512, "char", 0.9, 0.2)
    ch[..., :3] *= 0.85
    V.put("char_bark", 0, 0, ch[:, :256], K.scan_normal("dead_tree_trunk/textures/dead_tree_trunk_nor_gl_1k.jpg", 512)[:, :256])
    V.put("cycad_trunk", 256, 0, K.scan_tile("palm_tree_bark/palm_tree_bark_diff_1k.png", 512, "#4a3c2e", 0.85, 0.4)[:, :256], K.scan_normal("palm_tree_bark/palm_tree_bark_nor_gl_1k.png", 512)[:, :256])
    V.put("char_twigs", 512, 0, K.paint_twigs(K.tile(256), rng, "char", "#5a5048", trunks=3, depth=5))
    V.put("ash_twigs", 768, 0, K.paint_twigs(K.tile(256), rng, "#4a4440", "ash", trunks=4, depth=6, spread=0.85))
    V.put("frond", 512, 256, K.paint_frond(K.tile(256), rng, "#4a3e2a", "cycad", "#7a7a46"))
    V.put("frond_dry", 768, 256, K.paint_frond(K.tile(256), rng, "#4a3e2a", "#6e5a3a", "#8a6a40"))
    su = K.tile(256)
    K.paint_blotch(su, rng, "sulfur", "#d0bc5a", scale=6, cover=0.7, seed=11)
    V.put("sulfur", 0, 512, su)
    ash = K.tile(256)
    K.paint_blotch(ash, rng, "ash", "#8a8580", scale=5, cover=0.8, seed=13)
    K.paint_dots(ash, rng, 40, "#1e1a18", "#3a3430", 1.5, 4, (0.2, 0.8))
    V.put("ash", 256, 512, ash)
    vm, vp = V.save(outdir, alpha=True)
    G = K.Atlas("RobangoKitVolcano_grass", 512)
    G.put("burnt", 0, 0, K.paint_blades(K.tile(256), rng, 120, "#2e211c", "burnt_grass", height=(0.35, 0.85), width=(0.6, 1.2), lean=0.7))
    G.put("burnt2", 256, 0, K.paint_blades(K.tile(256), rng, 105, "#3a2a22", "#7a5a40", height=(0.3, 0.75), width=(0.6, 1.1), lean=0.8))
    gm, gp = G.save(outdir, alpha=True)
    R = K.Atlas("RobangoKitVolcano_rock", 1024)
    R.put("basalt", 0, 0, K.scan_tile("dark_rock/textures/dark_rock_diff_1k.jpg", 512, "basalt", 0.85, 0.4), K.scan_normal("dark_rock/textures/dark_rock_nor_gl_1k.jpg", 512), K.scan_rough("dark_rock/textures/dark_rock_rough_1k.jpg", 512))
    R.put("burned", 512, 0, K.scan_tile("burned_ground_01/textures/burned_ground_01_diff_1k.jpg", 512, "#2e2826", 0.8, 0.5), K.scan_normal("burned_ground_01/textures/burned_ground_01_nor_gl_1k.jpg", 512), K.scan_rough("burned_ground_01/textures/burned_ground_01_rough_1k.jpg", 512))
    ob = K.scan_tile("dark_rock/textures/dark_rock_diff_1k.jpg", 512, "obsidian", 0.9, 0.3)
    R.put("obsidian", 0, 512, ob, K.scan_normal("dark_rock/textures/dark_rock_nor_gl_1k.jpg", 512), np.full((512, 512, 4), 0.12, np.float32))
    crust = K.scan_tile("burned_ground_01/textures/burned_ground_01_diff_1k.jpg", 512, "#2a2422", 0.85, 0.4)
    K.paint_twigs(crust, rng, "#7a2a10", "ember", trunks=4, depth=3, spread=1.2, thick=1.3)  # glowing seams
    crust[..., 3] = 1.0
    R.put("crust", 512, 512, crust, K.scan_normal("burned_ground_01/textures/burned_ground_01_nor_gl_1k.jpg", 512))
    rm, rp = R.save(outdir, alpha=False, with_rough=True)

    objs = []
    b = K.Builder()
    snag(b, rng, V.rects["char_bark"], V.rects["char_twigs"], 15, 0.6, 2, tw=2.0, every=3)
    objs.append(b.finish("veg_volcano_charred", vm))
    b = K.Builder()  # L3 variant: shorter broken snag
    snag(b, rng, V.rects["char_bark"], V.rects["char_twigs"], 11, 0.55, 2, tw=1.8, every=3)
    objs.append(b.finish("veg_volcano_charred_b", vm))
    b = K.Builder()  # survivor cycad: stout trunk + frond crown
    b.tube([Vector((0, 0, -0.3)), Vector((0.1, 0, 2.5)), Vector((0.2, 0.1, 5.2))], [0.8, 0.7, 0.55], V.rects["cycad_trunk"], sides=10, v_scale=0.12, jitter=0.05, rng=rng)
    for i in range(18):
        a = 2 * math.pi * i / 18
        o = Vector((math.cos(a), math.sin(a), 0))
        up = (o * rng.uniform(0.6, 1.4) + Vector((0, 0, 1))).normalized()
        b.card(Vector((0.2, 0.1, 5.0)), up, Vector((-o.y, o.x, 0)), 1.5, 3.6, V.rects["frond" if i % 4 else "frond_dry"], bend=o * 1.0 - Vector((0, 0, 1.4)), rows=4)
    objs.append(b.finish("veg_volcano_survivor_cycad", vm))
    b = K.Builder()  # ash scrub
    for i in range(14):
        a = math.pi * i / 14
        b.crossed(Vector((rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), 0)), rng.uniform(2.2, 3.2), rng.uniform(2.0, 3.0), V.rects["ash_twigs"], n=1, rot=a, lean=Vector((math.cos(2 * a) * 0.3, math.sin(2 * a) * 0.3, 0)), rows=4, bend=0.4)
    objs.append(b.finish("veg_volcano_ash_scrub", vm))
    b = K.Builder()
    mat_patch(b, rng, V.rects["sulfur"], 2.0)
    objs.append(b.finish("veg_volcano_sulfur_moss", vm))
    b = K.Builder()
    K.grass_cluster(b, rng, [G.rects["burnt"], G.rects["burnt2"]], 2.0, 0.8, 28, width=1.2)
    objs.append(b.finish("veg_volcano_burnt_grass", gm))
    b = K.Builder()  # basalt columns
    for i in range(10):
        a = rng.uniform(0, 2 * math.pi)
        r = rng.uniform(0, 2.4)
        b.prism(Vector((math.cos(a) * r, math.sin(a) * r, -0.2)), rng.uniform(0.9, 1.3), rng.uniform(4, 13), 6, R.rects["basalt"], rng, top_jit=0.05)
    objs.append(b.finish("rock_volcano_basalt_columns", rm))
    b = K.Builder()
    b.rock(Vector((0, 0, 1.8)), (3.0, 2.5, 2.4), R.rects["obsidian"], rng, sub=3, rough=0.45, scale=0.9)
    objs.append(b.finish("rock_volcano_obsidian_boulder", rm))
    b = K.Builder()  # lava crust slab with ember seams
    b.rock(Vector((0, 0, 0.2)), (7.0, 5.5, 0.7), R.rects["crust"], rng, sub=3, rough=0.2, flat=0.3, scale=1.2)
    objs.append(b.finish("rock_volcano_lava_crust", rm))
    b = K.Builder()  # hot-spring rim: ring of stones around a shallow basin
    for i in range(13):
        a = 2 * math.pi * i / 13
        b.rock(Vector((math.cos(a) * 5.2, math.sin(a) * 5.2, 0.4)), (1.5, 1.2, 1.0), R.rects["basalt" if i % 3 else "burned"], rng, sub=2, rough=0.3)
    b.disc(Vector((0, 0, -0.3)), 4.6, R.rects["burned"], segs=14, rings=2, rng=rng, lift=0.0)
    objs.append(b.finish("rock_volcano_hot_spring_rim", rm))
    b = K.Builder()
    mat_patch(b, rng, V.rects["ash"], 3.4)
    objs.append(b.finish("clutter_volcano_ash_patch", vm))
    return objs, (V, G, R), {"veg": vp, "grass": gp, "rock": rp}


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :]
    biome = argv[1]
    outdir = C.out_dir()
    seed = SEEDS[biome]
    C.reset(seed)
    rng = np.random.default_rng(seed)
    objs, atl, maps = {"desert": desert, "tundra": tundra, "volcano": volcano}[biome](rng, outdir)
    K.row_layout(objs)
    means = {}
    for a in atl:
        means.update({k: a.mean_hex(k) for k in a.rects})
    K.export_package("RobangoKit" + biome.capitalize(), outdir, objs, {"seed": seed, "atlas_means": means, "maps": maps})


main()
