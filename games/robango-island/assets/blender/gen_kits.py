"""B1a biome kits: beach, jungle, grassland, savanna, lake (asset catalog sections 2-3).

One FBX package per biome (catalog package plan: "9 biome kits, 1 Model each"). Each package
holds one named mesh per catalog row (key = Model name) plus ground-clutter cards, sharing three
kit textures: a 1024 vegetation atlas (bark columns + leaf/frond/flower/clutter tiles), a 512
grass atlas (narrow blades) and a 1024 rock atlas (4 baked scan slots of 512).

Run (repo root): blender -b --factory-startup --python gen_kits.py -- <outdir> <biome>
Sources: CC0 Poly Haven under build/a2b/src (SOURCES.md). Seeds recorded per biome.
"""

import json
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy
import numpy as np
from mathutils import Vector

import common as C
import kitlib as K

SEEDS = {"beach": 5101, "jungle": 5102, "grassland": 5103, "savanna": 5104, "lake": 5105}
V = Vector
UP = V((0, 0, 1))

# Leaf sources: (diff, alpha, pixel rects x0,y0,x1,y1 y-down, base at the bottom of the rect)
SHRUB4 = ("shrub_04/textures/shrub_04_diff_1k.jpg", "shrub_04/textures/shrub_04_alpha_1k.png",
          [(135, 100, 232, 330), (540, 75, 628, 338), (440, 410, 552, 645), (618, 395, 712, 598), (238, 655, 338, 940), (562, 698, 652, 905)])
NETTLE = ("nettle_plant/textures/nettle_plant_diff_1k.png", "nettle_plant/textures/nettle_plant_alpha_1k.png",
          [(380, 160, 545, 350), (515, 390, 670, 590), (380, 640, 600, 860), (20, 575, 205, 740), (30, 770, 150, 915), (20, 60, 180, 250)])
CALATHEA = ("calathea_orbifolia_01/textures/calathea_orbifolia_01_diff_1k.png", "calathea_orbifolia_01/textures/calathea_orbifolia_01_alpha_1k.png",
            [(45, 25, 430, 470), (475, 15, 900, 445), (45, 535, 430, 975), (475, 525, 895, 950)])
FERN = ("fern_02/textures/fern_02_diff_1k.jpg", "fern_02/textures/fern_02_alpha_1k.png",
        [(92, 110, 240, 965), (330, 25, 465, 785), (735, 110, 870, 900), (525, 520, 640, 985)])
ROOIBOS = ("wild_rooibos_bush/textures/wild_rooibos_bush_diff_1k.png", "wild_rooibos_bush/textures/wild_rooibos_bush_alpha_1k.png",
           [(20, 25, 125, 140), (205, 30, 300, 140), (350, 25, 470, 140), (535, 40, 640, 140)])
TWIGS = ("wild_rooibos_bush/textures/wild_rooibos_bush_diff_1k.png", "wild_rooibos_bush/textures/wild_rooibos_bush_alpha_1k.png",
         [(20, 385, 255, 1005), (290, 500, 470, 1005), (490, 680, 595, 1005)])


def leaves(source, target, sat=0.6):
    diff, alpha, rects = source
    return [K.grade(K.crop(K.src(diff), K.src(alpha), r), target, 0.72, sat) for r in rects]


def cluster(rng, srcs, count, size, spread=0.32, lift=0.25):
    tile = np.zeros((256, 256, 4), np.float32)
    for k in range(count):
        leaf = srcs[rng.integers(len(srcs))]
        K.stamp(tile, leaf, 128 + rng.uniform(-1, 1) * 256 * spread, 256 * lift + rng.uniform(-30, 50),
                rng.uniform(-1.4, 1.4), size * rng.uniform(0.8, 1.15), 0.7 + 0.35 * k / count)
    return tile


def bark(name, target, sat=0.7):
    base = os.path.join(C.SRC_DIR, name, "textures")
    if not os.path.isdir(base):
        base = os.path.join(C.SRC_DIR, name)
    f = [p for p in os.listdir(base) if "_diff" in p][0]
    img = K.resize(K.load_px(os.path.join(base, f)), 1024, 128)
    img[..., 3] = 1
    return K.grade(img, target, 0.8, sat)


def clutter_tile(rng, tex, target, fill=0.7, sat=0.6):
    base = os.path.join(C.SRC_DIR, tex, "textures")
    f = [p for p in os.listdir(base) if "_diff" in p][0]
    return K.textured_blob(os.path.join(base, f), rng, 256, 256, target, sat, fill)


# ----------------------------------------------------------------- builders (1 unit = 1 stud)
def palm(m, A, height, lean, fronds, flen, fruit=True, curve=1.0):
    rings, sides = 14, 8
    def at(t):
        return V((math.sin(math.radians(lean)) * height * t ** (1.4 * curve), 0.04 * height * t * t, math.cos(math.radians(lean * t)) * height * t))
    pts = [at(i / rings) for i in range(rings + 1)]
    radii = [height * 0.028 * (1 - 0.35 * i / rings) + (0.08 if i % 2 == 0 else 0) for i in range(rings + 1)]
    radii[0] *= 1.5
    m.tube(pts, radii, sides, A.uv["bark0"])
    top = pts[-1]
    for f in range(fronds):
        yaw = 2 * math.pi * f / fronds + random.uniform(-0.2, 0.2)
        for roll in (0.0, 0.6):
            K.frond_strip(m, top, yaw, random.uniform(0.05, 0.7), flen * random.uniform(0.85, 1.1), flen * 0.33, A.uv["frond"], droop=2.2, roll=roll)
    for f in range(5):
        K.frond_strip(m, top - V((0, 0, 0.6)), 2 * math.pi * f / 5 + 0.3, -1.0, flen * 0.6, flen * 0.25, A.uv["dry"], droop=0.5)
    if fruit:
        for i in range(10):
            a = random.uniform(0, 2 * math.pi)
            m.swatch_ball(top + V((math.cos(a) * 0.6, math.sin(a) * 0.6, -random.uniform(0.4, 1.4))), 0.3, A.pt["fruit"], 1)


def tree(m, A, height, trunk_r, bark, crowns, leaf_keys, card, branches=5, sides=8, lean=0.0, fork=0.0):
    rings = 7
    pts = [V((lean * height * (i / rings) ** 2, 0, height * 0.55 * i / rings)) for i in range(rings + 1)]
    m.tube(pts, [trunk_r * (1.25 if i == 0 else 1 - 0.4 * i / rings) for i in range(rings + 1)], sides, A.uv[bark])
    top = pts[-1]
    for b in range(branches):
        a = 2 * math.pi * b / branches + random.uniform(-0.3, 0.3)
        d = V((math.cos(a), math.sin(a), 0))
        z0 = top.z * random.uniform(0.75, 1.0)
        start = V((top.x, top.y, z0))
        reach = height * random.uniform(0.18, 0.3) * (1 + fork)
        bp = [start, start + d * reach * 0.5 + V((0, 0, height * 0.12)), start + d * reach + V((0, 0, height * (0.2 - fork * 0.15)))]
        m.tube(bp, [trunk_r * 0.45, trunk_r * 0.3, trunk_r * 0.15], 5, A.uv[bark])
    uvs = [A.uv[k] for k in leaf_keys]
    for z, rx, rz, n in crowns:
        K.outward_cards(m, uvs, n, V((top.x, 0, z)), rx, rx * random.uniform(0.85, 1.1), rz, card, zmin=-0.35, top_cards=n // 6, top_z=rz * 0.75)


def sprig_tile(rng, source, target, twig, sat=0.6, **kw):
    """L3: branch-card tile (twig + side twigs + scanned leaves) for clustered crowns."""
    return K.sprig(rng, leaves(source, target, sat), K.hexrgb(twig), **kw)


def hero(m, A, bark, keys, height, trunk_r, crown, **kw):
    """L3: clustered branch-card tree (kitlib.branch_tree) on the kit bark column."""
    return K.branch_tree(lambda pts, radii, sides: m.tube(pts, radii, sides, A.uv[bark]), m.quad, random, height, trunk_r, crown,
                         [A.uv[k] for k in keys], **kw)


def bush(m, A, rx, rz, clusters, cards, card, keys, stems=5, A_bark="bark1"):
    """L3: shrub of separated branch-card clumps over a few stems (negative space between clumps)."""
    for i in range(stems):
        a = 2 * math.pi * i / stems + random.uniform(-0.3, 0.3)
        m.card(V((0, 0, 0)), UP, V((-math.sin(a), math.cos(a), 0)), rx * 0.1, rz * 0.7, A.uv[A_bark], bend=V((math.cos(a), math.sin(a), 0)) * rx * 0.45, rows=2)
    K.clustered_shrub(m.quad, random, rx, rz, clusters, cards, card, [A.uv[k] for k in keys])


def shrub(m, A, rx, rz, n, keys, card, stems=5, A_bark="bark1"):
    for i in range(stems):
        a = 2 * math.pi * i / stems
        m.card(V((0, 0, 0)), UP, V((-math.sin(a), math.cos(a), 0)), rx * 0.12, rz * 0.8, A.uv[A_bark], bend=V((math.cos(a), math.sin(a), 0)) * rx * 0.5, rows=2)
    K.outward_cards(m, [A.uv[k] for k in keys], n, V((0, 0, rz * 0.55)), rx, rx, rz * 0.55, card, zmin=-0.3, top_cards=n // 5, top_z=rz * 0.45)


def fern(m, A, n, length, keys, pitch=(0.5, 1.2), steps=5, width=0.38):
    for i in range(n):
        yaw = 2 * math.pi * i / n + random.uniform(-0.2, 0.2)
        L = length * random.uniform(0.75, 1.1)
        K.frond_strip(m, V((0, 0, 0.05)), yaw, random.uniform(*pitch), L, L * width, A.uv[keys[i % len(keys)]], droop=1.6, steps=steps)


def mat(m, A, size, n, keys, h=0.25):
    for i in range(n):
        a, r = random.uniform(0, 2 * math.pi), size * 0.45 * math.sqrt(random.random())
        c = V((math.cos(a) * r, math.sin(a) * r, random.uniform(0.05, h)))
        w = size * random.uniform(0.18, 0.3)
        t = V((math.cos(a + 1.3), math.sin(a + 1.3), random.uniform(-0.1, 0.25))).normalized()
        s = V((-t.y, t.x, 0)).normalized()
        m.quad([c - s * w / 2 - t * w / 2, c + s * w / 2 - t * w / 2, c + s * w / 2 + t * w / 2, c - s * w / 2 + t * w / 2], A.uv[keys[i % len(keys)]])


def ground_card(m, A, key, size, n=1):
    for i in range(n):
        a = random.uniform(0, math.pi)
        c = V((random.uniform(-0.2, 0.2) * size, random.uniform(-0.2, 0.2) * size, 0.06 + i * 0.01))
        t, s = V((math.cos(a), math.sin(a), 0)), V((-math.sin(a), math.cos(a), 0))
        w = size * random.uniform(0.8, 1.1)
        m.quad([c - s * w / 2 - t * w / 2, c + s * w / 2 - t * w / 2, c + s * w / 2 + t * w / 2, c - s * w / 2 + t * w / 2], A.uv[key])


def grass(m, G, keys, pairs, hmin, hmax, width, radius, rows=1, lean=0.35):
    K.grass_cluster(m, [G.uv[k] for k in keys], pairs, hmin, hmax, width, radius, lean, rows)


# ----------------------------------------------------------------- kit specs
def build_textures(biome, rng, outdir):
    A = K.Atlas(f"Kit_{biome}_veg", 1024)
    G = K.Atlas(f"Kit_{biome}_grass", 512)
    A.pt = {}
    T = lambda c, r: (256 + c * 256, r * 256)  # 3 cols x 4 rows of 256 tiles right of the bark columns
    P = K.hexrgb
    barks = {"beach": ("palm_tree_bark", "bark", "bark_brown_02", "bark_dark"),
             "jungle": ("palm_tree_bark", "bark", "bark_brown_02", "bark_dark"),
             "grassland": ("bark_brown_02", "bark", "bark_platanus", "#b9b2a2"),
             "savanna": ("bark_brown_02", "bark", "bark_platanus", "#8a7a62"),
             "lake": ("bark_willow", "bark", "bark_brown_02", "bark_dark")}[biome]
    A.put("bark0", 0, 0, bark(barks[0], barks[1]))
    A.put("bark1", 128, 0, bark(barks[2], barks[3], 0.4))
    tiles = {}
    if biome in ("beach", "jungle"):
        tiles["frond"] = K.frond(256, 512, P("olive_light"), P("olive_dark"), rng)
        tiles["dry"] = K.frond(256, 512, P("straw"), P("straw_dry") * 0.75, rng, broken=0.35)
    if biome == "beach":
        tiles["leafA"] = cluster(rng, leaves(CALATHEA, "olive", 0.5), 9, 95)
        tiles["leafB"] = cluster(rng, leaves(SHRUB4, "olive_light"), 14, 110)
        tiles["flower"] = K.flowers(256, 256, rng, [np.array([0.78, 0.42, 0.55]), np.array([0.85, 0.55, 0.62])], 16, P("olive"))
        tiles["litter"] = clutter_tile(rng, "coral_gravel", "#a89a80")
        tiles["gravel"] = clutter_tile(rng, "clean_pebbles", "rock_light")
        gk = [("dune-a", P("olive_dark"), P("olive_light"), P("straw")), ("dune-b", P("straw_dry"), P("straw"), P("#b8a678"))]
    elif biome == "jungle":
        tiles["fan"] = K.fan(256, 256, P("olive_light"), P("olive_dark"), rng)
        tiles["broad"] = sprig_tile(rng, CALATHEA, "olive", "#4a3c2c", 0.55, leaves=24, leaf_h=80, sides=5)
        tiles["broad2"] = sprig_tile(rng, SHRUB4, "olive_dark", "#3e3226", 0.55, leaves=36, leaf_h=60, sides=5, spread=1.1)
        tiles["fernA"] = cluster(rng, leaves(FERN, "olive", 0.6), 5, 230, 0.15, 0.05)
        tiles["ginger"] = K.bracts(256, 256, rng, P("berry") * 1.25, P("olive_dark"))
        tiles["vine"] = K.strands(256, 256, rng, P("olive"))
        tiles["litter"] = clutter_tile(rng, "dry_decay_leaves", "#6b4a33")
        tiles["gravel"] = clutter_tile(rng, "red_laterite_soil_stones", "#7a5040")
        gk = [("tall", P("olive_dark"), P("olive"), P("straw")), ("elephant", P("olive_dark"), P("moss"), P("straw_dry"))]
    elif biome == "grassland":
        tiles["oak"] = sprig_tile(rng, SHRUB4, "olive", "#4a3c2e", leaves=70, leaf_h=64, sides=6, reach=0.42)
        tiles["oak2"] = sprig_tile(rng, SHRUB4, "#6a6a3a", "#4a3c2e", leaves=64, leaf_h=60, sides=6, spread=1.15, reach=0.42)
        tiles["birch"] = sprig_tile(rng, SHRUB4, "olive_light", "#8a8070", leaves=64, leaf_h=46, sides=6, reach=0.36)
        tiles["hazel"] = sprig_tile(rng, NETTLE, "olive", "#4a3c2e", 0.55, leaves=40, leaf_h=62, sides=5)
        tiles["bramble"] = sprig_tile(rng, NETTLE, "olive_dark", "#3e3226", 0.5, leaves=24, leaf_h=50, sides=5, spread=1.2)
        tiles["fernA"] = cluster(rng, leaves(FERN, "moss", 0.55), 5, 230, 0.15, 0.05)
        tiles["litter"] = clutter_tile(rng, "forest_leaves_02", "#6e5a3c")
        tiles["gravel"] = clutter_tile(rng, "gravel_floor_02", "rock_mid")
        gk = [("meadow", P("olive_dark"), P("olive"), P("straw")), ("flowers", P("olive_dark"), P("olive"), P("straw"))]
    elif biome == "savanna":
        tiles["acacia"] = sprig_tile(rng, ROOIBOS, "#6a6a3c", "#4a3a2c", leaves=80, leaf_h=50, sides=6, spread=1.35, reach=0.45)
        tiles["acacia2"] = sprig_tile(rng, ROOIBOS, "#74703e", "#4a3a2c", leaves=72, leaf_h=46, sides=7, spread=1.45, reach=0.46)
        tiles["thorn"] = cluster(rng, leaves(TWIGS, "#6a5a44", 0.5), 6, 200, 0.2, 0.05)
        tiles["tuft"] = K.blades(256, 256, rng, 60, P("straw_dry"), P("straw"), P("#c4ad78"), 1.5, 2.6, 0.5)
        tiles["mound"] = clutter_tile(rng, "red_laterite_soil_stones", "#9a5a3c", fill=0.95)
        tiles["litter"] = clutter_tile(rng, "dry_decay_leaves", "#8a6a44")
        tiles["gravel"] = clutter_tile(rng, "gravel_floor_02", "#9a8466")
        gk = [("gold-tall", P("straw_dry"), P("straw"), P("#c4ad78")), ("gold-short", P("#7a5a34"), P("#a8783e"), P("#c49a5a"))]
    else:  # lake
        tiles["willow"] = K.strands(256, 256, rng, P("olive"), 22)
        tiles["alder"] = sprig_tile(rng, NETTLE, "olive", "#3e3428", 0.55, leaves=56, leaf_h=58, sides=6, reach=0.42)
        tiles["sedge"] = K.blades(256, 256, rng, 70, P("olive_dark"), P("olive"), P("straw"), 1.5, 2.5, 0.4)
        tiles["lily"] = K.lily(256, 256, rng, P("olive") * 0.9)
        tiles["lilyflower"] = K.flowers(256, 256, rng, [np.array([0.92, 0.88, 0.86]), np.array([0.9, 0.7, 0.75])], 6)
        tiles["litter"] = clutter_tile(rng, "forest_leaves_02", "#5e5236")
        tiles["gravel"] = clutter_tile(rng, "clean_pebbles", "rock_mid")
        gk = [("reed", P("olive_dark"), P("olive"), P("straw")), ("cattail", P("olive_dark"), P("moss"), P("straw"))]
    # place tiles: tall frond tiles first (2 rows each), then square tiles
    slots = [(c, r) for r in range(4) for c in range(3)]
    used = set()
    for key in ("frond", "dry"):
        if key in tiles:
            c = len([k for k in used if k[1] == 0 and k[0] < 2])
            x, y = T(c, 0)
            A.put(key, x, y, tiles.pop(key))
            used |= {(c, 0), (c, 1)}
    for key, tile in tiles.items():
        c, r = next(s for s in slots if s not in used)
        used.add((c, r))
        x, y = T(c, r)
        A.put(key, x, y, tile)
    # fruit/berry swatch in the last free slot corner (L3: the jungle atlas is full and its palms
    # carry no fruit, so the swatch is skipped there)
    free = [s for s in slots if s not in used]
    if free:
        x, y = T(*free[0])
        A.px[y : y + 32, x : x + 32, :3] = K.hexrgb("fruit")
        A.px[y : y + 32, x : x + 32, 3] = 1
        A.pt["fruit"] = ((x + 16) / 1024, (y + 16) / 1024)
        A.px[y + 40 : y + 72, x : x + 32, :3] = K.hexrgb("berry")
        A.px[y + 40 : y + 72, x : x + 32, 3] = 1
        A.pt["berry"] = ((x + 16) / 1024, (y + 56) / 1024)
    # grass atlas: 4 vertical 128x512 tiles, two per grass row (narrow blades, A2b fix)
    for i, (key, base, mid, tip) in enumerate(gk):
        for v in range(2):
            heads = K.hexrgb("straw") if v == 1 else None
            if key == "cattail" and v == 1:
                heads = K.hexrgb("#4a3424")
            t = K.blades(128, 512, rng, 64 if v == 0 else 50, base, mid, tip, 0.7, 1.4, 0.28, heads)
            if key == "flowers" and v == 1:
                t = K.flowers(128, 512, rng, [np.array([0.62, 0.18, 0.12]), np.array([0.78, 0.38, 0.12])], 18, K.hexrgb("olive"))
            G.put(f"{key}{v}", (i * 2 + v) * 128, 0, t)
    return A, G


def rocks(biome, outdir, R):
    """Bake scan rocks into 512 slots of the kit rock atlas; returns {key: obj}."""
    P = K.src
    specs = {
        "beach": [("rock.beach.tide-boulder", P("boulder_01", "boulder_01.gltf"), 6.5, 700, "rock_mid", 1.0),
                  ("rock.beach.reef-shelf", P("namaqualand_boulder_04", "namaqualand_boulder_04.gltf"), 16, 900, "rock_dark", 0.3)],
        "jungle": [("rock.jungle.mossy-boulder", P("rock_moss_set_01", "rock_moss_set_01.gltf"), 6.5, 800, "moss", 1.0),
                   ("rock.jungle.red-bank", P("namaqualand_boulder_02", "namaqualand_boulder_02.gltf"), 8.5, 700, "#7a4e3a", 0.8)],
        "grassland": [("rock.grassland.grey-boulder", P("boulder_01", "boulder_01.gltf"), 5.5, 700, "rock_mid", 1.0),
                      ("rock.grassland.boulder-cluster", P("namaqualand_boulder_02", "namaqualand_boulder_02.gltf"), 6, 340, "rock_light", 1.0)],
        "savanna": [("rock.savanna.kopje-slab", P("namaqualand_boulder_04", "namaqualand_boulder_04.gltf"), 7, 400, "#9a8a74", 0.55),
                    ("rock.savanna.sun-boulder", P("namaqualand_boulder_02", "namaqualand_boulder_02.gltf"), 4.5, 600, "#a8977e", 1.0)],
        "lake": [("rock.lake.river-stones", P("boulder_01", "boulder_01.gltf"), 3.2, 170, "rock_mid", 0.6)],
    }[biome]
    out = {}
    for i, (key, gltf, size, tris, target, squash) in enumerate(specs):
        obj, maps = K.scan_rock(gltf, key, size, tris, target, outdir, squash)
        x, y = (i % 2) * 512, (i // 2) * 512
        R.put(f"slot{i}", x, y, maps["albedo"], maps["normal"])
        K.remap_uv(obj, R.uv[f"slot{i}"])
        out[key] = obj
    # pebble slot (procedural lumps on a clean_pebbles texture)
    peb = K.resize(K.load_px(K.src("clean_pebbles", "textures", "clean_pebbles_diff_1k.png")), 512, 512)
    peb[..., 3] = 1
    R.put("pebbles", 0, 512, K.grade(peb, "rock_light" if biome != "jungle" else "rock_mid", 0.75, 0.5))
    return out


def build_kit(biome, outdir):
    seed = SEEDS[biome]
    C.reset(seed)
    rng = np.random.default_rng(seed)
    A, G = build_textures(biome, rng, outdir)
    R = K.Atlas(f"Kit_{biome}_rock", 1024)
    rk = rocks(biome, outdir, R)
    amat, gmat, rmat = A.save(outdir), G.save(outdir), R.save(outdir)
    rmat.node_tree.nodes["Principled BSDF"].inputs["Alpha"].default_value = 1.0
    for l in list(rmat.node_tree.nodes["Principled BSDF"].inputs["Alpha"].links):
        rmat.node_tree.links.remove(l)
    objs = []

    def make(key, fn, material=amat):
        m = K.Mesh(key)
        fn(m)
        objs.append(K.ground(m.finish(material)))

    def rock_copy(key, srcobj, placements):
        o = K.copies(srcobj, key, placements)
        K.assign(o, rmat)
        objs.append(K.ground(o))

    def pebbles(key, n, spread, size):
        m = K.Mesh(key)
        for i in range(n):
            a, r = random.uniform(0, 6.28), spread * math.sqrt(random.random())
            m.blob(V((math.cos(a) * r, math.sin(a) * r, 0)), size * random.uniform(0.5, 1.2), 1, R.uv["pebbles"], (1, 0.8, 0.45), 0.2)
        objs.append(K.ground(m.finish(rmat)))

    if biome == "beach":
        make("veg.beach.palm-tall", lambda m: palm(m, A, 25, 12, 9, 9.0))
        make("veg.beach.palm-lean", lambda m: palm(m, A, 21, 42, 8, 8.0, curve=0.8))
        make("veg.beach.seagrape", lambda m: shrub(m, A, 2.6, 5.0, 190, ["leafA", "leafB"], 1.5))
        make("veg.beach.vine-mat", lambda m: mat(m, A, 6, 120, ["flower", "leafB"]))
        make("veg.beach.dune-grass-a", lambda m: grass(m, G, ["dune-a0", "dune-a1"], 28, 2.4, 3.2, 0.6, 0.9), gmat)
        make("veg.beach.dune-grass-b", lambda m: grass(m, G, ["dune-b0", "dune-b1"], 28, 4.2, 5.4, 0.7, 1.1), gmat)
        objs.append(K.ground(rk["rock.beach.tide-boulder"]))
        K.assign(objs[-1], rmat)
        objs.append(K.ground(rk["rock.beach.reef-shelf"]))
        K.assign(objs[-1], rmat)
        pebbles("rock.beach.pebble-scatter", 15, 2.8, 0.45)
    elif biome == "jungle":
        make("veg.jungle.fan-palm", lambda m: (palm(m, A, 16, 8, 0, 6, fruit=False), [K.frond_strip(m, V((0.6, 0.1, 16)), 2 * math.pi * i / 16, random.uniform(-0.2, 0.9), 5.5, 4.6, A.uv["fan"], droop=1.4, steps=3) for i in range(16)]))
        def giant(variant):
            # L3: capped near 28 studs (was 53.5, D2 F3); forked trunk, plank buttress fins, clustered crown.
            def build(m):
                h = (25.5, 23.5)[variant]
                r = (1.5, 1.3)[variant]
                n = 6 + variant
                for i in range(n):
                    a = 2 * math.pi * i / n + random.uniform(-0.2, 0.2)
                    d = V((math.cos(a), math.sin(a), 0))
                    reach = random.uniform(2.6, 3.6)
                    m.card(d * r * 0.4 - V((0, 0, 0.3)), UP, d, reach, random.uniform(3.6, 5.0), A.uv["bark1"], bend=-d * reach * 0.35, rows=2)

                def vine(p):
                    if random.random() < 0.35:
                        a = random.uniform(0, 6.28)
                        ln = random.uniform(4, 7)
                        m.card(p - V((0, 0, ln)), UP, V((-math.sin(a), math.cos(a), 0)), 1.6, ln, A.uv["vine"], rows=1)

                crown = ((11, 9.5, 5.5), (9, 10, 6.5))[variant]
                hero(m, A, "bark1", ["broad", "broad2", "broad2"], h, r, crown, fork=(0.5, 0.42)[variant], leaders=(3, 2)[variant],
                     groups=(8, 6)[variant], clusters=(44, 38)[variant], cards=8, card=4.4, mind=3.4, roots=5, root_reach=2.8, root_h=3.2,
                     lean=((0.02, 0.0), (-0.03, 0.02))[variant], sides=10, hang=vine)
            return build
        make("veg.jungle.buttress-giant", giant(0))
        make("veg.jungle.buttress-giant-b", giant(1))

        def strangler(variant):
            def build(m):
                h = (26.0, 23.0)[variant]
                for k in range(5):
                    a = 2 * math.pi * k / 5
                    pts = [V((math.cos(a + z * 0.08) * 1.25, math.sin(a + z * 0.08) * 1.25, z)) for z in range(0, int(h * 0.5), 3)]
                    m.tube(pts, [0.42] * len(pts), 5, A.uv["bark1"])
                crown = ((8.5, 7.5, 5.0), (7.5, 8.5, 4.5))[variant]
                hero(m, A, "bark1", ["broad2", "broad"], h, 1.0, crown, fork=0.55, leaders=2, groups=(6, 5)[variant],
                     clusters=(32, 28)[variant], cards=8, card=4.0, mind=3.1, roots=4, root_reach=2.2, root_h=1.4,
                     lean=((0.03, 0.0), (0.0, -0.04))[variant])
            return build
        make("veg.jungle.strangler", strangler(0))
        make("veg.jungle.strangler-b", strangler(1))
        make("veg.jungle.understory-broadleaf", lambda m: bush(m, A, 3.2, 6.5, 14, 8, 3.0, ["broad", "broad2"]))
        make("veg.jungle.red-ginger", lambda m: (fern(m, A, 14, 3.4, ["broad"], (0.9, 1.4), 4, 0.5), mat(m, A, 1.5, 40, ["ginger"], 3.0)))
        make("veg.jungle.tree-fern", lambda m: (m.tube([V((0, 0, z)) for z in (0, 3, 6, 9)], [0.5, 0.42, 0.38, 0.35], 7, A.uv["bark1"]), [K.frond_strip(m, V((0, 0, 9)), 2 * math.pi * i / 14, random.uniform(0.1, 0.6), 5.5, 2.0, A.uv["fernA"], droop=2.2, steps=6) for i in range(14)]))
        make("veg.jungle.ground-fern", lambda m: fern(m, A, 28, 2.4, ["fernA"]))
        make("veg.jungle.jungle-tall", lambda m: grass(m, G, ["tall0", "tall1"], 36, 5.6, 7.0, 0.65, 1.4, 1), gmat)
        make("veg.jungle.elephant-grass", lambda m: grass(m, G, ["elephant0", "elephant1"], 36, 7.0, 8.6, 0.75, 1.6, 1), gmat)
        objs.append(K.ground(rk["rock.jungle.mossy-boulder"]))
        K.assign(objs[-1], rmat)
        objs.append(K.ground(rk["rock.jungle.red-bank"]))
        K.assign(objs[-1], rmat)
    elif biome == "grassland":
        # L3: 3 oak and 2 birch variants; forked tapered trunks, clustered branch-card crowns with gaps.
        make("veg.grassland.oak", lambda m: hero(m, A, "bark0", ["oak", "oak2"], 25, 1.2, (10.5, 9.5, 6.5), fork=0.4, leaders=3, groups=8, clusters=46, cards=9, card=4.2, mind=3.3, roots=4, root_reach=2.2, root_h=1.2))
        make("veg.grassland.oak-b", lambda m: hero(m, A, "bark0", ["oak2", "oak"], 21, 1.05, (9.0, 7.5, 5.5), fork=0.34, leaders=2, groups=7, clusters=38, cards=9, card=4.0, mind=3.1, roots=3, root_reach=2.0, root_h=1.0, lean=(0.06, 0.02)))
        make("veg.grassland.oak-c", lambda m: hero(m, A, "bark0", ["oak", "oak2"], 27, 1.0, (7.5, 8.0, 8.0), fork=0.48, leaders=2, groups=6, clusters=40, cards=8, card=4.0, mind=3.0, roots=3, root_reach=1.8, root_h=1.0, lean=(-0.03, 0.04)))
        make("veg.grassland.birch", lambda m: hero(m, A, "bark1", ["birch"], 24, 0.55, (4.8, 4.4, 7.5), fork=0.5, leaders=2, groups=6, clusters=30, cards=8, card=3.3, mind=2.5, sides=7, zmin=-0.6))
        make("veg.grassland.birch-b", lambda m: hero(m, A, "bark1", ["birch"], 20, 0.5, (5.5, 4.2, 6.0), fork=0.42, leaders=3, groups=6, clusters=28, cards=8, card=3.2, mind=2.4, sides=7, zmin=-0.6, lean=(0.05, -0.03)))
        make("veg.grassland.hazel", lambda m: bush(m, A, 3.2, 6.0, 16, 8, 2.3, ["hazel"]))
        make("veg.grassland.bramble", lambda m: bush(m, A, 2.4, 3.4, 14, 8, 1.8, ["bramble"]))
        make("veg.grassland.bracken", lambda m: fern(m, A, 26, 3.4, ["fernA"], (0.9, 1.3)))
        make("veg.grassland.meadow", lambda m: grass(m, G, ["meadow0", "meadow1"], 30, 1.9, 2.8, 0.55, 1.0), gmat)
        make("veg.grassland.flower-patch", lambda m: grass(m, G, ["flowers1", "meadow0"], 28, 1.6, 2.4, 0.65, 1.2), gmat)
        objs.append(K.ground(rk["rock.grassland.grey-boulder"]))
        K.assign(objs[-1], rmat)
        rock_copy("rock.grassland.boulder-cluster", rk["rock.grassland.boulder-cluster"],
                  [((0, 0, 0), 0, (1.6, 1.5, 1.4)), ((5.5, 1.5, 0), 1.3, (1, 1, 0.9)), ((-4.5, 2.5, 0), 2.4, (0.8, 0.8, 0.7)), ((1, -4.5, 0), 4.0, (0.6, 0.6, 0.55))])
        bpy.data.objects.remove(rk["rock.grassland.boulder-cluster"])
    elif biome == "savanna":
        # L3: umbrella acacias as wide flat layers of branch-card clusters on a forked, leaning trunk (3 variants).
        def flattop(h, crown, lean, leaders, clusters, keys):
            return lambda m: hero(m, A, "bark0", keys, h, 0.62, crown, fork=0.55, leaders=leaders, groups=leaders * 2 + 1, clusters=clusters,
                                  cards=9, card=4.6, mind=3.2, roots=0, lean=lean, zmin=-0.25, depth=(0.35, 1.0), flat=0.85)
        make("veg.savanna.flat-top", flattop(20, (10.5, 9.0, 2.0), (0.04, 0.0), 3, 40, ["acacia", "acacia2"]))
        make("veg.savanna.flat-top-b", flattop(16, (8.0, 7.0, 1.8), (-0.06, 0.03), 2, 28, ["acacia2", "acacia"]))
        make("veg.savanna.flat-top-c", flattop(22, (12.0, 8.5, 2.3), (0.02, 0.05), 3, 44, ["acacia", "acacia2"]))

        def bottle(m):
            m.tube([V((0, 0, z)) for z in (0, 3, 7, 11, 14, 16)], [2.6, 3.2, 3.0, 2.2, 1.2, 0.7], 12, A.uv["bark1"])
            hero(m, A, "bark1", ["acacia"], 22, 0.6, (6.5, 6.0, 3.0), fork=0.72, leaders=4, groups=8, clusters=26, cards=8, card=3.4, mind=2.5, flat=0.7)
        make("veg.savanna.bottle-trunk", bottle)
        make("veg.savanna.thornbush", lambda m: bush(m, A, 2.6, 4.0, 14, 7, 2.0, ["thorn", "acacia2"]))
        make("veg.savanna.termite-mound", lambda m: [m.blob(V((x, y, 0)), r, 2, A.uv["mound"], (0.55, 0.55, 1.6), 0.18) for x, y, r in ((0, 0, 2.2), (1.2, 0.6, 1.4), (-0.9, 0.7, 1.2))])
        make("veg.savanna.dry-tuft", lambda m: fern(m, A, 26, 1.9, ["tuft"], (1.0, 1.4), 2, 0.7))
        make("veg.savanna.gold-tall", lambda m: grass(m, G, ["gold-tall0", "gold-tall1"], 36, 3.8, 5.0, 0.55, 1.2), gmat)
        make("veg.savanna.gold-short", lambda m: grass(m, G, ["gold-short0", "gold-short1"], 28, 1.6, 2.2, 0.55, 1.0), gmat)
        rock_copy("rock.savanna.kopje-slab", rk["rock.savanna.kopje-slab"],
                  [((0, 0, 0), 0, (1.6, 1.4, 1)), ((2.5, 1, 2.6), 0.7, (1, 1, 1)), ((-3, 2, 0.5), 2.1, (1.1, 0.9, 1))])
        bpy.data.objects.remove(rk["rock.savanna.kopje-slab"])
        objs.append(K.ground(rk["rock.savanna.sun-boulder"]))
        K.assign(objs[-1], rmat)
    else:
        # L3: willow curtains hang from separated crown clusters; alder gets 2 clustered variants.
        def willow(m):
            def curtain(p):
                for k in range(3):
                    a = random.uniform(0, 6.28)
                    ln = random.uniform(5, 9) * (0.6 + 0.4 * p.z / 22)
                    c = p + V((math.cos(a), math.sin(a), 0)) * random.uniform(0.5, 1.5)
                    m.card(c - V((0, 0, ln)), UP, V((-math.sin(a), math.cos(a), 0)), 2.4, ln, A.uv["willow"], rows=1)
            hero(m, A, "bark0", ["willow", "alder"], 22, 1.15, (9.5, 9.0, 4.0), fork=0.4, leaders=3, groups=7, clusters=30, cards=6, card=3.4, mind=2.6,
                 roots=4, root_reach=2.0, root_h=1.0, hang=curtain)
        make("veg.lake.willow", willow)
        make("veg.lake.alder", lambda m: hero(m, A, "bark1", ["alder"], 21, 0.7, (5.5, 5.0, 7.0), fork=0.4, leaders=2, groups=6, clusters=34, cards=8, card=3.4, mind=2.6, sides=7, zmin=-0.55))
        make("veg.lake.alder-b", lambda m: hero(m, A, "bark1", ["alder"], 18, 0.65, (6.5, 5.5, 5.5), fork=0.36, leaders=3, groups=6, clusters=32, cards=8, card=3.3, mind=2.5, sides=7, lean=(0.05, 0.03)))
        make("veg.lake.sedge-clump", lambda m: fern(m, A, 40, 3.2, ["sedge"], (1.1, 1.45), 2, 0.6))
        make("veg.lake.lily-pads", lambda m: (mat(m, A, 6, 70, ["lily"], 0.06), mat(m, A, 2.5, 4, ["lilyflower"], 0.4)))
        make("veg.lake.reed-card", lambda m: grass(m, G, ["reed0", "reed1"], 32, 4.8, 6.0, 0.5, 1.0), gmat)
        make("veg.lake.cattail-card", lambda m: grass(m, G, ["cattail1", "cattail0"], 32, 4.4, 5.2, 0.55, 1.0), gmat)
        rock_copy("rock.lake.river-stones", rk["rock.lake.river-stones"],
                  [((0, 0, 0), 0, (1.3, 1, 1)), ((2.8, 0.8, 0), 1.0, (1, 0.9, 0.8)), ((-2.2, 1.5, 0), 2.0, (0.9, 0.8, 0.8)), ((0.6, -2.4, 0), 3.2, (0.8, 0.7, 0.7))])
        bpy.data.objects.remove(rk["rock.lake.river-stones"])
    # ground clutter cards (A2b fix: leaf litter + gravel per biome)
    make(f"clutter.{biome}.leaf-litter", lambda m: ground_card(m, A, "litter", 5.5, 3))
    make(f"clutter.{biome}.gravel", lambda m: ground_card(m, A, "gravel", 4.5, 2))
    for o in objs:
        o.name = o.data.name = o.name.split(".001")[0]
    K.layout_row(objs)
    name = f"RobangoKit_{biome}"
    pv = K.silhouettes_and_previews(name, outdir, objs)
    fbx = C.export_fbx(name, outdir, objs)
    rows = [{"key": o.name, "tris": C.triangles(o), "size": [round(v, 1) for v in o.dimensions]} for o in objs]
    means = {k: A.opaque_mean(k) for k in A.uv}
    json.dump({"package": name, "seed": seed, "fbx": fbx, "preview": pv, "rows": rows, "atlasMeans": means, "fbxBytes": os.path.getsize(fbx)},
              open(os.path.join(outdir, f"{name}.json"), "w"), indent=1)
    print("KIT", name, sum(r["tris"] for r in rows), "tris", len(rows), "models")


if __name__ == "__main__":
    args = sys.argv[sys.argv.index("--") + 1 :]
    build_kit(args[1], C.out_dir())
