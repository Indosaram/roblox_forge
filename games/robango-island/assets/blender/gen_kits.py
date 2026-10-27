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
        tiles["broad"] = cluster(rng, leaves(CALATHEA, "olive", 0.55), 8, 120)
        tiles["fernA"] = cluster(rng, leaves(FERN, "olive", 0.6), 5, 230, 0.15, 0.05)
        tiles["ginger"] = K.bracts(256, 256, rng, P("berry") * 1.25, P("olive_dark"))
        tiles["vine"] = K.strands(256, 256, rng, P("olive"))
        tiles["litter"] = clutter_tile(rng, "dry_decay_leaves", "#6b4a33")
        tiles["gravel"] = clutter_tile(rng, "red_laterite_soil_stones", "#7a5040")
        gk = [("tall", P("olive_dark"), P("olive"), P("straw")), ("elephant", P("olive_dark"), P("moss"), P("straw_dry"))]
    elif biome == "grassland":
        tiles["oak"] = cluster(rng, leaves(SHRUB4, "olive"), 18, 90)
        tiles["birch"] = cluster(rng, leaves(SHRUB4, "olive_light"), 16, 70)
        tiles["hazel"] = cluster(rng, leaves(NETTLE, "olive", 0.55), 12, 95)
        tiles["bramble"] = cluster(rng, leaves(NETTLE, "olive_dark", 0.5), 14, 80)
        tiles["fernA"] = cluster(rng, leaves(FERN, "moss", 0.55), 5, 230, 0.15, 0.05)
        tiles["litter"] = clutter_tile(rng, "forest_leaves_02", "#6e5a3c")
        tiles["gravel"] = clutter_tile(rng, "gravel_floor_02", "rock_mid")
        gk = [("meadow", P("olive_dark"), P("olive"), P("straw")), ("flowers", P("olive_dark"), P("olive"), P("straw"))]
    elif biome == "savanna":
        tiles["acacia"] = cluster(rng, leaves(ROOIBOS, "#6a6a3c"), 22, 70, 0.4, 0.3)
        tiles["thorn"] = cluster(rng, leaves(TWIGS, "#6a5a44", 0.5), 6, 200, 0.2, 0.05)
        tiles["tuft"] = K.blades(256, 256, rng, 60, P("straw_dry"), P("straw"), P("#c4ad78"), 1.5, 2.6, 0.5)
        tiles["mound"] = clutter_tile(rng, "red_laterite_soil_stones", "#9a5a3c", fill=0.95)
        tiles["litter"] = clutter_tile(rng, "dry_decay_leaves", "#8a6a44")
        tiles["gravel"] = clutter_tile(rng, "gravel_floor_02", "#9a8466")
        gk = [("gold-tall", P("straw_dry"), P("straw"), P("#c4ad78")), ("gold-short", P("#7a5a34"), P("#a8783e"), P("#c49a5a"))]
    else:  # lake
        tiles["willow"] = K.strands(256, 256, rng, P("olive"), 22)
        tiles["alder"] = cluster(rng, leaves(NETTLE, "olive", 0.55), 16, 85)
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
    # fruit/berry swatch in the last free slot corner
    c, r = next(s for s in slots if s not in used)
    x, y = T(c, r)
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
            t = K.blades(128, 512, rng, 34 if v == 0 else 26, base, mid, tip, 1.3, 2.4, 0.28, heads)
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
        make("veg.beach.palm-tall", lambda m: palm(m, A, 29, 12, 9, 9.5))
        make("veg.beach.palm-lean", lambda m: palm(m, A, 21, 42, 8, 8.0, curve=0.8))
        make("veg.beach.seagrape", lambda m: shrub(m, A, 2.6, 5.0, 190, ["leafA", "leafB"], 1.5))
        make("veg.beach.vine-mat", lambda m: mat(m, A, 6, 120, ["flower", "leafB"]))
        make("veg.beach.dune-grass-a", lambda m: grass(m, G, ["dune-a0", "dune-a1"], 24, 2.4, 3.2, 1.1, 0.9), gmat)
        make("veg.beach.dune-grass-b", lambda m: grass(m, G, ["dune-b0", "dune-b1"], 24, 4.2, 5.4, 1.3, 1.1), gmat)
        objs.append(K.ground(rk["rock.beach.tide-boulder"]))
        K.assign(objs[-1], rmat)
        objs.append(K.ground(rk["rock.beach.reef-shelf"]))
        K.assign(objs[-1], rmat)
        pebbles("rock.beach.pebble-scatter", 15, 2.8, 0.45)
    elif biome == "jungle":
        make("veg.jungle.fan-palm", lambda m: (palm(m, A, 16, 8, 0, 6, fruit=False), [K.frond_strip(m, V((0.6, 0.1, 16)), 2 * math.pi * i / 16, random.uniform(-0.2, 0.9), 5.5, 4.6, A.uv["fan"], droop=1.4, steps=3) for i in range(16)]))
        def giant(m):
            tree(m, A, 48, 2.0, "bark1", [(44, 15, 6, 380), (36, 10, 5, 240)], ["broad", "vine"], 5.5, branches=7, sides=10)
            for i in range(6):
                a = 2 * math.pi * i / 6
                d = V((math.cos(a), math.sin(a), 0))
                m.card(d * 0.8, (UP + d * 0.5).normalized(), d.cross(UP), 0.7, 7, A.uv["bark1"], rows=2)
                m.card(d * 0.8, UP, d, 3.6, 5.5, A.uv["bark1"], bend=d * 1.5, rows=3)
            for i in range(26):
                a = random.uniform(0, 6.28)
                c = V((math.cos(a) * random.uniform(6, 13), math.sin(a) * random.uniform(6, 13), random.uniform(28, 38)))
                m.card(c - V((0, 0, 9)), UP, V((-math.sin(a), math.cos(a), 0)), 2.2, 9, A.uv["vine"], rows=1)
        make("veg.jungle.buttress-giant", giant)
        def strangler(m):
            for k in range(5):
                a = 2 * math.pi * k / 5
                pts = [V((math.cos(a + z * 0.08) * 1.4, math.sin(a + z * 0.08) * 1.4, z)) for z in range(0, 20, 3)]
                m.tube(pts, [0.45] * len(pts), 5, A.uv["bark1"])
            tree(m, A, 32, 1.1, "bark1", [(28, 9, 4.5, 330)], ["broad", "fan"], 4.2, branches=5)
        make("veg.jungle.strangler", strangler)
        make("veg.jungle.understory-broadleaf", lambda m: shrub(m, A, 3.0, 6.5, 240, ["broad"], 2.0))
        make("veg.jungle.red-ginger", lambda m: (fern(m, A, 14, 3.4, ["broad"], (0.9, 1.4), 4, 0.5), mat(m, A, 1.5, 40, ["ginger"], 3.0)))
        make("veg.jungle.tree-fern", lambda m: (m.tube([V((0, 0, z)) for z in (0, 3, 6, 9)], [0.5, 0.42, 0.38, 0.35], 7, A.uv["bark1"]), [K.frond_strip(m, V((0, 0, 9)), 2 * math.pi * i / 14, random.uniform(0.1, 0.6), 5.5, 2.0, A.uv["fernA"], droop=2.2, steps=6) for i in range(14)]))
        make("veg.jungle.ground-fern", lambda m: fern(m, A, 28, 2.4, ["fernA"]))
        make("veg.jungle.jungle-tall", lambda m: grass(m, G, ["tall0", "tall1"], 32, 5.6, 7.0, 1.1, 1.4, 1), gmat)
        make("veg.jungle.elephant-grass", lambda m: grass(m, G, ["elephant0", "elephant1"], 32, 7.0, 8.6, 1.3, 1.6, 1), gmat)
        objs.append(K.ground(rk["rock.jungle.mossy-boulder"]))
        K.assign(objs[-1], rmat)
        objs.append(K.ground(rk["rock.jungle.red-bank"]))
        K.assign(objs[-1], rmat)
    elif biome == "grassland":
        make("veg.grassland.oak", lambda m: tree(m, A, 26, 1.3, "bark0", [(21, 11, 5.5, 520), (17, 8, 4, 260)], ["oak"], 4.0, branches=7, fork=0.5))
        make("veg.grassland.birch", lambda m: tree(m, A, 23, 0.6, "bark1", [(19, 5, 6, 380), (14, 4, 3.5, 200)], ["birch"], 3.2, branches=5, sides=7))
        make("veg.grassland.hazel", lambda m: shrub(m, A, 3.0, 6.0, 190, ["hazel"], 1.8))
        make("veg.grassland.bramble", lambda m: shrub(m, A, 2.2, 3.4, 170, ["bramble"], 1.4))
        make("veg.grassland.bracken", lambda m: fern(m, A, 26, 3.4, ["fernA"], (0.9, 1.3)))
        make("veg.grassland.meadow", lambda m: grass(m, G, ["meadow0", "meadow1"], 24, 1.9, 2.8, 0.9, 1.0), gmat)
        make("veg.grassland.flower-patch", lambda m: grass(m, G, ["flowers1", "meadow0"], 24, 1.6, 2.4, 1.0, 1.2), gmat)
        objs.append(K.ground(rk["rock.grassland.grey-boulder"]))
        K.assign(objs[-1], rmat)
        rock_copy("rock.grassland.boulder-cluster", rk["rock.grassland.boulder-cluster"],
                  [((0, 0, 0), 0, (1.6, 1.5, 1.4)), ((5.5, 1.5, 0), 1.3, (1, 1, 0.9)), ((-4.5, 2.5, 0), 2.4, (0.8, 0.8, 0.7)), ((1, -4.5, 0), 4.0, (0.6, 0.6, 0.55))])
        bpy.data.objects.remove(rk["rock.grassland.boulder-cluster"])
    elif biome == "savanna":
        def flattop(m):
            tree(m, A, 21, 0.75, "bark0", [], ["acacia"], 3.0, branches=6, fork=0.9, lean=0.05)
            K.outward_cards(m, [A.uv["acacia"]], 60, V((0, 0, 18.5)), 10, 9, 1.2, 4.2, zmin=0.2, top_cards=170, top_z=0.9)
        make("veg.savanna.flat-top", flattop)
        def bottle(m):
            m.tube([V((0, 0, z)) for z in (0, 3, 7, 11, 14, 16)], [2.6, 3.2, 3.0, 2.2, 1.2, 0.7], 12, A.uv["bark1"])
            tree(m, A, 24, 0.6, "bark1", [(19, 7, 2.5, 330)], ["acacia"], 3.0, branches=8, fork=0.4)
        make("veg.savanna.bottle-trunk", bottle)
        make("veg.savanna.thornbush", lambda m: shrub(m, A, 2.2, 4.0, 150, ["thorn", "acacia"], 1.6))
        make("veg.savanna.termite-mound", lambda m: [m.blob(V((x, y, 0)), r, 2, A.uv["mound"], (0.55, 0.55, 1.6), 0.18) for x, y, r in ((0, 0, 2.2), (1.2, 0.6, 1.4), (-0.9, 0.7, 1.2))])
        make("veg.savanna.dry-tuft", lambda m: fern(m, A, 26, 1.9, ["tuft"], (1.0, 1.4), 2, 0.7))
        make("veg.savanna.gold-tall", lambda m: grass(m, G, ["gold-tall0", "gold-tall1"], 32, 3.8, 5.0, 0.9, 1.2), gmat)
        make("veg.savanna.gold-short", lambda m: grass(m, G, ["gold-short0", "gold-short1"], 24, 1.6, 2.2, 0.9, 1.0), gmat)
        rock_copy("rock.savanna.kopje-slab", rk["rock.savanna.kopje-slab"],
                  [((0, 0, 0), 0, (1.6, 1.4, 1)), ((2.5, 1, 2.6), 0.7, (1, 1, 1)), ((-3, 2, 0.5), 2.1, (1.1, 0.9, 1))])
        bpy.data.objects.remove(rk["rock.savanna.kopje-slab"])
        objs.append(K.ground(rk["rock.savanna.sun-boulder"]))
        K.assign(objs[-1], rmat)
    else:
        def willow(m):
            tree(m, A, 25, 1.2, "bark0", [], ["willow"], 4, branches=8, fork=0.6)
            for i in range(170):
                a, r = random.uniform(0, 6.28), random.uniform(3, 11)
                top = V((math.cos(a) * r, math.sin(a) * r, 21 - r * 0.45 + random.uniform(-1, 1.5)))
                m.card(top - V((0, 0, 12 - r * 0.4)), UP, V((-math.sin(a), math.cos(a), 0)), 3.0, 12 - r * 0.4, A.uv["willow"], rows=1)
        make("veg.lake.willow", willow)
        make("veg.lake.alder", lambda m: tree(m, A, 19, 0.7, "bark1", [(15, 5, 6, 420), (11, 4, 3, 150)], ["alder"], 3.2, branches=6, sides=7))
        make("veg.lake.sedge-clump", lambda m: fern(m, A, 40, 3.2, ["sedge"], (1.1, 1.45), 2, 0.6))
        make("veg.lake.lily-pads", lambda m: (mat(m, A, 6, 70, ["lily"], 0.06), mat(m, A, 2.5, 4, ["lilyflower"], 0.4)))
        make("veg.lake.reed-card", lambda m: grass(m, G, ["reed0", "reed1"], 28, 4.8, 6.0, 0.9, 1.0), gmat)
        make("veg.lake.cattail-card", lambda m: grass(m, G, ["cattail1", "cattail0"], 28, 4.4, 5.2, 0.9, 1.0), gmat)
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
