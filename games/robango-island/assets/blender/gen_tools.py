"""L7 hand tools, weapons and worn gear (asset-audit row 8; refs R05-1, R08-1).

Headless only:
  blender -b --factory-startup --python games/robango-island/assets/blender/gen_tools.py -- build/l7 [Package...]
Outputs build/l7/out/RobangoTools.fbx (one package, manifest key mesh-tools), build/l7/out/rows.json (per-row triangles and bounds in
Roblox axes) and per-row silhouette/preview PNGs for the moderation screen.

Rows: axe, pick, knife, club, hammer, hoe, spear, bow in three material tiers (t1 knapped stone,
t2 bone/antler, t3 copper), plus torch, sling, bola and the back basket.

Each row is an FBX empty named by its key (`tool.<family>.t<n>` or `tool.<family>`) holding up to
four meshes, one per material role, so the runtime colours them with plain MeshPart Color and
Material (src/shared/ToolVisuals.luau). There are NO textures and NO materials in the FBX: Open
Cloud FBX imports leave a SurfaceAppearance TexturePack empty and phone clients then fail it.
  <key>         wood: haft, shaft, bow limbs, basket wicker
  <key>__head   working part: knapped stone, bone or copper (tier look)
  <key>__bind   lashing bands, cords, grip wraps (bands hug the haft: no free rope loops)
  <key>__ember  torch ember (runtime Neon)
Frame: Blender Z up = Roblox +Y, Blender +Y = Roblox -Z (forward). The grip point (where the right
hand holds) is the origin, the haft runs along +Z, and a working edge faces +Y (forward).
Moderation: every blade is a short, broad, visibly primitive tool head lashed to a haft; cords are
straight or end in a weight or pouch; nothing forms a closed rope loop. Seed 4371.
"""

import json
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
from mathutils import Matrix, Vector

import common as C

SEED = 4371
ROLES = ("", "__head", "__bind", "__ember")
# Preview colours only (object colour in Workbench); the runtime palette lives in ToolVisuals.luau.
PREVIEW = {
    "": (0.42, 0.29, 0.17, 1),
    "__bind": (0.55, 0.47, 0.32, 1),
    "__ember": (1.0, 0.45, 0.1, 1),
    1: (0.42, 0.44, 0.45, 1),
    2: (0.86, 0.82, 0.70, 1),
    3: (0.72, 0.42, 0.22, 1),
}


# ------------------------------------------------------------------ geometry helpers


def frame(origin=(0, 0, 0), x=(1, 0, 0), y=(0, 1, 0)):
    """Matrix from an origin and two axes (z = x cross y)."""
    xv = Vector(x).normalized()
    yv = Vector(y).normalized()
    zv = xv.cross(yv).normalized()
    yv = zv.cross(xv).normalized()
    m = Matrix.Identity(4)
    for i in range(3):
        m[i][0], m[i][1], m[i][2], m[i][3] = xv[i], yv[i], zv[i], origin[i]
    return m


def jitter(amount):
    return Vector((random.uniform(-amount, amount), random.uniform(-amount, amount), random.uniform(-amount, amount)))


def tube(bm, pts, radii, sides=8, cap=True, wobble=0.0):
    """Closed tube along a polyline (haft, shaft, cord, band)."""
    pts = [Vector(p) for p in pts]
    rings = []
    n = len(pts)
    for i, p in enumerate(pts):
        t = (pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]).normalized()
        ref = Vector((0, 0, 1)) if abs(t.z) < 0.9 else Vector((1, 0, 0))
        a = t.cross(ref).normalized()
        b = t.cross(a).normalized()
        r = radii[i] if isinstance(radii, (list, tuple)) else radii
        ring = []
        for k in range(sides):
            ang = 2 * math.pi * k / sides
            rr = r * (1 + random.uniform(-wobble, wobble))
            ring.append(bm.verts.new(p + (a * math.cos(ang) + b * math.sin(ang)) * rr))
        rings.append(ring)
    for i in range(n - 1):
        for k in range(sides):
            k2 = (k + 1) % sides
            bm.faces.new((rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]))
    if cap:
        bm.faces.new(list(reversed(rings[0])))
        bm.faces.new(rings[-1])
    return rings


def band(bm, z0, z1, r, sides=8, axis_frame=None):
    """Short lashing band hugging a haft along local Z (a wrap, not a loop)."""
    m = axis_frame or Matrix.Identity(4)
    tube(bm, [m @ Vector((0, 0, z0)), m @ Vector((0, 0, (z0 + z1) / 2)), m @ Vector((0, 0, z1))], [r * 0.97, r, r * 0.97], sides)


def lens(bm, outline, thick, m, ridge=0.45, knap=0.0):
    """Lens-section blade from a 2D outline in the local XY plane (edges thin, centre thick).
    knap > 0 jitters the ridge for a knapped-flint facet look (flat shaded)."""
    edge = [bm.verts.new(m @ Vector((x, y, 0))) for x, y in outline]
    cx = sum(x for x, _ in outline) / len(outline)
    cy = sum(y for _, y in outline) / len(outline)
    tops, bots = [], []
    for x, y in outline:
        ix, iy = cx + (x - cx) * ridge, cy + (y - cy) * ridge
        dz = thick / 2 * (1 + random.uniform(-knap, knap))
        tops.append(bm.verts.new(m @ Vector((ix + random.uniform(-knap, knap) * 0.05, iy, dz))))
        bots.append(bm.verts.new(m @ Vector((ix, iy + random.uniform(-knap, knap) * 0.05, -dz))))
    n = len(outline)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((edge[i], edge[j], tops[j], tops[i]))
        bm.faces.new((edge[j], edge[i], bots[i], bots[j]))
    bm.faces.new(tops)
    bm.faces.new(list(reversed(bots)))


def lathe(bm, profile, sides, m):
    """Surface of revolution around local Z from (radius, z) pairs; closed at both ends."""
    rings = []
    for r, z in profile:
        rings.append([bm.verts.new(m @ Vector((r * math.cos(2 * math.pi * k / sides), r * math.sin(2 * math.pi * k / sides), z))) for k in range(sides)])
    for i in range(len(rings) - 1):
        for k in range(sides):
            k2 = (k + 1) % sides
            bm.faces.new((rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]))
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[-1])


def stone(bm, center, radius, squash=(1, 1, 1), rough=0.12, subdiv=1):
    """Rounded pebble (icosphere with seeded jitter)."""
    ret = bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=radius)
    for v in ret["verts"]:
        v.co = Vector((v.co.x * squash[0], v.co.y * squash[1], v.co.z * squash[2])) * (1 + random.uniform(-rough, rough)) + Vector(center)


def haft(bm, z0, z1, r0, r1, bend=0.0, sides=8, steps=6):
    """Slightly bent wooden haft along +Z with a knot wobble."""
    pts, radii = [], []
    for i in range(steps + 1):
        t = i / steps
        z = z0 + (z1 - z0) * t
        pts.append((bend * math.sin(math.pi * t) + random.uniform(-0.01, 0.01), random.uniform(-0.01, 0.01), z))
        radii.append(r0 + (r1 - r0) * t)
    tube(bm, pts, radii, sides, wobble=0.05)


# ------------------------------------------------------------------ rows


class Row:
    def __init__(self, key, tier=None):
        self.key = key
        self.tier = tier
        self.bms = {role: bmesh.new() for role in ROLES}
        self.flat = {"__head"}

    def __getitem__(self, role):
        return self.bms[role]


def head_outline(kind, tier):
    """Blade outlines in the local plane (x along the edge direction, y across)."""
    if kind == "axe":
        if tier == 1:  # knapped tear-drop flint, blunt butt into the haft
            return [(0.0, -0.18), (0.35, -0.3), (0.72, -0.24), (0.82, 0.0), (0.72, 0.24), (0.35, 0.3), (0.0, 0.18)]
        if tier == 2:  # crescent bone blade
            return [(0.0, -0.14), (0.4, -0.22), (0.7, -0.34), (0.78, -0.12), (0.8, 0.12), (0.7, 0.34), (0.4, 0.22), (0.0, 0.14)]
        return [(0.0, -0.12), (0.45, -0.18), (0.72, -0.36), (0.8, 0.0), (0.72, 0.36), (0.45, 0.18), (0.0, 0.12)]
    if kind == "knife":
        if tier == 1:  # broad leaf flake, rounded tip
            return [(-0.12, 0.0), (-0.1, 0.42), (0.0, 0.8), (0.1, 0.42), (0.12, 0.0)]
        if tier == 2:
            return [(-0.1, 0.0), (-0.11, 0.45), (-0.04, 0.78), (0.06, 0.62), (0.1, 0.0)]
        return [(-0.11, 0.0), (-0.13, 0.4), (-0.06, 0.74), (0.0, 0.8), (0.06, 0.74), (0.13, 0.4), (0.11, 0.0)]
    if kind == "spear":
        if tier == 1:
            return [(-0.1, 0.0), (-0.14, 0.3), (0.0, 0.85), (0.14, 0.3), (0.1, 0.0)]
        if tier == 2:
            return [(-0.08, 0.0), (-0.1, 0.35), (0.0, 0.8), (0.1, 0.35), (0.08, 0.0)]
        return [(-0.08, 0.0), (-0.16, 0.25), (-0.1, 0.55), (0.0, 0.9), (0.1, 0.55), (0.16, 0.25), (0.08, 0.0)]
    if kind == "hoe":
        return [(-0.28, 0.0), (-0.3, 0.45), (-0.2, 0.6), (0.2, 0.6), (0.3, 0.45), (0.28, 0.0)]
    raise ValueError(kind)


def build_axe(row, t):
    haft(row[""], -0.6, 2.0, 0.1, 0.085, bend=0.05)
    top = 1.75
    m = frame((0, 0.05, top), x=(0, 1, 0), y=(0, 0, 1))
    lens(row["__head"], head_outline("axe", t), 0.2 if t == 1 else 0.14 if t == 2 else 0.08, m, knap=0.35 if t == 1 else 0.0)
    if t == 3:  # cast socket ring around the haft
        tube(row["__head"], [(0, 0, top - 0.25), (0, 0, top + 0.25)], 0.13, 8)
    band(row["__bind"], top - 0.38, top - 0.2, 0.11)
    band(row["__bind"], top + 0.2, top + 0.36, 0.105)
    band(row["__bind"], -0.25, 0.25, 0.115)  # grip wrap


def build_pick(row, t):
    haft(row[""], -0.6, 2.0, 0.1, 0.085, bend=0.04)
    top = 1.8
    if t == 2:  # antler tine pick: curved, tapering
        pts = [(0, -0.15, top + 0.02), (0, 0.15, top + 0.05), (0, 0.45, top - 0.02), (0, 0.7, top - 0.16), (0, 0.85, top - 0.36)]
        tube(row["__head"], pts, [0.11, 0.1, 0.08, 0.055, 0.025], 7)
        tube(row["__head"], [(0, -0.12, top), (0, -0.32, top - 0.06)], [0.1, 0.07], 7)
    else:  # knapped stone or cast copper point, both ways, wide blunt rear
        r = 0.12 if t == 1 else 0.09
        pts = [(0, -0.42, top - 0.05), (0, -0.15, top), (0, 0.2, top), (0, 0.55, top - 0.06), (0, 0.85, top - 0.2)]
        tube(row["__head"], pts, [r * 0.6, r, r, r * 0.65, 0.03], 6 if t == 1 else 8, wobble=0.12 if t == 1 else 0.0)
    band(row["__bind"], top - 0.3, top - 0.13, 0.11)
    band(row["__bind"], top + 0.12, top + 0.24, 0.1)
    band(row["__bind"], -0.25, 0.25, 0.115)


def build_knife(row, t):
    # Short grip below the origin, broad blade above: an everyday cutting tool.
    tube(row[""], [(0, 0, -0.35), (0, 0, 0.0), (0, 0, 0.28)], [0.085, 0.09, 0.085], 8, wobble=0.04)
    m = frame((0, 0, 0.24), x=(1, 0, 0), y=(0, 0, 1))
    lens(row["__head"], head_outline("knife", t), 0.09 if t == 1 else 0.07 if t == 2 else 0.05, m, knap=0.4 if t == 1 else 0.0)
    band(row["__bind"], 0.12, 0.3, 0.1)
    if t == 3:
        tube(row["__head"], [(0, 0, -0.4), (0, 0, -0.33)], 0.1, 8)  # copper pommel cap


def build_club(row, t):
    pts = [(0, 0, -0.55), (0, 0, 0.3), (0.02, 0, 1.0), (0.03, 0, 1.5), (0.02, 0, 1.85), (0, 0, 2.0)]
    tube(row[""], pts, [0.1, 0.1, 0.15, 0.22, 0.24, 0.15], 9, wobble=0.12)
    band(row["__bind"], -0.25, 0.25, 0.12)
    if t == 1:  # wood only: two knots on the head
        stone(row[""], (0.18, 0.05, 1.55), 0.09, rough=0.2, subdiv=1)
        stone(row[""], (-0.14, -0.1, 1.75), 0.08, rough=0.2, subdiv=1)
    elif t == 2:  # rounded bone studs set in the head
        for k in range(6):
            ang = 2 * math.pi * k / 6
            z = 1.45 + 0.22 * (k % 2)
            stone(row["__head"], (0.24 * math.cos(ang), 0.24 * math.sin(ang), z), 0.06, squash=(1, 1, 1.3), rough=0.05, subdiv=1)
    else:  # two copper bands
        tube(row["__head"], [(0.02, 0, 1.35), (0.02, 0, 1.47)], 0.235, 10)
        tube(row["__head"], [(0.02, 0, 1.7), (0.02, 0, 1.82)], 0.25, 10)


def build_hammer(row, t):
    haft(row[""], -0.55, 1.75, 0.1, 0.09, bend=0.03)
    top = 1.6
    m = frame((0, 0.1, top), x=(1, 0, 0), y=(0, 0, -1))  # lathe axis along +Y (forward/back)
    if t == 1:  # river cobble lashed across the haft
        stone(row["__head"], (0, 0.1, top), 0.26, squash=(0.85, 1.35, 0.85), rough=0.1, subdiv=2)
    elif t == 2:  # antler mallet: a thick tine section
        tube(row["__head"], [(0, -0.3, top), (0, 0.0, top + 0.02), (0, 0.35, top)], [0.15, 0.19, 0.16], 8, wobble=0.06)
    else:  # copper-capped block
        lathe(row["__head"], [(0.0, -0.36), (0.17, -0.36), (0.2, -0.28), (0.2, 0.28), (0.17, 0.36), (0.0, 0.36)], 8, m)
    band(row["__bind"], top - 0.3, top - 0.14, 0.11)
    band(row["__bind"], -0.25, 0.25, 0.115)


def build_hoe(row, t):
    haft(row[""], -0.6, 2.4, 0.095, 0.085, bend=0.05)
    top = 2.25
    # Blade hangs down-forward from the top, flat face toward the ground.
    m = frame((0, 0.08, top + 0.05), x=(1, 0, 0), y=(0, 0.55, -0.85))
    lens(row["__head"], head_outline("hoe", t), 0.1 if t == 1 else 0.07, m, ridge=0.6, knap=0.3 if t == 1 else 0.0)
    band(row["__bind"], top - 0.22, top - 0.05, 0.105)
    band(row["__bind"], -0.25, 0.25, 0.11)


def build_spear(row, t):
    haft(row[""], -2.4, 3.2, 0.085, 0.07, bend=0.06, steps=8)
    top = 3.12
    m = frame((0, 0, top), x=(1, 0, 0), y=(0, 0, 1))
    lens(row["__head"], head_outline("spear", t), 0.12 if t == 1 else 0.09 if t == 2 else 0.06, m, knap=0.35 if t == 1 else 0.0)
    if t == 3:
        tube(row["__head"], [(0, 0, top - 0.25), (0, 0, top + 0.05)], [0.095, 0.08], 8)
    else:
        band(row["__bind"], top - 0.25, top + 0.02, 0.09)
    band(row["__bind"], -0.3, 0.3, 0.1)


def build_bow(row, t):
    # Limbs bend back (-Y) toward the tips; the string is one straight cord tip to tip.
    half = 2.0
    pts, radii = [], []
    for i in range(13):
        s = -1 + 2 * i / 12
        z = s * half
        y = -0.45 * (s * s)
        pts.append((0, y, z))
        radii.append(0.085 * (1 - 0.55 * abs(s)) + 0.02)
    tube(row[""], pts, radii, 7)
    tip = pts[-1]
    tube(row["__bind"], [(0, tip[1] - 0.01, -tip[2] + 0.05), (0, tip[1] - 0.01, tip[2] - 0.05)], 0.012, 4)
    band(row["__bind"], -0.25, 0.25, 0.1)  # grip wrap
    if t >= 2:  # bone (t2) or copper (t3) tip caps
        for sgn in (-1, 1):
            z = sgn * (half - 0.08)
            tube(row["__head"], [(0, -0.45 + 0.02, z - 0.12 * sgn), (0, -0.45 + 0.02, z + 0.06 * sgn)], [0.045, 0.035], 6)
    if t == 3:
        band(row["__head"], 0.27, 0.36, 0.1)
        band(row["__head"], -0.36, -0.27, 0.1)


def build_sling(row):
    # A short wooden toggle in the hand, one twisted cord hanging to a leather pouch with a pebble.
    tube(row[""], [(-0.18, 0, 0), (0.18, 0, 0)], 0.05, 6)
    tube(row["__bind"], [(0, 0, -0.03), (0.02, 0.01, -0.5), (0.04, 0.02, -1.0)], 0.025, 5)
    lathe(row["__bind"], [(0.0, -1.32), (0.12, -1.27), (0.16, -1.15), (0.14, -1.04), (0.06, -1.0), (0.0, -0.99)], 8, Matrix.Translation((0.04, 0.02, 0)))
    stone(row["__head"], (0.04, 0.02, -1.1), 0.1, rough=0.1, subdiv=1)


def build_bola(row):
    # Held at the knot: three straight cords fan out, each ending in a weight.
    knot = Vector((0, 0, 0))
    stone(row["__bind"], knot, 0.07, rough=0.1, subdiv=1)
    for k, (dx, dy) in enumerate(((0.25, 0.05), (-0.18, 0.18), (-0.05, -0.24))):
        end = Vector((dx, dy, -1.05 - 0.08 * k))
        tube(row["__bind"], [knot, (knot + end) / 2, end], 0.022, 5, cap=False)
        stone(row["__head"], end + Vector((0, 0, -0.1)), 0.13, rough=0.12, subdiv=1)


def build_torch(row):
    haft(row[""], -0.6, 1.5, 0.085, 0.1, bend=0.03)
    lathe(row["__head"], [(0.0, 1.25), (0.13, 1.28), (0.17, 1.5), (0.15, 1.75), (0.07, 1.85), (0.0, 1.86)], 9, Matrix.Identity(4))
    band(row["__bind"], 1.3, 1.4, 0.16)
    band(row["__bind"], 1.58, 1.67, 0.165)
    lathe(row["__ember"], [(0.0, 1.78), (0.1, 1.8), (0.06, 2.05), (0.0, 2.25)], 7, Matrix.Identity(4))


def build_basket(row):
    # Back basket, origin at the wearer's upper back: tapered wicker body, rim, lid strap bands.
    # No shoulder straps (they would read as loops); the runtime welds it to the torso.
    m = Matrix.Translation((0, 0, -0.95))
    lathe(row[""], [(0.0, 0.0), (0.38, 0.0), (0.46, 0.25), (0.55, 1.0), (0.6, 1.55), (0.0, 1.55)], 12, m)
    for k in range(12):  # vertical stakes standing proud of the weave
        ang = 2 * math.pi * (k + 0.5) / 12
        a = Vector((math.cos(ang), math.sin(ang), 0))
        tube(row["__bind"], [a * 0.39 + Vector((0, 0, -0.95)), a * 0.52 + Vector((0, 0, -0.1)), a * 0.62 + Vector((0, 0, 0.62))], 0.025, 4)
    for z, r in ((-0.6, 0.48), (-0.2, 0.53), (0.2, 0.57), (0.58, 0.62)):
        tube(row["__bind"], [(0, 0, z - 0.03), (0, 0, z + 0.03)], r, 12)


WORK = [("axe", build_axe), ("pick", build_pick), ("knife", build_knife), ("club", build_club), ("hammer", build_hammer), ("hoe", build_hoe)]
HUNT = [("spear", build_spear), ("bow", build_bow)]
BUDGET = 700


def rows_for():
    out = []
    for family, fn in WORK:
        for t in (1, 2, 3):
            out.append(("RobangoTools", f"tool.{family}.t{t}", t, fn))
    out.append(("RobangoTools", "tool.torch", None, lambda r, _t: build_torch(r)))
    out.append(("RobangoTools", "tool.basket", None, lambda r, _t: build_basket(r)))
    for family, fn in HUNT:
        for t in (1, 2, 3):
            out.append(("RobangoTools", f"tool.{family}.t{t}", t, fn))
    out.append(("RobangoTools", "tool.sling", None, lambda r, _t: build_sling(r)))
    out.append(("RobangoTools", "tool.bola", None, lambda r, _t: build_bola(r)))
    return out


def to_object(name, bm, flat):
    bm.normal_update()
    # Recalculate outward normals: Roblox draws single-sided meshes.
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    uv = bm.loops.layers.uv.new("UVMap")
    for f in bm.faces:  # simple box projection so Roblox materials tile on the part
        n = f.normal
        ax = max(range(3), key=lambda i: abs(n[i]))
        for loop in f.loops:
            c = loop.vert.co
            u, v = [(c.y, c.z), (c.x, c.z), (c.x, c.y)][ax]
            loop[uv].uv = (u * 0.5, v * 0.5)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = not flat
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def roblox_box(lo, hi):
    return {"min": [round(lo.x, 3), round(lo.z, 3), round(-hi.y, 3)], "max": [round(hi.x, 3), round(hi.z, 3), round(-lo.y, 3)]}


def bounds(objs):
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in objs:
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    return lo, hi


def preview(name, outdir, objs):
    """Object-colour Workbench preview (the FBX carries no textures)."""
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "OBJECT"
    scene.display.shading.background_type = "VIEWPORT"
    scene.display.shading.background_color = (0.55, 0.52, 0.45)
    scene.render.resolution_x = scene.render.resolution_y = 384
    lo, hi = bounds(objs)
    center, extent = (lo + hi) / 2, max(hi - lo)
    cam_data = bpy.data.cameras.new("pv")
    cam = bpy.data.objects.new("pv", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    scene.camera = cam
    d = Vector((1.0, -0.8, 0.35)).normalized()
    cam.location = center + d * extent * 2.0
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    cam_data.clip_end = extent * 10
    scene.render.filepath = os.path.join(outdir, f"{name}_preview.png")
    bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(cam)


def main():
    root = os.path.abspath(sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "build/l7")
    only = set(sys.argv[sys.argv.index("--") + 2 :]) if "--" in sys.argv else set()
    out = os.path.join(root, "out")
    os.makedirs(out, exist_ok=True)
    C.reset(SEED)
    packages, rows = {}, {}
    for package, key, tier, fn in rows_for():
        random.seed(f"{SEED}:{key}")
        row = Row(key, tier)
        fn(row, tier)
        objs = []
        for role in ROLES:
            bm = row[role]
            if not bm.faces:
                bm.free()
                continue
            o = to_object(key + role, bm, role in ("__head", "__ember") and tier != 3)
            o.color = PREVIEW[tier] if role == "__head" and tier else PREVIEW.get(role, PREVIEW[1])
            objs.append(o)
        tris = sum(C.triangles(o) for o in objs)
        lo, hi = bounds(objs)
        rows[key] = {
            "package": package,
            "tier": tier,
            "tris": tris,
            "budget": BUDGET,
            "fits": tris <= BUDGET,
            "bounds": roblox_box(lo, hi),
            "meshes": [o.name for o in objs],
        }
        print(f"{key:20s} {package:18s} tris={tris:5d}/{BUDGET} {'ok' if tris <= BUDGET else 'OVER'}")
        packages.setdefault(package, []).append((key, objs))
    with open(os.path.join(out, "rows.json"), "w") as f:
        json.dump(rows, f, indent=1, sort_keys=True)
    for package, entries in packages.items():
        if only and package not in only:
            continue
        everything = []
        for key, objs in entries:
            empty = bpy.data.objects.new(key, None)
            bpy.context.scene.collection.objects.link(empty)
            for o in objs:
                o.parent = empty
            everything += [empty] + objs
        bpy.ops.object.select_all(action="DESELECT")
        for o in everything:
            o.select_set(True)
        bpy.context.view_layer.objects.active = everything[1]
        path = os.path.join(out, f"{package}.fbx")
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
    # Moderation screen and report: per-row silhouettes and object-colour previews.
    bpy.context.scene.display.shading.color_type = "OBJECT"
    for package, entries in packages.items():
        for key, objs in entries:
            for other in bpy.context.scene.objects:
                other.hide_render = True
            for o in objs:
                o.hide_render = False
            C.silhouette(key, out, objs, views=("front", "side"))
            preview(key, out, objs)
    print("done")


main()
