"""L6 survivor avatars: four adult survivors in period work clothes on two body types.

Headless only:
  blender -b --factory-startup --python games/robango-island/assets/blender/gen_survivors.py -- build/l6
Outputs build/l6/out/RobangoSurvivors.fbx (one package; one armature "Rig__rig__<preset>" per preset), silhouettes, previews
and build/l6/out/rows.json (pieces and triangles per preset).

R15 fit (SurvivorAvatar.luau, kind "rig"): every mesh piece belongs to ONE R15 body part and is
named "<R15Part>__<slot>__<preset>" (unique across the package). The geometry is authored in rig space around the blank R15 body
(characterR15.rbxm, scale 1: HumanoidRootPart centre at the origin, joints below), so the runtime
welds each piece to its body part at the offset it has here. The piece "Anchor" is a tiny
octahedron centred on the rig origin: the runtime measures every piece against it, which makes
the fit independent of where the importer puts the model.
L6b: every preset is painted (survivor_paint.py: woven cloth patterns, folds, leather, painted face,
hair strands, form light and occlusion) and baked into ONE colour atlas per preset; all pieces of a
preset share it. The runtime moves it onto MeshPart.TextureContent (MeshTexture.bake).
Shapes are our own and code-authored; nothing was traced from the reference game. No weapons,
insignia, badges or uniform cuts; no cords or loops at the neck. Seed 6060.
"""

import json
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
from mathutils import Vector

import common as C
import survivor_geo as G
import survivor_paint as P
import survivor_skin as S

SEED = 6060
PACKAGE = "RobangoSurvivors"

# R15 rest joints relative to the HumanoidRootPart (measured from characterR15.rbxm, scale 1).
WAIST, NECK, SHOULDER, ELBOW, WRIST = 0.05, 1.65, 1.413, 0.685, -0.075
HIP, KNEE, ANKLE, FLOOR = -0.35, -1.172, -2.098, -2.35

# Base colours of the baked atlases (sRGB). SurvivorAvatar.luau PRESETS[*].palette keeps the
# untextured fallback colours; they follow these.
PREVIEW = {
    "skin": "#c08f6c", "skin_dark": "#7c5640", "skin_light": "#e2bc9c", "eye": "#2a211c",
    "lip": "#9a5a4a", "brow": "#3a2a1e", "hair": "#4a3222", "hair_dark": "#231a14",
    "shirt": "#d8cdb4", "vest": "#5a4430", "trousers": "#8a7a5a", "belt": "#3a2a1c",
    "boots": "#4a3424", "overall": "#4f5d6c", "hat": "#5b574e", "braces": "#3d2a1d",
    "jacket": "#9a7a44", "straw": "#c9b07a", "band": "#5a3e2a",
}

BODY = {
    # x: arm centre line; hip: thigh centre; scale factors for girth.
    "A": {"arm_x": 0.56, "hip_x": 0.2, "g": 1.0, "chest": 0.45, "waist": 0.35, "hips": 0.37,
          "arm": 0.12, "fore": 0.09, "thigh": 0.19, "calf": 0.13, "head": 1.08},
    "B": {"arm_x": 0.5, "hip_x": 0.2, "g": 0.9, "chest": 0.39, "waist": 0.29, "hips": 0.38,
          "arm": 0.1, "fore": 0.078, "thigh": 0.19, "calf": 0.12, "head": 1.03},
}

PRESETS = {
    "ranger": {"body": "A", "skin": "skin", "hair": "short", "top": "rolled", "over": "waistcoat",
               "legs": "trousers", "boots": "ankle", "hat": None, "beard": False},
    "scout": {"body": "B", "skin": "skin_light", "hair": "ponytail", "top": "long", "over": "braces",
              "legs": "trousers", "boots": "tall", "hat": None, "beard": False},
    "forager": {"body": "B", "skin": "skin_dark", "hair": "bob", "top": "long", "over": "jacket",
                "legs": "trousers", "boots": "ankle", "hat": "brim", "beard": False},
    "drifter": {"body": "A", "skin": "skin", "hair": "short", "top": "rolled", "over": "overalls",
                "legs": "overall", "boots": "ankle", "hat": "cap", "beard": True},
}


PALETTES = {
    "ranger": {"skin": "#ba8e68", "shirt": "#b4a88c", "vest": "#4e3a28", "trousers": "#5a5040",
               "belt": "#3a2a1c", "boots": "#4a3424", "hair": "#4a3222", "brow": "#2e2016",
               "iris": "#4a3020", "lip": "#9a5a4a"},
    "scout": {"skin": "#e4be9e", "shirt": "#8a3e30", "braces": "#33231a", "trousers": "#625a44",
              "belt": "#3a2a1c", "boots": "#5a3c26", "hair": "#7a4a2a", "brow": "#4a2c1a",
              "iris": "#3e5a46", "lip": "#a8605a"},
    "forager": {"skin": "#7c563e", "shirt": "#a89c80", "jacket": "#7e6234", "trousers": "#454a38",
                "belt": "#3a2a1c", "boots": "#3e2c20", "hair": "#231a14", "brow": "#16100c",
                "hat": "#5e4e36", "band": "#2a1e14", "iris": "#2a1a10", "lip": "#7a4436"},
    "drifter": {"skin": "#a07050", "shirt": "#a8a492", "overall": "#34496a", "trousers": "#34496a",
                "belt": "#3a2a1c", "boots": "#4a3424", "hair": "#46301f", "brow": "#2a1c12",
                "hat": "#4a4a46", "iris": "#3a3a46", "lip": "#8a5444"},
}

# Woven patterns per slot (no camouflage, no insignia).
LOOKS = {
    "ranger": {"shirt": {"pattern": "pinstripe", "accent": "#8a8a96"}, "vest": {"pattern": "tweed", "accent": "#7a6044"},
               "trousers": {"pattern": "canvas"}},
    "scout": {"shirt": {"pattern": "check", "accent": "#4a2a24"}, "trousers": {"pattern": "canvas"}},
    "forager": {"jacket": {"pattern": "canvas"}, "shirt": {"pattern": "pinstripe", "accent": "#9a8a6a"},
                "trousers": {"pattern": "canvas"}, "hat": {"pattern": "tweed", "accent": "#55493a"}},
    "drifter": {"overall": {"pattern": "denim"}, "trousers": {"pattern": "denim"},
                "shirt": {"pattern": "check", "accent": "#7a8090"}, "hat": {"pattern": "tweed", "accent": "#3a3a36"}},
}


class Fig:
    def __init__(self):
        self.pieces = {}

    def bm(self, part, slot):
        key = f"{part}__{slot}"
        if key not in self.pieces:
            self.pieces[key] = bmesh.new()
        return self.pieces[key]


def sections_ring(sections, n=18, p=2.0):
    return [G.ring(y, rx, rz, cx, cz, n=n, p=p) for (y, rx, rz, cx, cz) in sections]


def torso_sections(b, grow=0.0):
    g = grow
    return [
        (WAIST, b["waist"] + g, 0.21 + g, 0, 0.01),
        (0.45, b["waist"] + 0.03 + g, 0.215 + g, 0, 0.0),
        (0.85, b["chest"] - 0.03 + g, 0.24 + g, 0, -0.015),
        (1.18, b["chest"] + g, 0.235 + g, 0, -0.01),
        (1.42, b["chest"] - 0.02 + g, 0.2 + g, 0, 0.0),
        (1.58, b["chest"] * 0.55 + g, 0.15 + g, 0, 0.01),
    ]


def pelvis_sections(b, grow=0.0):
    g = grow
    return [
        (-0.6, b["hips"] * 0.55 + g, 0.17 + g, 0, 0.0),
        (-0.45, b["hips"] * 0.92 + g, 0.215 + g, 0, 0.0),
        (-0.3, b["hips"] + g, 0.225 + g, 0, 0.0),
        (-0.12, b["hips"] - 0.01 + g, 0.225 + g, 0, 0.0),
        (WAIST + 0.07, b["waist"] + g, 0.21 + g, 0, 0.01),
    ]


def limb(fig, part, slot, x, ys, radii, n=12, cap0=True, cap1=True, cz=0.0, flat=1.0):
    secs = [(y, r, r * flat, x, cz) for y, r in zip(ys, radii)]
    G.loft(fig.bm(part, slot), None, sections_ring(G.dense(secs, 0.12), n=n), cap0=cap0, cap1=cap1)


def body(fig, b, preset):
    skin = preset["skin"]
    # Neck (UpperTorso) up into the head.
    limb(fig, "UpperTorso", skin, 0, [1.42, 1.58, 1.74], [0.12 * b["g"] + 0.01, 0.11, 0.105], cz=0.02)
    # Neck tendons into the collarbone notch (fused: no ring where the neck meets the head).
    G.ellipsoid(fig.bm("UpperTorso", skin), None, (0, 1.62, -0.03), (0.13, 0.12, 0.11), nlat=6, nlon=10)
    for side, name in ((-1, "Left"), (1, "Right")):
        x = side * b["arm_x"]
        # Shoulder cap and upper arm, elbow ball on the forearm, hand.
        G.ellipsoid(fig.bm(f"{name}UpperArm", "upperarm"), None, (x - side * 0.03, 1.33, 0.0),
                    (b["arm"] + 0.02, b["arm"] + 0.03, b["arm"] + 0.02), nlat=8, nlon=12)
        limb(fig, f"{name}UpperArm", "upperarm", x, [1.38, 1.0, ELBOW + 0.02], [b["arm"] + 0.01, b["arm"], b["arm"] * 0.78])
        G.ellipsoid(fig.bm(f"{name}LowerArm", "forearm"), None, (x, ELBOW, 0.0),
                    (b["arm"] * 0.8,) * 3, nlat=6, nlon=10)
        limb(fig, f"{name}LowerArm", "forearm", x, [ELBOW, 0.45, WRIST - 0.04], [b["fore"], b["fore"] * 0.95, b["fore"] * 0.68])
        hand = fig.bm(f"{name}Hand", skin)
        G.ellipsoid(hand, None, (x, -0.17, 0.0), (b["fore"] * 0.6, 0.11, b["fore"] * 1.0), nlat=8, nlon=10)  # palm
        for k in range(4):  # slightly curled fingers side by side
            fz = (k - 1.5) * b["fore"] * 0.42
            G.ellipsoid(hand, None, (x + side * 0.008, -0.31 + abs(k - 1.5) * 0.015, fz), (0.026, 0.075, 0.021), nlat=5, nlon=8)
        G.ellipsoid(hand, None, (x - side * 0.04, -0.2, -0.07), (0.026, 0.065, 0.026), nlat=5, nlon=8)  # thumb
        # Legs: thigh (UpperLeg), knee ball + shin (LowerLeg), foot under the boot.
        hx = side * b["hip_x"]
        limb(fig, f"{name}UpperLeg", "thigh", hx, [-0.25, -0.7, KNEE - 0.03], [b["thigh"], b["thigh"] * 0.85, b["calf"] * 0.95])
        G.ellipsoid(fig.bm(f"{name}LowerLeg", "shin"), None, (hx, KNEE, -0.01), (b["calf"],) * 3, nlat=6, nlon=10)
        limb(fig, f"{name}LowerLeg", "shin", hx, [KNEE, -1.42, -1.85, ANKLE + 0.02],
             [b["calf"] * 0.95, b["calf"], b["calf"] * 0.72, b["calf"] * 0.62])


def head(fig, b, preset):
    s = b["head"]
    skin = preset["skin"]
    cy = 1.95

    def skull(p):
        x, y, z = p
        t = (cy - y) / (0.26 * s)  # >0 below the centre
        if t > 0:
            x *= 1 - 0.2 * t ** 2  # broad, square jaw
            z = z * (1 - 0.14 * t) - 0.03 * t  # chin forward
        if z < -0.17 * s:
            z = -0.17 * s + (z + 0.17 * s) * 0.55  # flatter face plane: cheeks and jaw read as planes
        return (x, y, z)

    h = fig.bm("Head", skin)
    G.ellipsoid(h, None, (0, cy, 0.0), (0.19 * s, 0.26 * s, 0.22 * s), nlat=12, nlon=18, deform=skull)
    # Nose: bridge from the brow, a tip and wings (a clear plane change at play distance).
    G.ellipsoid(h, None, (0, cy + 0.02, -0.2 * s), (0.026, 0.075, 0.035), nlat=6, nlon=8)
    G.ellipsoid(h, None, (0, cy - 0.04, -0.222 * s), (0.034, 0.03, 0.036), nlat=6, nlon=8)
    for side in (-1, 1):
        G.ellipsoid(h, None, (side * 0.024, cy - 0.05, -0.2 * s), (0.02, 0.018, 0.022), nlat=4, nlon=8)  # nose wings
        # Brow ridge over each eye: it shades the eye like a socket.
        G.ellipsoid(h, None, (side * 0.07 * s, cy + 0.088, -0.183 * s), (0.06, 0.022, 0.03), nlat=5, nlon=10)
    for side in (-1, 1):
        G.ellipsoid(h, None, (side * 0.19 * s, cy, 0.02), (0.028, 0.06, 0.045), nlat=5, nlon=8)  # ear
        G.ellipsoid(fig.bm("Head", "eye"), None, (side * 0.07 * s, cy + 0.045, -0.18 * s), (0.034, 0.024, 0.016), nlat=6, nlon=10)
        G.ellipsoid(fig.bm("Head", "brow"), None, (side * 0.072 * s, cy + 0.1, -0.205 * s), (0.058, 0.02, 0.02), nlat=4, nlon=8)
    G.ellipsoid(fig.bm("Head", "lip"), None, (0, cy - 0.12 * s, -0.19 * s), (0.05, 0.012, 0.014), nlat=4, nlon=8)
    hair = fig.bm("Head", "hair")
    style = preset["hair"]
    locks(hair, cy, s, style)
    if preset["beard"]:
        G.ellipsoid(hair, None, (0, cy - 0.07, -0.01), (0.185 * s, 0.2 * s, 0.215 * s), nlat=12, nlon=18,
                    keep=lambda p: p[1] < cy - 0.06 and p[2] < 0.02)
    hat = preset["hat"]
    if hat == "cap":
        hb = fig.bm("Head", "hat")
        G.ellipsoid(hb, None, (0, cy + 0.13, 0.01), (0.225 * s, 0.13, 0.245 * s), nlat=8, nlon=18,
                    keep=lambda p: p[1] > cy + 0.1)
        G.ellipsoid(hb, None, (0, cy + 0.12, -0.21 * s), (0.17, 0.018, 0.1), nlat=4, nlon=12)  # short peak
    elif hat == "brim":
        hb = fig.bm("Head", "hat")
        G.ellipsoid(hb, None, (0, cy + 0.17, 0.01), (0.215 * s, 0.14, 0.235 * s), nlat=8, nlon=18,
                    keep=lambda p: p[1] > cy + 0.1)
        G.ellipsoid(hb, None, (0, cy + 0.1, 0.01), (0.42 * s, 0.02, 0.42 * s), nlat=4, nlon=24)
        G.torus(fig.bm("Head", "band"), None, cy + 0.13, 0.215 * s, 0.235 * s, 0.02, None, cz=0.01, n=20, m=5)


def lock(bm, at, along, radii):
    """One sculpted hair lock: an ellipsoid whose long axis (y) runs `along`, centred `at`."""
    y = Vector(along).normalized()
    x = y.cross(Vector((0, 0, 1)))
    if x.length < 1e-3:
        x = Vector((1, 0, 0))
    x.normalize()
    z = x.cross(y)

    def place(p):
        q = Vector(at) + x * p[0] + y * p[1] + z * p[2]
        return (q.x, q.y, q.z)

    G.ellipsoid(bm, None, (0, 0, 0), radii, nlat=6, nlon=8, deform=place)


def locks(bm, cy, s, style):
    """Hair as overlapping locks over the skull (fused into one sculpted volume with grooves): rows
    of locks swept back and down from a side part, a fringe swept across the brow, fuller sides."""
    rng = random.Random(len(style) * 7 + 3)
    rx, ry, rz = 0.2 * s, 0.26 * s, 0.225 * s
    long = {"short": 0.0, "ponytail": 0.12, "bob": 0.26}[style]
    for ring in range(5):
        lat = 0.15 + ring * 0.3  # 0 = crown, rising toward the hairline
        n = 6 + ring * 3
        for k in range(n):
            lon = 2 * math.pi * (k + 0.5 * (ring % 2)) / n
            fx, fz = math.sin(lon), -math.cos(lon)  # fz < 0 at the face
            sl = math.sin(lat)
            p = Vector((rx * sl * fx * 1.04, cy + 0.02 + ry * math.cos(lat) * 1.0, 0.012 + rz * sl * fz * 1.04))
            front = fz < -0.3
            if front and ring >= 3 and abs(fx) < 0.75:
                continue  # forehead stays bare under the fringe
            if ring == 4 and not front and long == 0.0 and fz > 0.2:
                p.y -= 0.02
            flow = Vector((fx * 0.35, -1.0, fz * 0.5 + 0.35)) if not front else Vector((0.6 if fx >= 0 else 0.4, -0.45, -0.15))
            length = 0.07 + 0.02 * ring + (long * 0.5 if (not front and ring >= 3) else 0.0)
            p += flow.normalized() * length * 0.35
            lock(bm, p, flow, (0.05 + rng.uniform(-0.008, 0.008), length, 0.03))
    # Fringe swept across from a left part, and full sides over the ears.
    for k in range(5):
        t = k / 4
        lock(bm, (-0.11 * s + 0.21 * s * t, cy + 0.17 - 0.03 * math.sin(t * math.pi), -0.165 * s + 0.02 * abs(t - 0.5)),
             (1.0, -0.35, -0.1), (0.035, 0.085, 0.028))
    for side in (-1, 1):
        lock(bm, (side * 0.178 * s, cy + 0.08, 0.03), (side * 0.1, -1.0, 0.4), (0.026, 0.085 + long * 0.4, 0.065))
    if style == "bob":
        for k in range(7):
            a = math.pi * (0.15 + 0.7 * k / 6)
            lock(bm, (0.19 * s * math.cos(a) * 1.05, cy - 0.12, 0.2 * s * math.sin(a) * 0.95 + 0.02),
                 (math.cos(a) * 0.15, -1.0, 0.1), (0.045, 0.12, 0.035))
    if style == "ponytail":
        lock(bm, (0, cy + 0.06, 0.235 * s), (0, -0.2, 1.0), (0.04, 0.035, 0.04))  # tie
        for i, (y, z, rr) in enumerate(((cy - 0.02, 0.28, 0.065), (cy - 0.17, 0.3, 0.058), (cy - 0.31, 0.28, 0.045), (cy - 0.42, 0.25, 0.03))):
            lock(bm, (0, y, z * s), (0, -1.0, 0.15 - 0.1 * i), (rr, 0.1, rr * 0.85))


def clothes(fig, b, preset):
    top, over = preset["top"], preset["over"]
    shirt = "shirt"
    G.loft(fig.bm("UpperTorso", shirt), None, sections_ring(G.dense(torso_sections(b, 0.012), 0.12), n=20), cap0=True, cap1=False)
    G.torus(fig.bm("UpperTorso", shirt), None, 1.58, 0.135, 0.125, 0.025, None, cz=0.02, n=16, m=5)  # collar band
    trousers = "overall" if preset["legs"] == "overall" else "trousers"
    G.loft(fig.bm("LowerTorso", trousers), None, sections_ring(pelvis_sections(b, 0.015), n=20), cap0=True, cap1=True)
    if over != "overalls":
        G.torus(fig.bm("LowerTorso", "belt"), None, WAIST + 0.02, b["waist"] + 0.02, 0.225, 0.035, None, cz=0.01, n=22, m=5)
    for side, name in ((-1, "Left"), (1, "Right")):
        x = side * b["arm_x"]
        sleeve = "jacket" if over == "jacket" else shirt
        G.ellipsoid(fig.bm(f"{name}UpperArm", sleeve), None, (x - side * 0.07, 1.31, 0.0),
                    (b["arm"] + 0.04, b["arm"] + 0.02, b["arm"] + 0.03), nlat=8, nlon=12)
        limb(fig, f"{name}UpperArm", sleeve, x, [1.3, 1.0, ELBOW + 0.03], [b["arm"] + 0.03, b["arm"] + 0.025, b["arm"] * 0.8 + 0.03])
        if top == "rolled" and over != "jacket":
            G.torus(fig.bm(f"{name}UpperArm", sleeve), None, ELBOW + 0.06, b["arm"] * 0.8 + 0.035, b["arm"] * 0.8 + 0.035, 0.035, None, cx=x, n=14, m=5)
        else:
            G.ellipsoid(fig.bm(f"{name}LowerArm", sleeve), None, (x, ELBOW, 0.0), (b["arm"] * 0.8 + 0.025,) * 3, nlat=6, nlon=10)
            limb(fig, f"{name}LowerArm", sleeve, x, [ELBOW, 0.45, 0.02], [b["fore"] + 0.025, b["fore"] + 0.02, b["fore"] * 0.72 + 0.02])
            G.torus(fig.bm(f"{name}LowerArm", sleeve), None, 0.03, b["fore"] * 0.72 + 0.025, b["fore"] * 0.72 + 0.025, 0.025, None, cx=x, n=12, m=5)
        hx = side * b["hip_x"]
        limb(fig, f"{name}UpperLeg", trousers, hx, [-0.3, -0.7, KNEE - 0.02],
             [b["thigh"] + 0.0, b["thigh"] * 0.85 + 0.03, b["calf"] + 0.04], cap0=False)
        G.ellipsoid(fig.bm(f"{name}LowerLeg", trousers), None, (hx, KNEE, -0.005), (b["calf"] + 0.04, 0.09, b["calf"] + 0.04), nlat=6, nlon=10)
        tall = preset["boots"] == "tall"
        bottom = -1.45 if tall else -1.95
        limb(fig, f"{name}LowerLeg", trousers, hx, [KNEE, -1.42, bottom],
             [b["calf"] + 0.04, b["calf"] + 0.035, b["calf"] * (0.95 if tall else 0.78) + 0.04])
        top_y = -1.2 if tall else -1.86
        limb(fig, f"{name}LowerLeg", "boots", hx, [top_y, -1.55, ANKLE + 0.02],
             [b["calf"] + 0.045 if tall else b["calf"] * 0.75 + 0.045, b["calf"] * 0.85 + 0.04, b["calf"] * 0.62 + 0.04])
        if tall:
            G.torus(fig.bm(f"{name}LowerLeg", "boots"), None, top_y, b["calf"] + 0.05, b["calf"] + 0.05, 0.025, None, cx=hx, n=14, m=5)

        def shoe(p, hx=hx):
            return (p[0], max(p[1], FLOOR), p[2])

        G.ellipsoid(fig.bm(f"{name}Foot", "boots"), None, (hx, -2.23, -0.07), (0.105, 0.13, 0.22), nlat=8, nlon=14, deform=shoe)
        G.ellipsoid(fig.bm(f"{name}Foot", "boots"), None, (hx, -2.27, -0.23), (0.095, 0.075, 0.075), nlat=6, nlon=10, deform=shoe)  # toe cap
        G.ellipsoid(fig.bm(f"{name}Foot", "boots"), None, (hx, -2.27, 0.07), (0.09, 0.08, 0.07), nlat=6, nlon=10, deform=shoe)  # heel
        G.ellipsoid(fig.bm(f"{name}Foot", "boots"), None, (hx, FLOOR + 0.035, -0.07), (0.12, 0.035, 0.25), nlat=4, nlon=14)  # sole
        G.ellipsoid(fig.bm(f"{name}Foot", "boots"), None, (hx, ANKLE - 0.03, 0.0), (0.095, 0.09, 0.1), nlat=6, nlon=10)
    # Outer layers.
    if over == "waistcoat":
        def vest_keep(p):
            front = p[2] < -0.05
            v = abs(p[0]) < 0.04 + max(0.0, p[1] - 0.75) * 0.32
            return not (front and v) and p[1] < 1.47
        secs = torso_sections(b, 0.035)[:-1] + [(1.45, b["chest"] * 0.75 + 0.03, 0.19, 0, 0.0)]
        G.loft(fig.bm("UpperTorso", "vest"), None, sections_ring(G.dense(secs, 0.06), n=28), cap0=False, cap1=False)
        keep_faces(fig.bm("UpperTorso", "vest"), vest_keep)
    elif over == "jacket":
        def jacket_keep(p):
            front = p[2] < -0.05
            return not (front and abs(p[0]) < 0.03 + max(0.0, p[1] - 0.9) * 0.3)
        secs = torso_sections(b, 0.04)
        G.loft(fig.bm("UpperTorso", "jacket"), None, sections_ring(G.dense(secs, 0.06), n=28), cap0=False, cap1=False)
        keep_faces(fig.bm("UpperTorso", "jacket"), jacket_keep)
        G.torus(fig.bm("UpperTorso", "jacket"), None, 1.5, b["chest"] * 0.62 + 0.04, 0.2, 0.035, None, cz=0.01, n=20, m=5)
        skirt = [(WAIST + 0.08, b["waist"] + 0.05, 0.25, 0, 0.01), (-0.2, b["hips"] + 0.06, 0.27, 0, 0.0),
                 (-0.55, b["hips"] + 0.09, 0.29, 0, 0.0)]
        G.loft(fig.bm("LowerTorso", "jacket"), None, sections_ring(G.dense(skirt, 0.06), n=28), cap0=False, cap1=False)
        keep_faces(fig.bm("LowerTorso", "jacket"), lambda p: not (p[2] < -0.05 and abs(p[0]) < 0.06))
    elif over == "braces":
        for side in (-1, 1):
            strap(fig.bm("UpperTorso", "braces"), b, side * 0.12, 0.03)
    elif over == "overalls":
        bib = [(WAIST, b["waist"] + 0.035, 0.235, 0, 0.01), (0.5, b["waist"] + 0.055, 0.24, 0, 0.0),
               (1.0, b["chest"] + 0.02, 0.265, 0, -0.015)]
        G.loft(fig.bm("UpperTorso", "overall"), None, sections_ring(G.dense(bib, 0.06), n=28), cap0=False, cap1=False)
        keep_faces(fig.bm("UpperTorso", "overall"), lambda p: p[1] < 0.42 or (p[2] < -0.05 and abs(p[0]) < 0.24))
        for side in (-1, 1):
            strap(fig.bm("UpperTorso", "overall"), b, side * 0.16, 0.04, front_y=0.98)
        G.ellipsoid(fig.bm("UpperTorso", "overall"), None, (0, 0.78, -0.262), (0.1, 0.08, 0.008), nlat=4, nlon=8)  # bib pocket


def strap(bm, b, x, w, front_y=0.2):
    """Shoulder strap: up the front, over the shoulder, down the back (flat tube, no loop)."""
    pts = [(x, front_y, -0.255), (x * 1.05, 0.9, -0.27), (x * 1.15, 1.3, -0.22), (x * 1.2, 1.5, 0.0),
           (x * 1.15, 1.3, 0.22), (x * 1.05, 0.7, 0.245), (x, 0.15, 0.235)]
    rings = []
    for i, p in enumerate(pts):
        a = Vector(pts[max(i - 1, 0)])
        c = Vector(pts[min(i + 1, len(pts) - 1)])
        t = (c - a).normalized()
        out = Vector((0, 0, -1 if p[2] < 0 else 1)) if abs(p[2]) > 0.1 else Vector((0, 1, 0))
        side = t.cross(out).normalized() * w
        n = out * 0.012
        q = Vector(p)
        rings.append([tuple(q + side + n), tuple(q - side + n), tuple(q - side - n), tuple(q + side - n)])
    G.loft(bm, None, rings)


def keep_faces(bm, keep):
    gone = [f for f in bm.faces if not keep(G.rv(f.calc_center_median()))]
    bmesh.ops.delete(bm, geom=gone, context="FACES")
    # Open garment edges get a thin double face so the shell never shows its inside as a hole.
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")


def anchor(fig):
    bm = fig.bm("Anchor", "anchor")
    e = 0.04
    vs = [bm.verts.new(G.bv(p)) for p in ((e, 0, 0), (-e, 0, 0), (0, e, 0), (0, -e, 0), (0, 0, e), (0, 0, -e))]
    for a in (0, 1):
        for b_ in (2, 3):
            for c in (4, 5):
                G.face(bm, (vs[a], vs[b_], vs[c]), Vector((0, 0, 0)), None, None)


def build(name):
    preset = PRESETS[name]
    b = BODY[preset["body"]]
    fig = Fig()
    body(fig, b, preset)
    head(fig, b, preset)
    clothes(fig, b, preset)
    anchor(fig)
    objs = []
    mats = {}
    for key, bm in sorted(fig.pieces.items()):
        part, slot = key.split("__")
        # Hidden under clothing: the bare limb pieces are only kept where skin shows.
        if slot in ("upperarm", "thigh"):
            bm.free()
            continue
        if slot == "forearm":
            covered = preset["top"] != "rolled" or preset["over"] == "jacket"
            if covered:
                bm.free()
                continue
            slot = "skin"
        if slot == "shin":
            bm.free()
            continue
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        if slot == preset["skin"]:
            slot = "skin"
        nm = f"{part}__{slot}__{name}"
        if nm in [o.name for o in objs]:
            other = bpy.data.objects[nm]
            tmp = C.mesh_object(nm + "_tmp", bm)
            C.join([other, tmp], nm)
            continue
        obj = C.mesh_object(nm, bm)
        for poly in obj.data.polygons:
            poly.use_smooth = True
        if slot not in mats:
            mats[slot] = P.material_for(slot, name, PALETTES[name], LOOKS[name], b["head"])
        obj.data.materials.append(mats[slot])
        objs.append(obj)
    return objs


RIGID = ("hat", "band")  # worn hats stay rigid pieces on the Head (ToolVisuals hides them under gear)
BODY_TRIS = 9000


def is_face(p):
    return p[1] > 1.72 and p[2] < -0.02 and abs(p[0]) < 0.2


def skinned(name, objs, out, others):
    """Body lane: fuses the painted rest-pose pieces into one skinned shell, bakes their paint into
    the preset's one 1024 atlas (face islands enlarged) and binds it to a 15-bone R15 armature.
    Returns (export objects, atlas path, body, armature)."""
    b = BODY[PRESETS[name]["body"]]
    pieces = [o for o in objs if not o.name.startswith("Anchor")]
    fused = [o for o in pieces if o.name.split("__")[1] not in RIGID]
    rigid = [o for o in pieces if o.name.split("__")[1] in RIGID]
    body = S.fuse(fused, f"UpperTorso__body__{name}", 0.017, BODY_TRIS, b["arm_x"], b["hip_x"])
    rig = S.bones(b["arm_x"], b["hip_x"])
    groups = S.skin(body, rig, b["arm_x"], b["hip_x"])
    lows = [body]
    for o in rigid:
        c = o.copy()
        c.data = o.data.copy()
        C.link(c)
        lows.append(c)
    S.atlas_uvs(lows, 2.6, is_face)
    P.LOCAL_AO = True
    atlas = S.bake_onto([(low, pieces if low is body else [o]) for low, o in zip(lows, [None] + rigid)],
                        f"{PACKAGE}_{name}", out, size=1024, hide=others)
    P.LOCAL_AO = False
    keep = [o for o in objs if o.name.startswith("Anchor")]
    for o in pieces:
        bpy.data.objects.remove(o, do_unlink=True)
    # Earlier presets' materials stay with their own meshes; the shared node materials of this
    # preset's pieces are no longer needed.
    for c in lows[1:]:
        c.name = c.name.rsplit(".", 1)[0]
        c.data.name = c.name
    arm = S.armature(f"Rig__rig__{name}", rig, body, groups, name)
    return keep + lows, atlas, body, arm


def main():
    root = os.path.abspath(sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "build/l6")
    only = sys.argv[sys.argv.index("--") + 2:] if "--" in sys.argv else []
    out = os.path.join(root, "out")
    os.makedirs(out, exist_ok=True)
    rows = {}
    C.reset(SEED)
    everything = []
    for i, name in enumerate(PRESETS):
        if only and name not in only:
            continue
        objs = build(name)
        others = [o for o in everything if o.type in ("MESH", "ARMATURE", "EMPTY")]
        objs, atlas, body, arm = skinned(name, objs, out, others)
        # No empty row: with armatures under "survivor.<preset>" empties the exported FBX lost the
        # skin of two of the four bodies (Blender re-import, body lane); without empties all four
        # keep it. The armature "Rig__rig__<preset>" is the preset's row; every piece hangs under it.
        for o in objs:
            if o is not body:
                o.parent = arm
        tris = {o.name: C.triangles(o) for o in objs}
        rows[name] = {"row": arm.name, "body": PRESETS[name]["body"], "triangles": sum(tris.values()),
                      "pieces": sorted(tris), "atlas": os.path.basename(atlas),
                      "bones": sorted(bn.name for bn in arm.data.bones), "skinned": body.name,
                      "vertices": len(body.data.vertices)}
        print("built", name, rows[name]["triangles"], "tris", len(objs), "pieces", len(arm.data.bones), "bones")
        visible = [o for o in objs if not o.name.startswith("Anchor")]
        for other in bpy.context.scene.objects:
            other.hide_render = other not in visible
        C.silhouette(name, out, visible)
        C.preview(name, out, visible)
        everything += [arm] + objs
    for o in everything:
        o.hide_render = False
    bpy.ops.object.select_all(action="DESELECT")
    for o in everything:
        o.select_set(True)
    bpy.context.view_layer.objects.active = everything[1]
    path = os.path.join(out, f"{PACKAGE}.fbx")
    bpy.ops.export_scene.fbx(
        filepath=path,
        use_selection=True,
        object_types={"MESH", "ARMATURE"},
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_ALL",
        path_mode="COPY",
        embed_textures=True,
        add_leaf_bones=False,
        bake_anim=False,
        mesh_smooth_type="FACE",
    )
    print("exported", path, os.path.getsize(path))
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out, f"{PACKAGE}.blend"))
    with open(os.path.join(out, "rows.json"), "w") as f:
        json.dump(rows, f, indent=1, sort_keys=True)
    print("done")


main()
