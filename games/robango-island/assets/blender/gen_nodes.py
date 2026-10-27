"""B1a resource nodes (asset catalog section 4): every B1a node row as 2 Models, `<key>` (full)
and `<key>.depleted` (~30% of the triangles), in two packages that share the two 1024 node atlases:
RobangoNodes_A (wood/plant) and RobangoNodes_B (mineral/food/markers).

Run (repo root): blender -b --factory-startup --python gen_nodes.py -- <outdir> A|B
"""

import json
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from mathutils import Vector

import common as C
import kitlib as K
from gen_kits import CALATHEA, FERN, NETTLE, SHRUB4, bark, cluster, clutter_tile, leaves

V = Vector
UP = V((0, 0, 1))
SEEDS = {"A": 5201, "B": 5202}


def atlas(pkg, rng):
    A = K.Atlas(f"Nodes_{pkg}", 1024)
    A.put("bark", 0, 0, bark("bark_brown_02", "bark"))
    A.put("drift", 128, 0, bark("bark_platanus", "#9c9484", 0.3))
    T = lambda c, r: (256 + c * 256, r * 256)
    P = K.hexrgb
    tiles = {
        "leaf": cluster(rng, leaves(SHRUB4, "olive"), 16, 100),
        "nettle": cluster(rng, leaves(NETTLE, "olive", 0.55), 12, 95),
        "fern": cluster(rng, leaves(FERN, "olive", 0.6), 5, 230, 0.15, 0.05),
        "broad": cluster(rng, leaves(CALATHEA, "olive", 0.5), 8, 120),
        "fiber": K.blades(256, 256, rng, 70, P("olive_dark"), P("olive"), P("straw"), 1.4, 2.4, 0.45, P("straw")),
        "flax": K.flowers(256, 256, rng, [np.array([0.42, 0.5, 0.78]), np.array([0.5, 0.58, 0.85])], 16, P("olive")),
        "crop": K.blades(256, 256, rng, 50, P("olive_dark"), P("olive_light"), P("#b8a060"), 2.0, 3.4, 0.25, P("#c4a860")),
        "litter": clutter_tile(rng, "dry_decay_leaves", "#6b4a33", 0.85),
        "rock": clutter_tile(rng, "coast_rocks_01", "rock_mid", 1.2),
        "flint": clutter_tile(rng, "aerial_rocks_02" if os.path.isdir(K.src("aerial_rocks_02")) else "clean_pebbles", "#2e2a28", 1.2, 0.3),
        "chalk": clutter_tile(rng, "gravel_floor_02", "#b8b0a0", 1.2, 0.3),
    }
    slots = [(c, r) for r in range(4) for c in range(3)]
    for (key, tile), (c, r) in zip(tiles.items(), slots):
        A.put(key, *T(c, r), tile)
    # solid swatches in the last slot: 8 x 32px squares
    x, y = T(2, 3)
    A.pt = {}
    for i, (name, hexc) in enumerate([("berry", "berry"), ("fruit", "fruit"), ("mush", "#c07a2a"), ("shell", "#c8bca8"),
                                      ("cloth", "#3a7a7a"), ("hide", "hide"), ("bone", "#cfc4a8"), ("water", "#3c5a5a"),
                                      ("crate", "#7a6040"), ("rope", "#9c8a5a"), ("glint", "#9ad0d0"), ("fish", "#4a5a5a"),
                                      ("nut", "#8a6a3a"), ("apple", "#9a3a2a"), ("banana", "#c8b048"), ("meat", "#7a3a30")]):
        sx, sy = x + (i % 4) * 64, y + (i // 4) * 64
        A.px[sy : sy + 48, sx : sx + 48, :3] = K.hexrgb(hexc)
        A.px[sy : sy + 48, sx : sx + 48, 3] = 1
        A.pt[name] = ((sx + 24) / 1024, (sy + 24) / 1024)
    return A


def sw(A, name):
    u, v = A.pt[name]
    return (u - 0.01, v - 0.01, u + 0.01, v + 0.01)


def log(m, A, a, b, r, key="bark", sides=7):
    m.tube([a, (a + b) / 2, b], [r, r * 0.95, r * 0.85], sides, A.uv[key])


def rock(m, A, c, r, key="rock", sub=1, sq=(1, 1, 0.7)):
    m.blob(c, r, sub, A.uv[key], sq, 0.22)


def bush(m, A, keys, rx, rz, n, card):
    K.outward_cards(m, [A.uv[k] for k in keys], n, V((0, 0, rz * 0.55)), rx, rx, rz * 0.55, card, zmin=-0.3, top_cards=n // 5, top_z=rz * 0.45)


def balls(m, A, name, n, centre, spread, r):
    for _ in range(n):
        m.swatch_ball(centre + V((random.uniform(-1, 1) * spread, random.uniform(-1, 1) * spread, random.uniform(0, spread))), r, A.pt[name])


# Each builder(m, A, full: bool). Depleted keeps a stump / empty bed (~30% tris).
def branch_pile(m, A, full):
    for i in range(6 if full else 2):
        a = random.uniform(0, math.pi)
        d = V((math.cos(a), math.sin(a), 0)) * random.uniform(1.6, 2.2)
        log(m, A, -d + V((0, 0, 0.2 + i * 0.12)), d + V((0, 0, 0.3)), 0.14, sides=5)


def stone_pile(m, A, full):
    for i in range(9 if full else 3):
        rock(m, A, V((random.uniform(-1, 1), random.uniform(-1, 1), 0.2 + (i % 3) * 0.25)), random.uniform(0.35, 0.55))


def fallen_tree(m, A, full):
    if full:
        log(m, A, V((-6, 0, 0.9)), V((6, 0, 0.7)), 0.9, sides=10)
        for i in range(4):
            a = i * 1.57
            log(m, A, V((-6, 0, 0.9)), V((-6.3, math.cos(a) * 2, 0.9 + math.sin(a) * 1.8)), 0.25, sides=5)
        for i in range(3):
            log(m, A, V((-1 + i * 3, 0, 1.4)), V((-0.2 + i * 3, 1.6, 2.8)), 0.14, sides=5)
    else:
        log(m, A, V((-6, 0, 0.0)), V((-6, 0, 1.3)), 0.9, sides=10)


def driftwood(m, A, full):
    for i in range(6 if full else 2):
        a = random.uniform(-0.4, 0.4)
        d = V((math.cos(a), math.sin(a), 0)) * random.uniform(2.5, 4.5)
        c = V((random.uniform(-2.5, 2.5), random.uniform(-0.8, 0.8), 0.25))
        log(m, A, c - d, c + d, random.uniform(0.15, 0.3), "drift", 6)


def fiber_bush(m, A, full):
    K.grass_cluster(m, [A.uv["fiber"]], 40 if full else 10, 1.6 if full else 0.5, 2.6 if full else 0.8, 1.2, 1.6, 0.4)


def berry_bush(m, A, full):
    if full:
        bush(m, A, ["leaf", "nettle"], 1.9, 3.4, 120, 1.25)
        balls(m, A, "berry", 30, V((0, 0, 1.9)), 1.5, 0.15)
    else:
        bush(m, A, ["leaf"], 1.0, 1.2, 40, 0.8)


def flint_outcrop(m, A, full):
    rock(m, A, V((0, 0, 0.5)), 2.2, "chalk", 2, (1.2, 0.7, 0.6))
    for i in range(10 if full else 0):
        rock(m, A, V((random.uniform(-2, 2), random.uniform(-0.8, 0.8), 1.0 + random.uniform(0, 0.5))), 0.35, "flint", 1, (1, 0.8, 0.7))


def flint_scree(m, A, full):
    for i in range(16 if full else 5):
        rock(m, A, V((random.uniform(-4, 4), random.uniform(-1.8, 1.8), 0.2)), random.uniform(0.3, 0.7), "flint" if i % 3 == 0 else "rock")


def boulder_field(m, A, full):
    for i in range(7 if full else 2):
        rock(m, A, V((random.uniform(-4, 4), random.uniform(-4, 4), 0.6)), random.uniform(0.9, 1.6), "rock", 2)


def birch_stand(m, A, full):
    for i in range(3):
        a = i * 2.1
        b = V((math.cos(a) * 1.8, math.sin(a) * 1.8, 0))
        log(m, A, b, b + V((0.2, 0.1, 13 if full else 1.2)), 0.45, "drift", 8)
        if full:
            K.outward_cards(m, [A.uv["leaf"]], 70, b + V((0, 0, 11)), 2.4, 2.4, 3, 1.6, zmin=-0.3)


def chanterelle_log(m, A, full):
    log(m, A, V((-4, 0, 0.6)), V((4, 0, 0.55)), 0.6, sides=9)
    for i in range(14 if full else 0):
        c = V((random.uniform(-3.5, 3.5), random.choice((-0.6, 0.6)), random.uniform(0.2, 0.9)))
        m.blob(c, 0.22, 1, sw(A, "mush"), (1, 1, 0.45), 0.1)


def hazel_thicket(m, A, full):
    for i in range(5):
        a = i * 1.25
        b = V((math.cos(a) * 1.5, math.sin(a) * 1.5, 0))
        log(m, A, b, b * 1.4 + V((0, 0, 5 if full else 0.8)), 0.15, sides=5)
    if full:
        bush(m, A, ["nettle", "leaf"], 2.8, 5.5, 210, 1.5)
        balls(m, A, "nut", 24, V((0, 0, 3)), 2.0, 0.13)


def clam_bed(m, A, full):
    for i in range(24 if full else 6):
        c = V((random.uniform(-2.2, 2.2), random.uniform(-2.2, 2.2), 0.05))
        m.blob(c, 0.32, 1, sw(A, "shell"), (1, 0.8, 0.35), 0.1)


def meat_cache(m, A, full):
    # Ground-level cache: a hide-wrapped bundle resting on a low log platform, short stakes around.
    # Nothing hangs (the A2 moderation screen rejects frame + hanging shapes).
    for x in (-0.9, 0.0, 0.9):
        log(m, A, V((x, -1.4, 0.25)), V((x, 1.4, 0.25)), 0.22, sides=6)
    for i in range(4):
        a = i * math.pi / 2 + 0.6
        log(m, A, V((math.cos(a) * 1.9, math.sin(a) * 1.9, 0)), V((math.cos(a) * 1.8, math.sin(a) * 1.8, 0.9)), 0.1, sides=5)
    if full:
        m.blob(V((0, 0, 1.1)), 0.95, 2, sw(A, "hide"), (1.2, 0.9, 0.7), 0.15)


def carcass(m, A, full):
    for i in range(7):
        log(m, A, V((-1 + i * 0.35, -0.9, 0.3)), V((-1 + i * 0.35, 0.9, 0.3 + (0.7 if full else 0.2))), 0.07, "drift", 5)
    log(m, A, V((-1.6, 0, 0.35)), V((1.6, 0, 0.35)), 0.12, "drift", 5)
    if full:
        m.blob(V((0.2, 0, 0.5)), 1.3, 2, sw(A, "hide"), (1.4, 0.8, 0.4), 0.15)


def water_spring(m, A, full):
    for i in range(12):
        a = i * math.pi / 6
        rock(m, A, V((math.cos(a) * 1.8, math.sin(a) * 1.8, 0.15)), 0.5, "rock", 1, (1, 1, 0.55))
    m.quad([V((-1.5, -1.5, 0.12 if full else 0.02)), V((1.5, -1.5, 0.12 if full else 0.02)), V((1.5, 1.5, 0.12 if full else 0.02)), V((-1.5, 1.5, 0.12 if full else 0.02))], sw(A, "water"))


def fish_school(m, A, full):
    for i in range(10 if full else 3):
        c = V((random.uniform(-2, 2), random.uniform(-2, 2), -0.4))
        m.blob(c, 0.35, 1, sw(A, "fish"), (1.6, 0.5, 0.3), 0.05)


def leaf_heap(m, A, full):
    K.outward_cards(m, [A.uv["litter"], A.uv["leaf"]], 60 if full else 16, V((0, 0, 0.1)), 1.8, 1.8, 0.5 if full else 0.2, 1.4, zmin=0.0)


def flax_patch(m, A, full):
    K.grass_cluster(m, [A.uv["flax"], A.uv["fiber"]], 36 if full else 10, 1.5 if full else 0.4, 2.2 if full else 0.6, 1.1, 2.2, 0.3)


def wild_crop(m, A, full):
    K.grass_cluster(m, [A.uv["crop"]], 36 if full else 10, 1.4 if full else 0.3, 2.4 if full else 0.6, 1.0, 1.9, 0.2)


def fruit_tree(m, A, full):
    log(m, A, V((0, 0, 0)), V((0.3, 0, 6 if full else 1.4)), 0.4, sides=8)
    if full:
        K.outward_cards(m, [A.uv["broad"], A.uv["leaf"]], 230, V((0.3, 0, 7.5)), 3.4, 3.4, 2.6, 1.7, zmin=-0.4, top_cards=40, top_z=2)
        balls(m, A, "apple", 26, V((0.3, 0, 6.8)), 2.6, 0.2)


def seed_pod(m, A, full):
    K.grass_cluster(m, [A.uv["fiber"]], 14 if full else 4, 0.9 if full else 0.3, 1.5 if full else 0.5, 0.9, 0.8, 0.3)
    if full:
        balls(m, A, "nut", 10, V((0, 0, 1.3)), 0.5, 0.12)


def relief_crate(m, A, full):
    if full:
        m.box(V((0, 0, 1)), (3, 2, 2), sw(A, "crate"))
        for x in (-1.0, 1.0):
            m.box(V((x, 0, 1)), (0.14, 2.06, 2.06), sw(A, "rope"))
    else:
        for i in range(4):
            m.box(V((random.uniform(-1.5, 1.5), random.uniform(-1, 1), 0.08)), (2.4, 0.4, 0.12), sw(A, "crate"), random.uniform(0, 3))


def survey_cairn(m, A, full):
    for i in range(6 if full else 2):
        rock(m, A, V((random.uniform(-0.3, 0.3), random.uniform(-0.3, 0.3), 0.4 + i * 0.5)), 0.75 - i * 0.07, "rock", 1, (1, 1, 0.55))
    if full:
        m.box(V((1.1, 0, 0.35)), (0.7, 0.4, 0.6), sw(A, "hide"))


def signal_shard(m, A, full):
    rock(m, A, V((0, 0, 0)), 1.3, "rock", 1, (1, 1, 0.35))
    if full:
        m.blob(V((0.1, 0, 0.6)), 0.6, 1, sw(A, "glint"), (0.5, 0.25, 1.4), 0.05)


def rescue_marker(m, A, full):
    log(m, A, V((0, 0, 0)), V((0, 0, 5 if full else 1.0)), 0.1, sides=6)
    if full:
        m.quad([V((0, 0, 3.6)), V((1.8, 0, 3.75)), V((1.8, 0.05, 4.8)), V((0, 0, 4.9))], sw(A, "cloth"))
    for i in range(3):
        a = i * 2.1
        rock(m, A, V((math.cos(a) * 0.5, math.sin(a) * 0.5, 0.15)), 0.35, "rock", 1)


def journal_cache(m, A, full):
    log(m, A, V((-2.2, 0, 0.55)), V((2.2, 0, 0.5)), 0.55, sides=9)
    if full:
        m.box(V((2.4, 0, 0.35)), (0.7, 0.5, 0.25), sw(A, "cloth"))


PACKAGES = {
    "A": [("node.branch-pile", branch_pile), ("node.fallen-tree", fallen_tree), ("node.driftwood-line", driftwood),
          ("node.fiber-bush", fiber_bush), ("node.berry-bush", berry_bush), ("node.birch-stand", birch_stand),
          ("node.chanterelle-log", chanterelle_log), ("node.hazel-thicket", hazel_thicket), ("node.leaf-litter", leaf_heap),
          ("node.flax-patch", flax_patch), ("node.wild-crop", wild_crop), ("node.fruit-tree", fruit_tree), ("node.seed-pod", seed_pod)],
    "B": [("node.stone-pile", stone_pile), ("node.flint-outcrop", flint_outcrop), ("node.flint-scree", flint_scree),
          ("node.boulder-field", boulder_field), ("node.clam-bed", clam_bed), ("node.meat-cache", meat_cache),
          ("node.carcass", carcass), ("node.water-spring", water_spring), ("node.fish-school", fish_school),
          ("node.relief-crate", relief_crate), ("node.survey-cairn", survey_cairn), ("node.signal-shard", signal_shard),
          ("node.rescue-marker", rescue_marker), ("node.journal-cache", journal_cache)],
}


def main():
    args = sys.argv[sys.argv.index("--") + 1 :]
    outdir, pkg = C.out_dir(), args[1]
    seed = SEEDS[pkg]
    C.reset(seed)
    rng = np.random.default_rng(seed)
    A = atlas(pkg, rng)
    mat = A.save(outdir)
    objs = []
    for key, fn in PACKAGES[pkg]:
        for full in (True, False):
            random.seed(f"{seed}:{key}:{full}")
            m = K.Mesh(key if full else key + ".depleted")
            fn(m, A, full)
            objs.append(K.ground(m.finish(mat)))
    for o in objs:
        o.name = o.data.name = o.name.split(".001")[0]
    K.layout_row(objs, 3)
    name = f"RobangoNodes_{pkg}"
    pv = K.silhouettes_and_previews(name, outdir, objs)
    fbx = C.export_fbx(name, outdir, objs)
    rows = [{"key": o.name, "tris": C.triangles(o), "size": [round(v, 1) for v in o.dimensions]} for o in objs]
    json.dump({"package": name, "seed": seed, "fbx": fbx, "rows": rows, "fbxBytes": os.path.getsize(fbx)},
              open(os.path.join(outdir, f"{name}.json"), "w"), indent=1)
    print("NODES", name, sum(r["tris"] for r in rows), len(rows))


main()
