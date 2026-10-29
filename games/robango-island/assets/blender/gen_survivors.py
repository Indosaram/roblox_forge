"""L6 survivor avatars: four adult survivors in period work clothes on two body types.

Headless only:
  blender -b --factory-startup --python games/robango-island/assets/blender/gen_survivors.py -- build/l6
Outputs build/l6/out/RobangoSurvivors.fbx (one package; one empty "survivor.<preset>" per preset), silhouettes, previews
and build/l6/out/rows.json (pieces and triangles per preset).

R15 fit (SurvivorAvatar.luau, kind "rig"): every mesh piece belongs to ONE R15 body part and is
named "<R15Part>__<slot>__<preset>" (unique across the package). The geometry is authored in rig space around the blank R15 body
(characterR15.rbxm, scale 1: HumanoidRootPart centre at the origin, joints below), so the runtime
welds each piece to its body part at the offset it has here. The piece "Anchor" is a tiny
octahedron centred on the rig origin: the runtime measures every piece against it, which makes
the fit independent of where the importer puts the model. Pieces carry no texture: the runtime
colours them per slot (MeshPart.Color + Material), so no SurfaceAppearance is ever needed.
Shapes are our own and code-authored; nothing was traced from the reference game. No weapons,
insignia, badges or uniform cuts; no cords or loops at the neck. Seed 6060.
"""

import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
from mathutils import Vector

import common as C
import survivor_geo as G

SEED = 6060
PACKAGE = "RobangoSurvivors"

# R15 rest joints relative to the HumanoidRootPart (measured from characterR15.rbxm, scale 1).
WAIST, NECK, SHOULDER, ELBOW, WRIST = 0.05, 1.65, 1.413, 0.685, -0.075
HIP, KNEE, ANKLE, FLOOR = -0.35, -1.172, -2.098, -2.35

# Preview colours only; the shipped colours live in SurvivorAvatar.luau PRESETS[*].palette.
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
          "arm": 0.12, "fore": 0.09, "thigh": 0.19, "calf": 0.13, "head": 1.0},
    "B": {"arm_x": 0.5, "hip_x": 0.2, "g": 0.9, "chest": 0.39, "waist": 0.29, "hips": 0.38,
          "arm": 0.1, "fore": 0.078, "thigh": 0.19, "calf": 0.12, "head": 0.95},
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
        G.ellipsoid(hand, None, (x, -0.2, 0.0), (b["fore"] * 0.62, 0.15, b["fore"] * 1.05), nlat=8, nlon=10)
        G.ellipsoid(hand, None, (x - side * 0.035, -0.17, -0.06), (0.03, 0.07, 0.03), nlat=5, nlon=8)
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
            x *= 1 - 0.32 * t ** 1.5
            z = z * (1 - 0.18 * t) - 0.03 * t  # chin forward
        return (x, y, z)

    h = fig.bm("Head", skin)
    G.ellipsoid(h, None, (0, cy, 0.0), (0.19 * s, 0.26 * s, 0.22 * s), nlat=12, nlon=18, deform=skull)
    G.ellipsoid(h, None, (0, cy - 0.02, -0.215 * s), (0.032, 0.065, 0.045), nlat=6, nlon=8)  # nose
    for side in (-1, 1):
        G.ellipsoid(h, None, (side * 0.19 * s, cy, 0.02), (0.028, 0.06, 0.045), nlat=5, nlon=8)  # ear
        G.ellipsoid(fig.bm("Head", "eye"), None, (side * 0.07 * s, cy + 0.045, -0.188 * s), (0.026, 0.017, 0.012), nlat=4, nlon=8)
        G.ellipsoid(fig.bm("Head", "brow"), None, (side * 0.072 * s, cy + 0.09, -0.195 * s), (0.045, 0.012, 0.016), nlat=4, nlon=8)
    G.ellipsoid(fig.bm("Head", "lip"), None, (0, cy - 0.12 * s, -0.19 * s), (0.05, 0.012, 0.014), nlat=4, nlon=8)
    hair = fig.bm("Head", "hair")
    style = preset["hair"]
    r = (0.205 * s, 0.25 * s, 0.235 * s)
    if style == "short":
        G.ellipsoid(hair, None, (0, cy + 0.035, 0.012), r, nlat=12, nlon=18,
                    keep=lambda p: p[1] > cy + 0.06 - (0.16 if p[2] > 0.02 else 0) - (0.08 if abs(p[0]) > 0.15 and p[2] > -0.08 else 0))
    else:
        long = style == "ponytail"
        G.ellipsoid(hair, None, (0, cy + 0.03, 0.015), (r[0] + 0.01, r[1] + 0.01, r[2]), nlat=12, nlon=18,
                    keep=lambda p: p[1] > cy + 0.07 or (p[2] > -0.06 and p[1] > cy - (0.12 if long else 0.24)))
        if long:
            for i, (y, z, rr) in enumerate(((cy + 0.0, 0.25, 0.07), (cy - 0.15, 0.27, 0.065), (cy - 0.3, 0.25, 0.05))):
                G.ellipsoid(hair, None, (0, y, z), (rr, 0.11, rr), nlat=6, nlon=10)
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
            m = bpy.data.materials.new(f"{slot}.{name}")
            m.diffuse_color = (*C.hexlin(PREVIEW.get(preset["skin"] if slot == "skin" else slot, "#808080")), 1.0)
            m.use_nodes = True
            m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = m.diffuse_color
            m.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.85
            mats[slot] = m
        obj.data.materials.append(mats[slot])
        objs.append(obj)
    return objs


def main():
    root = os.path.abspath(sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "build/l6")
    out = os.path.join(root, "out")
    os.makedirs(out, exist_ok=True)
    rows = {}
    C.reset(SEED)
    everything = []
    for i, name in enumerate(PRESETS):
        objs = build(name)
        empty = bpy.data.objects.new(f"survivor.{name}", None)
        bpy.context.scene.collection.objects.link(empty)
        for o in objs:
            o.parent = empty
        tris = {o.name: C.triangles(o) for o in objs}
        rows[name] = {"row": empty.name, "body": PRESETS[name]["body"], "triangles": sum(tris.values()),
                      "pieces": sorted(tris)}
        print("built", name, rows[name]["triangles"], "tris", len(objs), "pieces")
        visible = [o for o in objs if not o.name.startswith("Anchor")]
        for other in bpy.context.scene.objects:
            other.hide_render = other not in visible
        C.silhouette(name, out, visible)
        C.preview(name, out, visible)
        everything += [empty] + objs
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
        object_types={"MESH", "EMPTY"},
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_ALL",
        path_mode="AUTO",
        embed_textures=False,
        bake_anim=False,
        mesh_smooth_type="FACE",
    )
    print("exported", path, os.path.getsize(path))
    with open(os.path.join(out, "rows.json"), "w") as f:
        json.dump(rows, f, indent=1, sort_keys=True)
    print("done")


main()
