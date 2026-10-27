"""B2a creatures: skinned, textured meshes for the theropod, ceratopsian and sauropod body plans
and the 11 species mapped to them (asset catalog section 5).

Run (repo root, headless only):
  blender -b --factory-startup --python games/robango-island/assets/blender/gen_creatures.py -- <outdir> <species>

Rules applied (A2b REPORT recipe):
- built at final stud scale (1 Blender unit = 1 stud); the runtime never scales a skinned model;
- one rig per plan with the catalog bone count (theropod 22, ceratopsian 20, sauropod 26);
- every bone's local X is the creature's side axis, so +X rotation lifts a bone's tip (pitch)
  and Z rotation is yaw; the Root bone points up (local Y up, local Z forward);
- palette fed through C.hexlin (linear), CC0 leather micro-detail box-projected;
- S/M creatures bake 512 x3, L/XL 1024 x3; triangle totals stay inside the size class.
Needs build/a2b/src/brown_leather/ (SOURCES.md).
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
from mathutils import Matrix, Vector

import common as C

SEED = 4210
X = Vector((1, 0, 0))

# Muted species palettes (sRGB hex): content wildlifeDetails visual colours pulled toward the
# A2b palette family targets (hide #6b5f3e, belly #8a7a58) so the herd reads realistic, not toy.
SPECIES = {
    "compsognathus": dict(plan="theropod", envelope=(1, 1.5, 3), tris=4000, tex=512, length=3.0,
        body="#6a7440", stripe="#3a4224", belly="#9a9468", accent="#56602f",
        knobs=dict(neck=1.15, head=0.9, tail=1.25, girth=0.8, legs=1.0, arms=1.0, snout=1.0)),
    "oviraptor": dict(plan="theropod", envelope=(1.5, 3, 3), tris=4000, tex=512, length=3.0,
        body="#7a5440", stripe="#4a2e22", belly="#a08c6c", accent="#3e5a6e",
        knobs=dict(neck=1.1, head=1.0, tail=0.9, girth=1.0, legs=1.0, arms=1.15, snout=0.6),
        features=["crest", "armfeathers", "tailfan"]),
    "gallimimus": dict(plan="theropod", envelope=(2, 6, 5), tris=7000, tex=512, length=5.0,
        body="#7e6444", stripe="#4c3a26", belly="#a8946e", accent="#5e4a32",
        knobs=dict(neck=1.6, head=0.72, tail=1.0, girth=0.9, legs=1.45, arms=1.1, snout=1.1)),
    "utahraptor": dict(plan="theropod", envelope=(3, 6, 6), tris=7000, tex=512, length=6.0,
        body="#6e4c36", stripe="#3c2618", belly="#9c8664", accent="#a07c46",
        knobs=dict(neck=1.0, head=1.05, tail=1.0, girth=1.15, legs=1.05, arms=1.15, snout=1.0),
        features=["sickle", "mane", "armfeathers"]),
    "velociraptor": dict(plan="theropod", envelope=(2, 4, 4), tris=4000, tex=512, length=4.0,
        body="#80684a", stripe="#4a3624", belly="#a89474", accent="#5e3e2c",
        knobs=dict(neck=1.0, head=0.95, tail=1.1, girth=0.85, legs=1.0, arms=1.05, snout=1.15),
        features=["sickle", "armfeathers"]),
    "dilophosaurus": dict(plan="theropod", envelope=(3, 6, 6), tris=7000, tex=512, length=6.0,
        body="#4e6a58", stripe="#2a3c32", belly="#94a088", accent="#a08844",
        knobs=dict(neck=1.15, head=1.0, tail=1.0, girth=1.0, legs=1.05, arms=1.0, snout=1.1),
        features=["twincrest"]),
    "allosaurus": dict(plan="theropod", envelope=(5, 9, 12), tris=10000, tex=1024, length=12.0,
        body="#6e6246", stripe="#3e3424", belly="#9a8e6c", accent="#8a4a34",
        knobs=dict(neck=1.0, head=1.25, tail=1.0, girth=1.2, legs=1.0, arms=0.85, snout=1.0),
        features=["brow"]),
    "tyrannosaurus": dict(plan="theropod", envelope=(7, 12, 16), tris=14000, tex=1024, length=16.0,
        body="#5a6048", stripe="#30342a", belly="#8e8c6c", accent="#6e4a34",
        knobs=dict(neck=0.9, head=1.6, tail=1.0, girth=1.35, legs=1.1, arms=0.45, snout=0.9),
        features=["brow"]),
    "protoceratops": dict(plan="ceratopsian", envelope=(2.5, 3, 4), tris=4000, tex=512, length=4.0,
        body="#8a7450", stripe="#5a4630", belly="#ab9a76", accent="#8a5a3c",
        knobs=dict(frill=0.75, horns=0.0, girth=0.95, legs=1.0), features=["frill"]),
    "triceratops": dict(plan="ceratopsian", envelope=(5, 5, 8), tris=7000, tex=512, length=8.0,
        body="#6e5440", stripe="#463426", belly="#9c8a6c", accent="#8e6a44",
        knobs=dict(frill=1.1, horns=1.0, girth=1.1, legs=1.05), features=["frill", "horns"]),
    "brachiosaurus": dict(plan="sauropod", envelope=(8, 24, 18), tris=14000, tex=1024, length=18.0,
        body="#646c54", stripe="#3e4434", belly="#9a9a80", accent="#4e5640",
        knobs=dict(girth=1.0), features=["nasalarch"]),
}


def lerp3(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


# ------------------------------------------------------------------ plan skeletons
# Each plan returns: chains {name: [(key, pos, ra, rb)]} parented to an existing key,
# bones [(name, head_key, tail_key, parent)], tips (claws), eye position.


def theropod(k):
    g, legs = k["girth"], k["legs"]
    dz = 1.06 * (legs - 1)

    def up(p):
        return (p[0], p[1], p[2] + dz)

    spine = [
        ("pelvis", up((0, 0.00, 1.16)), 0.24 * g, 0.29 * g),
        ("belly", up((0, -0.30, 1.13)), 0.26 * g, 0.33 * g),
        ("chest", up((0, -0.56, 1.19)), 0.23 * g, 0.31 * g),
    ]
    chest = Vector(spine[2][1])
    nf, hs, sn = k["neck"], k["head"], k["snout"]
    neck_a = chest + (Vector((0, -0.22, 0.17)) * nf)
    head_back = chest + (Vector((0, -0.45, 0.50)) * nf)
    neck_b = (neck_a + head_back) / 2 + Vector((0, 0.02, 0.0))
    hb = head_back
    head = hb + Vector((0, -0.14, -0.01)) * hs
    snout = hb + Vector((0, -0.14 - 0.20 * sn, -0.03)) * hs
    nose = hb + Vector((0, -0.14 - 0.35 * sn, -0.055)) * hs
    jaw_a = hb + Vector((0, -0.10, -0.10)) * hs
    jaw_tip = hb + Vector((0, -0.14 - 0.31 * sn, -0.135)) * hs
    neck = [
        ("neck_a", tuple(neck_a), 0.14 * g * max(hs, 1) ** 0.5, 0.16 * g * max(hs, 1) ** 0.5),
        ("neck_b", tuple(neck_b), 0.11 * g * hs ** 0.6, 0.12 * g * hs ** 0.6),
        ("head_back", tuple(hb), 0.13 * hs, 0.13 * hs),
        ("head", tuple(head), 0.115 * hs, 0.11 * hs),
        ("snout", tuple(snout), 0.085 * hs, 0.065 * hs),
        ("nose", tuple(nose), 0.05 * hs, 0.042 * hs),
    ]
    jaw = [("jaw_a", tuple(jaw_a), 0.09 * hs, 0.055 * hs), ("jaw_tip", tuple(jaw_tip), 0.04 * hs, 0.026 * hs)]
    tl = k["tail"]
    pel = Vector(spine[0][1])
    tail = []
    for i, (dy, dzz, ra, rb) in enumerate([(0.40, -0.03, 0.20, 0.24), (0.82, -0.08, 0.14, 0.17), (1.25, -0.16, 0.09, 0.11), (1.65, -0.23, 0.05, 0.06), (2.05, -0.30, 0.022, 0.022)]):
        tail.append((f"tail{i + 1}", tuple(pel + Vector((0, dy * tl, dzz * tl))), ra * g, rb * g))
    chains = {"pelvis": [], "spine": spine, "neck": neck, "jaw": jaw, "tail": tail}
    leg_pts = [("hip", (0.18, 0.02, 1.06), 0.16, 0.20), ("knee", (0.25, -0.16, 0.66), 0.10, 0.11), ("ankle", (0.22, 0.14, 0.25), 0.055, 0.055), ("foot", (0.22, -0.04, 0.06), 0.05, 0.03)]
    toes = [(0.22, -0.27, 0.03), (0.14, -0.21, 0.03), (0.30, -0.21, 0.03)]
    am = k["arms"]
    tips = []
    limbs = []
    for side, sfx in ((1, "L"), (-1, "R")):
        leg = []
        for name, (x, y, z), ra, rb in leg_pts:
            zz = z * legs if name != "hip" else z + dz
            leg.append((f"{name}{sfx}", (x * side * g, y, zz), ra * g * (1 if name == "hip" else legs ** 0.3), rb * g))
        foot = Vector(leg[-1][1])
        toe_keys = []
        for i, (x, y, z) in enumerate(toes):
            p = (x * side * g, foot.y + (y + 0.04) * legs ** 0.5, z)
            toe_keys.append((f"toe{i}{sfx}", p, 0.028 * g, 0.02 * g))
            tips.append(("toe", Vector(p), "Toe" + sfx if i == 0 else "Foot" + sfx))
        sh = chest + Vector((0.16 * side * g, -0.04, -0.07))
        el = sh + Vector((0.07 * side, -0.07, -0.20)) * am
        wr = el + Vector((-0.02 * side, -0.15, -0.09)) * am
        arm = [(f"shoulder{sfx}", tuple(sh), 0.065 * g * am ** 0.5, 0.065 * g * am ** 0.5), (f"elbow{sfx}", tuple(el), 0.048 * am, 0.048 * am), (f"wrist{sfx}", tuple(wr), 0.032 * am, 0.03 * am)]
        fingers = []
        for i, dx in enumerate((-0.03, 0.03)):
            p = wr + Vector((dx * side, -0.09, -0.06)) * am
            fingers.append((f"finger{i}{sfx}", tuple(p), 0.014 * am, 0.012 * am))
            tips.append(("finger", p, "Arm" + sfx))
        limbs.append((sfx, leg, toe_keys, arm, fingers))
    bones = [
        ("Root", "pelvis", "@up", None),
        ("Spine", "pelvis", "belly", "Root"),
        ("Chest", "belly", "chest", "Spine"),
        ("Neck1", "chest", "neck_a", "Chest"),
        ("Neck2", "neck_a", "head_back", "Neck1"),
        ("Head", "head_back", "nose", "Neck2"),
        ("Jaw", "head_back", "jaw_tip", "Head"),
        ("Tail1", "pelvis", "tail1", "Root"),
        ("Tail2", "tail1", "tail2", "Tail1"),
        ("Tail3", "tail2", "tail3", "Tail2"),
        ("Tail4", "tail3", "tail4", "Tail3"),
        ("Tail5", "tail4", "tail5", "Tail4"),
    ]
    for sfx in ("L", "R"):
        bones += [
            (f"Thigh{sfx}", f"hip{sfx}", f"knee{sfx}", "Root"),
            (f"Shin{sfx}", f"knee{sfx}", f"ankle{sfx}", f"Thigh{sfx}"),
            (f"Foot{sfx}", f"ankle{sfx}", f"foot{sfx}", f"Shin{sfx}"),
            (f"Toe{sfx}", f"foot{sfx}", f"toe0{sfx}", f"Foot{sfx}"),
            (f"Arm{sfx}", f"shoulder{sfx}", f"wrist{sfx}", "Chest"),
        ]
    eye = hb + Vector((0.10 * hs, -0.12 * hs, 0.045 * hs))
    nostril = nose + Vector((0.028 * hs, -0.02 * hs, 0.02 * hs))
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, limbs=limbs, bones=bones, tips=tips, eye=eye, nostril=nostril, root_key="pelvis")


def ceratopsian(k):
    g, legs = k["girth"], k["legs"]
    spine = [
        ("pelvis", (0, 0.25, 1.15), 0.36 * g, 0.40 * g),
        ("belly", (0, -0.20, 1.12), 0.44 * g, 0.46 * g),
        ("chest", (0, -0.65, 1.06), 0.38 * g, 0.42 * g),
    ]
    neck = [
        ("neck_a", (0, -0.95, 1.00), 0.26 * g, 0.28 * g),
        ("head_back", (0, -1.15, 0.98), 0.25, 0.26),
        ("head", (0, -1.38, 0.90), 0.19, 0.20),
        ("snout", (0, -1.58, 0.82), 0.12, 0.12),
        ("nose", (0, -1.76, 0.74), 0.055, 0.065),
    ]
    jaw = [("jaw_a", (0, -1.34, 0.74), 0.15, 0.09), ("jaw_tip", (0, -1.66, 0.635), 0.05, 0.035)]
    tail = [
        ("tail1", (0, 0.65, 1.05), 0.24 * g, 0.27 * g),
        ("tail2", (0, 1.10, 0.92), 0.15 * g, 0.17 * g),
        ("tail3", (0, 1.55, 0.78), 0.08 * g, 0.09 * g),
        ("tail4", (0, 2.00, 0.65), 0.03, 0.03),
    ]
    tips, limbs = [], []
    for side, sfx in ((1, "L"), (-1, "R")):
        leg = [
            (f"hip{sfx}", (0.30 * side * g, 0.30, 0.95), 0.22 * g, 0.26 * g),
            (f"knee{sfx}", (0.34 * side * g, 0.15, 0.55 * legs), 0.14, 0.15),
            (f"ankle{sfx}", (0.33 * side * g, 0.30, 0.20 * legs), 0.10, 0.10),
            (f"foot{sfx}", (0.33 * side * g, 0.20, 0.05), 0.11, 0.06),
        ]
        toes = []
        for i, dx in enumerate((-0.07, 0.0, 0.07)):
            p = (0.33 * side * g + dx * side, 0.06, 0.03)
            toes.append((f"toe{i}{sfx}", p, 0.035, 0.025))
            tips.append(("hoof", Vector(p), "Foot" + sfx))
        arm = [
            (f"shoulder{sfx}", (0.30 * side * g, -0.62, 0.85), 0.17 * g, 0.18 * g),
            (f"elbow{sfx}", (0.37 * side * g, -0.58, 0.48 * legs), 0.12, 0.12),
            (f"wrist{sfx}", (0.35 * side * g, -0.64, 0.15 * legs), 0.09, 0.09),
            (f"hand{sfx}", (0.35 * side * g, -0.70, 0.04), 0.095, 0.05),
        ]
        fingers = []
        for i, dx in enumerate((-0.06, 0.0, 0.06)):
            p = (0.35 * side * g + dx * side, -0.80, 0.03)
            fingers.append((f"finger{i}{sfx}", p, 0.03, 0.022))
            tips.append(("hoof", Vector(p), "Forearm" + sfx))
        limbs.append((sfx, leg, toes, arm, fingers))
    bones = [
        ("Root", "pelvis", "@up", None),
        ("Spine", "pelvis", "belly", "Root"),
        ("Chest", "belly", "chest", "Spine"),
        ("Neck", "chest", "head_back", "Chest"),
        ("Head", "head_back", "nose", "Neck"),
        ("Jaw", "head_back", "jaw_tip", "Head"),
        ("Tail1", "pelvis", "tail1", "Root"),
        ("Tail2", "tail1", "tail2", "Tail1"),
        ("Tail3", "tail2", "tail3", "Tail2"),
        ("Tail4", "tail3", "tail4", "Tail3"),
    ]
    for sfx in ("L", "R"):
        bones += [
            (f"Thigh{sfx}", f"hip{sfx}", f"knee{sfx}", "Root"),
            (f"Shin{sfx}", f"knee{sfx}", f"ankle{sfx}", f"Thigh{sfx}"),
            (f"Foot{sfx}", f"ankle{sfx}", f"foot{sfx}", f"Shin{sfx}"),
            (f"UpperArm{sfx}", f"shoulder{sfx}", f"elbow{sfx}", "Chest"),
            (f"Forearm{sfx}", f"elbow{sfx}", f"hand{sfx}", f"UpperArm{sfx}"),
        ]
    eye = Vector((0.17, -1.30, 1.02))
    nostril = Vector((0.04, -1.66, 0.84))
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, limbs=limbs, bones=bones, tips=tips, eye=eye, nostril=nostril, root_key="pelvis")


def sauropod(k):
    g = k["girth"]
    spine = [
        ("pelvis", (0, 2.0, 8.6), 1.7 * g, 1.9 * g),
        ("belly", (0, 0.0, 8.8), 2.1 * g, 2.3 * g),
        ("chest", (0, -2.2, 9.6), 1.9 * g, 2.2 * g),
    ]
    neck = [
        ("n1", (0, -3.6, 11.4), 1.1, 1.2),
        ("n2", (0, -4.5, 13.6), 0.85, 0.9),
        ("n3", (0, -5.1, 15.8), 0.7, 0.7),
        ("n4", (0, -5.5, 18.0), 0.58, 0.58),
        ("n5", (0, -5.8, 20.0), 0.5, 0.5),
        ("n6", (0, -6.1, 21.6), 0.45, 0.45),
        ("head_back", (0, -6.4, 22.55), 0.52, 0.55),
        ("head", (0, -7.15, 22.6), 0.44, 0.42),
        ("nose", (0, -7.9, 22.45), 0.3, 0.27),
    ]
    jaw = [("jaw_a", (0, -7.0, 22.1), 0.36, 0.2), ("jaw_tip", (0, -7.8, 22.12), 0.22, 0.13)]
    tail = [
        ("tail1", (0, 3.2, 8.1), 1.25 * g, 1.4 * g),
        ("tail2", (0, 4.5, 7.4), 0.85 * g, 0.95 * g),
        ("tail3", (0, 5.9, 6.6), 0.55 * g, 0.6 * g),
        ("tail4", (0, 7.4, 5.8), 0.3, 0.3),
        ("tail5", (0, 9.0, 5.0), 0.12, 0.12),
    ]
    tips, limbs = [], []
    for side, sfx in ((1, "L"), (-1, "R")):
        leg = [
            (f"hip{sfx}", (1.4 * side, 2.2, 7.6), 1.0, 1.2),
            (f"knee{sfx}", (1.5 * side, 1.9, 4.4), 0.75, 0.75),
            (f"ankle{sfx}", (1.5 * side, 2.2, 1.3), 0.6, 0.6),
            (f"foot{sfx}", (1.5 * side, 1.9, 0.35), 0.72, 0.4),
        ]
        arm = [
            (f"shoulder{sfx}", (1.5 * side, -2.4, 8.6), 1.0, 1.05),
            (f"elbow{sfx}", (1.6 * side, -2.2, 5.0), 0.7, 0.7),
            (f"wrist{sfx}", (1.6 * side, -2.5, 1.6), 0.55, 0.55),
            (f"hand{sfx}", (1.6 * side, -2.6, 0.35), 0.62, 0.38),
        ]
        for i, dx in enumerate((-0.35, 0.0, 0.35)):
            tips.append(("nail", Vector((1.5 * side + dx, 1.3, 0.2)), "Foot" + sfx))
            tips.append(("nail", Vector((1.6 * side + dx, -3.05, 0.2)), "Forearm" + sfx))
        limbs.append((sfx, leg, [], arm, []))
    bones = [
        ("Root", "pelvis", "@up", None),
        ("Spine", "pelvis", "belly", "Root"),
        ("Chest", "belly", "chest", "Spine"),
        ("Neck1", "chest", "n1", "Chest"),
        ("Neck2", "n1", "n2", "Neck1"),
        ("Neck3", "n2", "n3", "Neck2"),
        ("Neck4", "n3", "n4", "Neck3"),
        ("Neck5", "n4", "n5", "Neck4"),
        ("Neck6", "n5", "head_back", "Neck5"),
        ("Head", "head_back", "nose", "Neck6"),
        ("Jaw", "head_back", "jaw_tip", "Head"),
        ("Tail1", "pelvis", "tail1", "Root"),
        ("Tail2", "tail1", "tail2", "Tail1"),
        ("Tail3", "tail2", "tail3", "Tail2"),
        ("Tail4", "tail3", "tail4", "Tail3"),
        ("Tail5", "tail4", "tail5", "Tail4"),
    ]
    for sfx in ("L", "R"):
        bones += [
            (f"Thigh{sfx}", f"hip{sfx}", f"knee{sfx}", "Root"),
            (f"Shin{sfx}", f"knee{sfx}", f"ankle{sfx}", f"Thigh{sfx}"),
            (f"Foot{sfx}", f"ankle{sfx}", f"foot{sfx}", f"Shin{sfx}"),
            (f"UpperArm{sfx}", f"shoulder{sfx}", f"elbow{sfx}", "Chest"),
            (f"Forearm{sfx}", f"elbow{sfx}", f"hand{sfx}", f"UpperArm{sfx}"),
        ]
    eye = Vector((0.38, -6.85, 22.85))
    nostril = Vector((0.12, -7.0, 23.25))
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, limbs=limbs, bones=bones, tips=tips, eye=eye, nostril=nostril, root_key="pelvis", base_length=16.9)


PLANS = {"theropod": theropod, "ceratopsian": ceratopsian, "sauropod": sauropod}
PLAN_BONES = {"theropod": 22, "ceratopsian": 20, "sauropod": 26}


# ------------------------------------------------------------------ geometry


def scaled(sk, s):
    """Scale every position and radius of a skeleton dict by s (final stud scale)."""

    def chain(c):
        return [(n, tuple(Vector(p) * s), ra * s, rb * s) for n, p, ra, rb in c]

    out = dict(sk)
    for key in ("spine", "neck", "jaw", "tail"):
        out[key] = chain(sk[key])
    out["limbs"] = [(sfx, chain(l), chain(t), chain(a), chain(f)) for sfx, l, t, a, f in sk["limbs"]]
    out["tips"] = [(kind, p * s, bone) for kind, p, bone in sk["tips"]]
    out["eye"], out["nostril"] = sk["eye"] * s, sk["nostril"] * s
    return out


def build_body(name, sk, target):
    me = bpy.data.meshes.new(name)
    obj = C.link(bpy.data.objects.new(name, me))
    bm = bmesh.new()
    keys, radii, idx = [], [], {}

    def add(key, pos, ra, rb):
        v = bm.verts.new(Vector(pos))
        idx[key] = v
        keys.append(key)
        radii.append((ra, rb))
        return v

    def run(chain, start):
        prev = start
        for n, p, ra, rb in chain:
            v = add(n, p, ra, rb)
            if prev is not None:
                bm.edges.new((prev, v))
            prev = v
        return prev

    # Tail (reversed) -> pelvis -> belly -> chest -> neck -> head; jaw branches at head_back.
    tail_end = None
    for n, p, ra, rb in reversed(sk["tail"]):
        v = add(n, p, ra, rb)
        if tail_end is not None:
            bm.edges.new((tail_end, v))
        tail_end = v
    last = run(sk["spine"], tail_end)
    run(sk["neck"], last)
    run(sk["jaw"], idx["head_back"])
    for sfx, leg, toes, arm, fingers in sk["limbs"]:
        foot = run(leg, idx["pelvis"])
        for n, p, ra, rb in toes:
            v = add(n, p, ra, rb)
            bm.edges.new((foot, v))
        wrist = run(arm, idx["chest"])
        for n, p, ra, rb in fingers:
            v = add(n, p, ra, rb)
            bm.edges.new((wrist, v))
    bm.to_mesh(me)
    bm.free()
    obj.modifiers.new("skin", "SKIN")
    for i, r in enumerate(radii):
        me.skin_vertices[0].data[i].radius = r
        me.skin_vertices[0].data[i].use_root = keys[i] == sk["root_key"]
    sub = obj.modifiers.new("sub", "SUBSURF")
    sub.levels = 2
    C.apply_modifiers(obj)
    tex = bpy.data.textures.new("lump", "CLOUDS")
    tex.noise_scale = 0.08 * sk["scale"]
    disp = obj.modifiers.new("disp", "DISPLACE")
    disp.texture = tex
    disp.strength = 0.008 * sk["scale"]
    C.apply_modifiers(obj)
    C.decimate_to(obj, target)
    C.finish_mesh(obj)
    return obj, {k: Vector(v) for k, v in [(n, p) for c in ("spine", "neck", "jaw", "tail") for n, p, _a, _b in sk[c]]}


def detail_object(name, bm, bone):
    obj = C.mesh_object(name, bm)
    vg = obj.vertex_groups.new(name="detail:" + bone)
    vg.add(list(range(len(obj.data.vertices))), 1.0, "REPLACE")
    return obj


def cone(bm, base, direction, length, radius, segments=6):
    d = direction.normalized()
    rot = d.to_track_quat("Z", "Y").to_matrix().to_4x4()
    m = Matrix.Translation(base) @ rot @ Matrix.Translation(Vector((0, 0, length / 2)))
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=radius, radius2=radius * 0.06, depth=length, matrix=m)


def plate(bm, center, normal, up, width, height, thick, segments=12, arc=math.pi):
    """Half-disc fan plate (frill, crest): its flat edge on `center`, bulging along `up`."""
    n = normal.normalized()
    u = up.normalized()
    side = u.cross(n).normalized()
    rim_f, rim_b = [], []
    for i in range(segments + 1):
        a = -arc / 2 + arc * i / segments
        p = center + side * math.sin(a) * width + u * math.cos(a) * height
        rim_f.append(bm.verts.new(p + n * thick / 2))
        rim_b.append(bm.verts.new(p - n * thick / 2))
    cf, cb = bm.verts.new(center + n * thick / 2), bm.verts.new(center - n * thick / 2)
    for i in range(segments):
        bm.faces.new((cf, rim_f[i], rim_f[i + 1]))
        bm.faces.new((cb, rim_b[i + 1], rim_b[i]))
        bm.faces.new((rim_f[i], rim_b[i], rim_b[i + 1], rim_f[i + 1]))


def build_details(sp, sk, points):
    """Claws, eyes and species features as separate objects, each tagged with its bone."""
    s = sk["scale"]
    feats = sp.get("features", [])
    out = {"claw": [], "eye": [], "accent": [], "ivory": []}
    bm = bmesh.new()
    for kind, p, bone in sk["tips"]:
        if kind == "toe":
            cone(bm, p, Vector((0, -1, -0.45)), 0.09 * s, 0.022 * s)
        elif kind == "finger":
            cone(bm, p, Vector((0, -1, -0.9)), 0.06 * s, 0.012 * s)
        elif kind == "hoof":
            cone(bm, p + Vector((0, -0.02 * s, 0)), Vector((0, -1, -0.6)), 0.06 * s, 0.03 * s)
        else:
            cone(bm, p, Vector((0, -1, -0.3)), 0.25 * s, 0.18 * s)
    # Tips are grouped by bone: one object per bone keeps the explicit weights exact.
    by_bone = {}
    for kind, p, bone in sk["tips"]:
        by_bone.setdefault(bone, []).append((kind, p))
    bm.free()
    for bone, items in by_bone.items():
        b = bmesh.new()
        for kind, p in items:
            if kind == "toe":
                cone(b, p, Vector((0, -1, -0.45)), 0.09 * s, 0.022 * s)
            elif kind == "finger":
                cone(b, p, Vector((0, -1, -0.9)), 0.06 * s, 0.012 * s)
            elif kind == "hoof":
                cone(b, p + Vector((0, -0.02 * s, 0)), Vector((0, -1, -0.6)), 0.06 * s, 0.035 * s)
            else:
                cone(b, p, Vector((0, -1, -0.3)), 0.012 * s, 0.012 * s)
        out["claw"].append(detail_object("claws_" + bone, b, bone))
    if "sickle" in feats:
        for sfx, side in (("L", 1), ("R", -1)):
            foot = points.get("foot" + sfx) or Vector()
            b = bmesh.new()
            # The raised second-toe sickle: a long curved-looking dark cone held up and forward.
            base = Vector((0.20 * side * s * sp["knobs"]["girth"], 0, 0))
            cone(b, base + Vector((0, sk["sickle_y"][sfx], 0.075 * s)), Vector((0, -0.6, 0.55)), 0.13 * s, 0.03 * s)
            out["claw"].append(detail_object("sickle" + sfx, b, "Foot" + sfx))
    b = bmesh.new()
    eye = sk["eye"]
    r = 0.034 * s * (sp["knobs"].get("head", 1.0) ** 0.5 if sp["plan"] == "theropod" else 1.0)
    if sp["plan"] == "sauropod":
        r = 0.16
    elif sp["plan"] == "ceratopsian":
        r = 0.045 * s
    for side in (1, -1):
        bmesh.ops.create_uvsphere(b, u_segments=10, v_segments=8, radius=r, matrix=Matrix.Translation(Vector((eye.x * side, eye.y, eye.z))))
    eyes = detail_object("eyes", b, "Head")
    C.finish_mesh(eyes)
    out["eye"].append(eyes)
    hb, nose = points["head_back"], points["nose"]
    fwd = (nose - hb).normalized()
    if "crest" in feats:
        b = bmesh.new()
        plate(b, hb + Vector((0, -0.07 * s, 0.09 * s)), X, Vector((0, -0.25, 1)), 0.09 * s, 0.17 * s, 0.025 * s, 10)
        out["accent"].append(detail_object("crest", b, "Head"))
    if "twincrest" in feats:
        b = bmesh.new()
        for side in (1, -1):
            c = hb + fwd * 0.12 * s + Vector((0.045 * side * s, 0, 0.08 * s))
            plate(b, c, Vector((1, 0, -0.12 * side)), Vector((0, 0.15, 1)), 0.17 * s, 0.11 * s, 0.012 * s, 12)
        out["accent"].append(detail_object("twincrest", b, "Head"))
    if "brow" in feats:
        b = bmesh.new()
        hs = sp["knobs"]["head"]
        for side in (1, -1):
            c = hb + Vector((0.075 * side * s * hs, -0.10 * s * hs, 0.10 * s * hs))
            cone(b, c, Vector((0.25 * side, -0.4, 1)), 0.07 * s * hs, 0.03 * s * hs)
        out["accent"].append(detail_object("brow", b, "Head"))
    if "mane" in feats:
        # Feather mane: a row of short quill spikes down the back of the neck.
        n0, n1 = points["neck_a"], points["head_back"]
        b = bmesh.new()
        for i in range(7):
            t = i / 6
            p = n0.lerp(n1, t) + Vector((0, 0.06 * s, 0.11 * s * (1.2 - 0.4 * t)))
            cone(b, p, Vector((0, 0.9, 0.6)), 0.14 * s, 0.03 * s, 5)
        out["accent"].append(detail_object("mane_neck", b, "Neck2"))
    if "armfeathers" in feats:
        for sfx, side in (("L", 1), ("R", -1)):
            b = bmesh.new()
            sh = Vector(sk["arm_pts"][sfx][0])
            wr = Vector(sk["arm_pts"][sfx][2])
            for i in range(5):
                t = 0.25 + 0.75 * i / 4
                p = sh.lerp(wr, t) + Vector((0.01 * side * s, 0.02 * s, 0))
                cone(b, p, Vector((0.15 * side, 0.7, -0.5)), (0.10 + 0.03 * i) * s, 0.022 * s, 4)
            out["accent"].append(detail_object("armfeathers" + sfx, b, "Arm" + sfx))
    if "tailfan" in feats:
        tip = points["tail5"]
        b = bmesh.new()
        for i in range(7):
            a = -0.6 + 1.2 * i / 6
            cone(b, tip + Vector((0, -0.12 * s, 0)), Vector((math.sin(a), 1, 0.15)), 0.22 * s, 0.03 * s, 4)
        out["accent"].append(detail_object("tailfan", b, "Tail5"))
    if "frill" in feats:
        f = sp["knobs"]["frill"]
        b = bmesh.new()
        plate(b, hb + Vector((0, 0.02 * s, 0.10 * s)), Vector((0, -1, -0.55)), Vector((0, 0.55, 1)), 0.48 * s * f, 0.5 * s * f, 0.05 * s, 16, math.pi * 1.1)
        # Rim knobs (epoccipitals) along the frill edge.
        n = Vector((0, -1, -0.55)).normalized()
        u = Vector((0, 0.55, 1)).normalized()
        side = u.cross(n).normalized()
        for i in range(9):
            a = -math.pi * 0.55 + math.pi * 1.1 * i / 8
            p = hb + Vector((0, 0.02 * s, 0.10 * s)) + side * math.sin(a) * 0.48 * s * f + u * math.cos(a) * 0.5 * s * f
            bmesh.ops.create_icosphere(b, subdivisions=1, radius=0.045 * s * f, matrix=Matrix.Translation(p))
        out["accent"].append(detail_object("frill", b, "Head"))
    if "horns" in feats:
        h = sp["knobs"]["horns"]
        b = bmesh.new()
        for side in (1, -1):
            cone(b, hb + Vector((0.13 * side * s, -0.16 * s, 0.17 * s)), Vector((0.12 * side, -0.85, 0.55)), 0.48 * s * h, 0.055 * s, 8)
        cone(b, nose + Vector((0, 0.10 * s, 0.07 * s)), Vector((0, -0.3, 1)), 0.18 * s * h, 0.045 * s, 8)
        out["ivory"].append(detail_object("horns", b, "Head"))
    if sp["plan"] == "ceratopsian":
        b = bmesh.new()
        cone(b, nose + Vector((0, 0.02 * s, -0.015 * s)), Vector((0, -0.6, -0.8)), 0.09 * s, 0.05 * s, 8)
        out["ivory"].append(detail_object("beak", b, "Head"))
    if "nasalarch" in feats:
        b = bmesh.new()
        bmesh.ops.create_uvsphere(b, u_segments=12, v_segments=8, radius=0.34, matrix=Matrix.Translation(Vector((0, -6.85, 23.0))) @ Matrix.Diagonal((1.0, 1.4, 0.8, 1)))
        out["accent"].append(detail_object("nasalarch", b, "Head"))
    return out


# ------------------------------------------------------------------ materials


def make_hide_mat(sp, sk):
    s = sk["scale"]
    length = sp["length"]

    def hide_mat(nodes, links):
        coord = nodes.new("ShaderNodeTexCoord").outputs["Object"]
        geo = nodes.new("ShaderNodeNewGeometry")
        nz = nodes.new("ShaderNodeSeparateXYZ")
        links.new(geo.outputs["Normal"], nz.inputs["Vector"])
        shade = C.ramp(nodes, links, nz.outputs["Z"], [(-0.55, C.hexlin(sp["belly"])), (-0.05, C.hexlin(sp["body"])), (0.6, C.hexlin(sp["body"]))])
        # Irregular transverse stripes on the back and flanks only; band count scales with length.
        wave = nodes.new("ShaderNodeTexWave")
        wave.wave_type = "BANDS"
        wave.bands_direction = "Y"
        wave.inputs["Scale"].default_value = 2.6 * 3.55 / length * (1.0 if sp["plan"] != "sauropod" else 1.6)
        wave.inputs["Distortion"].default_value = 9.0
        wave.inputs["Detail"].default_value = 3.0
        links.new(coord, wave.inputs["Vector"])
        brk = C.noise(nodes, 3.5 * 3.55 / length, 4, 0.55, coord, links)
        sm = nodes.new("ShaderNodeMath")
        sm.operation = "MULTIPLY"
        links.new(wave.outputs["Fac"], sm.inputs[0])
        links.new(brk.outputs["Fac"], sm.inputs[1])
        lo = 0.30 if sp["plan"] != "sauropod" else 0.36
        band = C.ramp(nodes, links, sm.outputs["Value"], [(lo, (0, 0, 0)), (lo + 0.12, (1, 1, 1))])
        back = C.ramp(nodes, links, nz.outputs["Z"], [(-0.2, (0, 0, 0)), (0.25, (1, 1, 1))])
        m1 = nodes.new("ShaderNodeMath")
        m1.operation = "MULTIPLY"
        links.new(band.outputs["Color"], m1.inputs[0])
        links.new(back.outputs["Color"], m1.inputs[1])
        stripe_col = nodes.new("ShaderNodeRGB")
        stripe_col.outputs[0].default_value = (*C.hexlin(sp["stripe"]), 1)
        col = C.mix(nodes, links, m1.outputs["Value"], shade.outputs["Color"], stripe_col.outputs[0])

        def dist_to(point, radius_in, radius_out):
            vm = nodes.new("ShaderNodeVectorMath")
            vm.operation = "DISTANCE"
            links.new(coord, vm.inputs[0])
            vm.inputs[1].default_value = point
            return C.ramp(nodes, links, vm.outputs["Value"], [(radius_in, (1, 1, 1)), (radius_out, (0, 0, 0))]).outputs["Color"]

        dark = nodes.new("ShaderNodeRGB")
        dark.outputs[0].default_value = (*C.hexlin("#1c1712"), 1)
        eye, nos = sk["eye"], sk["nostril"]
        es = 0.035 * s if sp["plan"] != "sauropod" else 0.18
        for side in (1, -1):
            col = C.mix(nodes, links, dist_to((nos.x * side, nos.y, nos.z), es * 0.22, es * 0.4), col, dark.outputs[0])
            ring = dist_to((eye.x * side, eye.y + es * 0.9, eye.z), es, es * 2.2)
            k = nodes.new("ShaderNodeMath")
            k.operation = "MULTIPLY"
            k.inputs[1].default_value = 0.65
            links.new(ring, k.inputs[0])
            stripe2 = nodes.new("ShaderNodeRGB")
            stripe2.outputs[0].default_value = (*C.hexlin(sp["stripe"]), 1)
            col = C.mix(nodes, links, k.outputs["Value"], col, stripe2.outputs[0])
        # CC0 leather scan as micro-detail at a constant texel density per stud.
        mp = nodes.new("ShaderNodeMapping")
        density = 1.25 if length < 8 else 0.7
        mp.inputs["Scale"].default_value = (density, density, density)
        links.new(coord, mp.inputs["Vector"])
        la = nodes.new("ShaderNodeTexImage")
        la.image = C.load_image(os.path.join(C.SRC_DIR, "brown_leather", "brown_leather_albedo_1k.png"))
        la.projection = "BOX"
        la.projection_blend = 0.3
        links.new(mp.outputs["Vector"], la.inputs["Vector"])
        bw = nodes.new("ShaderNodeRGBToBW")
        links.new(la.outputs["Color"], bw.inputs["Color"])
        det = C.ramp(nodes, links, bw.outputs["Val"], [(0.05, (0.62, 0.62, 0.62)), (0.25, (1.2, 1.2, 1.2))])
        mul = nodes.new("ShaderNodeMix")
        mul.data_type = "RGBA"
        mul.blend_type = "MULTIPLY"
        mul.inputs["Factor"].default_value = 1.0
        links.new(col, mul.inputs["A"])
        links.new(det.outputs["Color"], mul.inputs["B"])
        ln = nodes.new("ShaderNodeTexImage")
        ln.image = C.load_image(os.path.join(C.SRC_DIR, "brown_leather", "brown_leather_nor_gl_1k.png"), True)
        ln.projection = "BOX"
        ln.projection_blend = 0.3
        links.new(mp.outputs["Vector"], ln.inputs["Vector"])
        nmap = nodes.new("ShaderNodeNormalMap")
        nmap.inputs["Strength"].default_value = 1.5
        links.new(ln.outputs["Color"], nmap.inputs["Color"])
        vor = nodes.new("ShaderNodeTexVoronoi")
        vor.inputs["Scale"].default_value = min(23.0, 380.0 / length)
        links.new(coord, vor.inputs["Vector"])
        b = nodes.new("ShaderNodeBump")
        b.inputs["Strength"].default_value = 0.3
        links.new(vor.outputs["Distance"], b.inputs["Height"])
        links.new(nmap.outputs["Normal"], b.inputs["Normal"])
        rough = C.ramp(nodes, links, bw.outputs["Val"], [(0.05, (0.9, 0.9, 0.9)), (0.3, (0.7, 0.7, 0.7))])
        return mul.outputs["Result"], rough.outputs["Color"], b.outputs["Normal"]

    return hide_mat


def flat_mat(hexcol, rough):
    def build(nodes, links):
        c = nodes.new("ShaderNodeRGB")
        c.outputs[0].default_value = (*C.hexlin(hexcol), 1)
        r = nodes.new("ShaderNodeValue")
        r.outputs[0].default_value = rough
        return c.outputs[0], r.outputs[0], None

    return build


def eye_mat(nodes, links):
    geo = nodes.new("ShaderNodeNewGeometry")
    sep = nodes.new("ShaderNodeSeparateXYZ")
    links.new(geo.outputs["Normal"], sep.inputs["Vector"])
    ax = nodes.new("ShaderNodeMath")
    ax.operation = "ABSOLUTE"
    links.new(sep.outputs["X"], ax.inputs[0])
    col = C.ramp(nodes, links, ax.outputs["Value"], [(0.55, C.hexlin("#201a14")), (0.62, C.hexlin("eye")), (0.86, C.hexlin("eye")), (0.9, (0.005, 0.004, 0.003))])
    r = nodes.new("ShaderNodeValue")
    r.outputs[0].default_value = 0.2
    return col.outputs["Color"], r.outputs[0], None


# ------------------------------------------------------------------ rig


def build_armature(name, sk, points):
    arm_data = bpy.data.armatures.new(name + "Rig")
    arm = C.link(bpy.data.objects.new(name + "Rig", arm_data))
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    made = {}
    for bname, h, t, parent in sk["bones"]:
        b = arm_data.edit_bones.new(bname)
        b.head = points[h]
        b.tail = points[h] + Vector((0, 0, 0.3 * sk["scale"])) if t == "@up" else points[t]
        # Local X = creature side axis (+X world): +X rotation lifts the tip, Z is yaw.
        y = (b.tail - b.head).normalized()
        z = X.cross(y)
        if z.length > 1e-4:
            b.align_roll(z.normalized())
        if parent:
            b.parent = made[parent]
            b.use_connect = (made[parent].tail - b.head).length < 1e-4
        made[bname] = b
    bpy.ops.object.mode_set(mode="OBJECT")
    return arm


def weight(body, arm):
    """Heat weights for the body, explicit 1.0 weights for tagged details, nearest bone fallback."""
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")
    bones = {b.name: (arm.matrix_world @ b.head_local, arm.matrix_world @ b.tail_local) for b in arm.data.bones}
    groups = {g.index: g.name for g in body.vertex_groups}
    bone_groups = {name: body.vertex_groups.get(name) or body.vertex_groups.new(name=name) for name in bones}
    detail = {}
    for v in body.data.vertices:
        for ge in v.groups:
            gname = groups.get(ge.group, "")
            if gname.startswith("detail:") and ge.weight > 0.5:
                detail[v.index] = gname[7:]
    fixed = 0
    for v in body.data.vertices:
        has = any(not groups.get(ge.group, "").startswith("detail:") and ge.weight > 1e-4 for ge in v.groups)
        target = detail.get(v.index)
        if target is None and has:
            continue
        if target is None:
            p = body.matrix_world @ v.co
            best, target = 1e18, None
            for name, (h, t) in bones.items():
                seg = t - h
                u = max(0.0, min(1.0, (p - h).dot(seg) / max(seg.length_squared, 1e-9)))
                d = (h + seg * u - p).length
                if d < best:
                    best, target = d, name
        for g in bone_groups.values():
            g.remove([v.index])
        bone_groups[target].add([v.index], 1.0, "REPLACE")
        fixed += 1
    for g in list(body.vertex_groups):
        if g.name.startswith("detail:"):
            body.vertex_groups.remove(g)
    weighted = sum(1 for v in body.data.vertices if any(ge.weight > 1e-4 for ge in v.groups))
    return weighted, fixed


# ------------------------------------------------------------------ main


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :]
    outdir = C.out_dir()
    key = argv[1]
    sp = SPECIES[key]
    name = "Robango" + key[0].upper() + key[1:]
    C.reset(SEED + sorted(SPECIES).index(key))
    plan = PLANS[sp["plan"]]
    raw = plan(sp["knobs"])
    base = raw.get("base_length")
    if base is None:
        ys = [p[1] for c in ("spine", "neck", "tail") for _n, p, _a, _b in raw[c]]
        base = max(ys) - min(ys)
    s = sp["length"] / base
    sk = scaled(raw, s)
    sk["scale"] = s
    sk["arm_pts"] = {sfx: [a[1] for a in arm] for sfx, _l, _t, arm, _f in sk["limbs"]}
    sk["sickle_y"] = {sfx: leg[-1][1][1] - 0.02 * s for sfx, leg, _t, _a, _f in sk["limbs"]}
    points = {}
    for c in ("spine", "neck", "jaw", "tail"):
        for n, p, _a, _b in sk[c]:
            points[n] = Vector(p)
    for sfx, leg, toes, arm, fingers in sk["limbs"]:
        for n, p, _a, _b in leg + toes + arm + fingers:
            points[n] = Vector(p)
    detail_budget = 900 if sp["tris"] <= 4000 else 1400
    body, _ = build_body(name, sk, sp["tris"] - detail_budget)
    body.data.materials.append(C.material("hide", make_hide_mat(sp, sk)))
    det = build_details(sp, sk, points)
    mats = {
        "claw": C.material("claw", flat_mat("claw", 0.45)),
        "eye": C.material("eye", eye_mat),
        "accent": C.material("accent", flat_mat(sp["accent"], 0.8)),
        "ivory": C.material("ivory", flat_mat("#b8ab88", 0.6)),
    }
    parts = [body]
    for kind, objs in det.items():
        for o in objs:
            o.data.materials.append(mats[kind])
            parts.append(o)
    body = C.join(parts, name)
    C.unwrap(body, 0.006)
    sil = C.silhouette(name, outdir, [body])
    maps = C.bake(body, name, outdir, size=sp["tex"])
    arm = build_armature(name, sk, points)
    weighted, fixed = weight(body, arm)
    pv = C.preview(name, outdir, [body])
    fbx = C.export_fbx(name, outdir, [arm, body])
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for c in body.bound_box:
        w = body.matrix_world @ Vector(c)
        lo = Vector(map(min, lo, w))
        hi = Vector(map(max, hi, w))
    size = hi - lo
    assert len(arm.data.bones) == PLAN_BONES[sp["plan"]], (len(arm.data.bones), PLAN_BONES[sp["plan"]])
    C.report(
        name,
        [body],
        {"fbx": fbx, "preview": pv, "silhouettes": sil, **maps},
        {
            "species": key,
            "plan": sp["plan"],
            "seed": SEED + sorted(SPECIES).index(key),
            "bones": len(arm.data.bones),
            "weighted_vertices": weighted,
            "fallback_or_detail_vertices": fixed,
            "vertices": len(body.data.vertices),
            "size_studs": [round(size.x, 2), round(size.z, 2), round(size.y, 2)],
            "envelope": sp["envelope"],
            "budget_tris": sp["tris"],
            "texture": sp["tex"],
            "root_height": round(points["pelvis"].z - lo.z, 3),
            "bbox_min_z": round(lo.z, 3),
        },
    )


main()
