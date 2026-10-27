"""B3 buildings, stations, town kit and opening set pieces (asset-catalog sections 6-7).

Headless only:
  python games/robango-island/assets/blender/build_building_atlas.py build/b3
  blender -b --factory-startup --python games/robango-island/assets/blender/gen_buildings.py -- build/b3
Outputs build/b3/out/<Package>.fbx (one per catalog package), silhouette and preview sheets,
and build/b3/out/rows.json (per-row triangles and designed bounds, Roblox axes).

Every row is one mesh named by its catalog key. Extra meshes on a row use a suffix:
  <key>__cut   roof/wall pieces that fade indoors (G24, ForgeCutaway)
  <key>__ember fire anchor (Fire + PointLight at load)
  <key>__glow  emissive rift fissure / lantern glass
  <key>__tag   cloth recoloured at runtime (plot tag, clan banner)
All rows share ONE 1024 atlas (albedo + normal + roughness): log, plank, thatch, canvas, rope,
stone, brick, clay, slate, tile, metal, hide, char, solids, teal cloth, sea-glass.
Shapes are our own: no reference-game models were traced. Seed 4310.
"""

import json
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
from mathutils import Euler, Matrix, Vector

import common as C

SEED = 4310
GRID = 4
TILES = ["log", "plank", "thatch", "canvas", "rope", "stone", "brick", "clay",
         "slate", "tile", "metal", "hide", "char", "solid", "teal", "seaglass"]
# Solid colours live in quarter cells of the "solid" tile.
SOLIDS = {"ember": (0, 0), "leaf": (1, 0), "flower": (0, 1), "glow": (1, 1)}
# Studs covered by one tile before the texture stretches.
SPAN = {"log": 5, "plank": 6, "thatch": 6, "canvas": 7, "rope": 2, "stone": 6, "brick": 5,
        "clay": 6, "slate": 6, "tile": 6, "metal": 3, "hide": 4, "char": 5, "teal": 4, "seaglass": 5}
MARGIN = 0.02


def tile_rect(tile):
    if tile in SOLIDS:
        i = TILES.index("solid")
        row, col = divmod(i, GRID)
        sx, sy = SOLIDS[tile]
        u0 = (col + sx * 0.5 + 0.2) / GRID
        v0 = 1 - (row + sy * 0.5 + 0.3) / GRID
        return u0, v0, 0.1 / GRID, 0.0
    i = TILES.index(tile)
    row, col = divmod(i, GRID)
    return col / GRID, 1 - (row + 1) / GRID, 1 / GRID, 1 / GRID


class MB:
    """Face soup with per-face planar UVs into one atlas tile."""

    def __init__(self):
        self.faces = []  # (points, tile)

    def face(self, pts, tile, center=None):
        """center: a point inside the closed primitive; the face is wound to point away from it,
        because Roblox culls back faces (single-sided meshes)."""
        pts = [Vector(p) for p in pts]
        if center is not None and len(pts) >= 3:
            n = Vector((0, 0, 0))
            for i in range(len(pts)):
                a, b = pts[i], pts[(i + 1) % len(pts)]
                n += Vector(((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)))
            mid = sum(pts, Vector((0, 0, 0))) / len(pts)
            if n.dot(mid - Vector(center)) < 0:
                pts = list(reversed(pts))
        self.faces.append((pts, tile))

    def tris(self):
        return sum(len(p) - 2 for p, _ in self.faces)

    def build(self, name):
        bm = bmesh.new()
        uv = bm.loops.layers.uv.new("UVMap")
        for pts, tile in self.faces:
            vs = [bm.verts.new(p) for p in pts]
            try:
                f = bm.faces.new(vs)
            except ValueError:
                continue
            u0, v0, du, dv = tile_rect(tile)
            if dv == 0.0:
                for loop in f.loops:
                    loop[uv].uv = (u0 + random.random() * du, v0 - random.random() * du * 0.5)
                continue
            n = f.normal if f.normal.length > 1e-6 else Vector((0, 0, 1))
            t1 = (pts[1] - pts[0])
            if t1.length < 1e-6:
                t1 = Vector((1, 0, 0))
            t1.normalize()
            t2 = n.cross(t1).normalized()
            co = [((p - pts[0]).dot(t1), (p - pts[0]).dot(t2)) for p in pts]
            mx, my = min(c[0] for c in co), min(c[1] for c in co)
            ex = max(c[0] for c in co) - mx
            ey = max(c[1] for c in co) - my
            span = SPAN.get(tile, 6)
            s = 1.0 / max(span, ex, ey, 1e-3)
            ox = random.random() * max(0.0, 1 - ex * s)
            oy = random.random() * max(0.0, 1 - ey * s)
            for loop, c in zip(f.loops, co):
                a = ox + (c[0] - mx) * s
                b = oy + (c[1] - my) * s
                loop[uv].uv = (u0 + (MARGIN + a * (1 - 2 * MARGIN)) * du, v0 + (MARGIN + b * (1 - 2 * MARGIN)) * dv)
        bm.normal_update()
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
        obj = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(obj)
        return obj


def rot(r):
    return Euler([math.radians(a) for a in r], "XYZ").to_matrix()


def box(mb, c, s, tile, r=(0, 0, 0), top=None):
    """Box centred at c, size s, rotation r (deg). top=tile for the +Z face (e.g. thatch edge)."""
    m = rot(r)
    c = Vector(c)
    hx, hy, hz = s[0] / 2, s[1] / 2, s[2] / 2
    P = [c + m @ Vector((x, y, z)) for x in (-hx, hx) for y in (-hy, hy) for z in (-hz, hz)]
    # index = xi*4 + yi*2 + zi
    faces = [((0, 2, 3, 1), tile), ((4, 5, 7, 6), tile), ((0, 1, 5, 4), tile),
             ((2, 6, 7, 3), tile), ((0, 4, 6, 2), tile), ((1, 3, 7, 5), top or tile)]
    for idx, t in faces:
        mb.face([P[i] for i in idx], t, center=c)


def ring(a, axis, r, n, phase=0.0, jitter=0.0):
    axis = axis.normalized()
    ref = Vector((0, 0, 1)) if abs(axis.z) < 0.9 else Vector((1, 0, 0))
    u = axis.cross(ref).normalized()
    v = axis.cross(u).normalized()
    out = []
    for i in range(n):
        t = phase + i * 2 * math.pi / n
        rr = r * (1 + (random.uniform(-jitter, jitter) if jitter else 0))
        out.append(a + (u * math.cos(t) + v * math.sin(t)) * rr)
    return out


def cyl(mb, a, b, r0, r1, tile, n=7, cap=True, cap_tile=None, jitter=0.0):
    a, b = Vector(a), Vector(b)
    axis = b - a
    if axis.length < 1e-6:
        return
    A = ring(a, axis, r0, n, jitter=jitter)
    B = ring(b, axis, max(r1, 0.001), n, jitter=jitter) if r1 > 0.001 else None
    mid = (a + b) / 2
    for i in range(n):
        j = (i + 1) % n
        if B is None:
            mb.face([A[i], A[j], b], tile, center=a + (b - a) * 0.25)
        else:
            mb.face([A[i], A[j], B[j], B[i]], tile, center=mid)
    if cap:
        mb.face(list(reversed(A)), cap_tile or tile, center=mid)
        if B is not None:
            mb.face(B, cap_tile or tile, center=mid)


def log(mb, a, b, r, n=7, tile="log", cap="plank"):
    cyl(mb, a, b, r, r * 0.92, tile, n=n, cap=True, cap_tile=cap, jitter=0.06)


def lathe(mb, c, prof, tile, n=10, close_top=True, close_bottom=False, jitter=0.0):
    """prof: [(radius, z)] bottom to top around vertical axis at c."""
    c = Vector(c)
    rings = []
    for r, z in prof:
        rings.append(ring(c + Vector((0, 0, z)), Vector((0, 0, 1)), max(r, 0.001), n, jitter=jitter))
    for k in range(len(rings) - 1):
        R0, R1 = rings[k], rings[k + 1]
        z = (prof[k][1] + prof[k + 1][1]) / 2
        for i in range(n):
            j = (i + 1) % n
            mb.face([R0[i], R0[j], R1[j], R1[i]], tile, center=c + Vector((0, 0, z)))
    if close_top:
        mb.face(rings[-1], tile, center=c + Vector((0, 0, prof[-1][1] - 1)))
    if close_bottom:
        mb.face(list(reversed(rings[0])), tile, center=c + Vector((0, 0, prof[0][1] + 1)))


def sheet(mb, p00, p10, p01, nu, nv, tile, sag=0.0, both=True, noise=0.0):
    """Subdivided cloth/hide sheet spanning p00->p10 (u) and p00->p01 (v); sags along -Z."""
    p00, p10, p01 = Vector(p00), Vector(p10), Vector(p01)
    du, dv = p10 - p00, p01 - p00
    G = []
    for j in range(nv + 1):
        row = []
        for i in range(nu + 1):
            u, v = i / nu, j / nv
            p = p00 + du * u + dv * v
            p.z -= sag * math.sin(math.pi * u) * math.sin(math.pi * v)
            if noise:
                p.z += random.uniform(-noise, noise)
            row.append(p)
        G.append(row)
    for j in range(nv):
        for i in range(nu):
            q = [G[j][i], G[j][i + 1], G[j + 1][i + 1], G[j + 1][i]]
            mb.face(q, tile)
            if both:
                mb.face(list(reversed(q)), tile)


def rock(mb, c, s, tile="stone", n=6):
    """Lumpy stone: a jittered 3-ring lathe."""
    c = Vector(c)
    lathe(mb, c + Vector((0, 0, -s * 0.15)), [(s * 0.55, 0), (s * 0.62, s * 0.35), (s * 0.35, s * 0.75)], tile,
          n=n, jitter=0.18)


def gable(mb, cut, cx, cy, w, d, eave, ridge, tile, layers=3, thick=0.35, over=0.6):
    """Layered gable roof over x in [cx-w/2, cx+w/2], ridge along Y, into `cut`."""
    half = w / 2 + over
    rise = ridge - eave
    ang = math.degrees(math.atan2(rise, half))
    slope = math.hypot(half, rise)
    for side in (-1, 1):
        for k in range(layers):
            frac = (k + 0.5) / layers
            seg = slope / layers * 1.25
            x = cx + side * half * (1 - frac)
            z = eave + rise * frac + thick * 0.5
            box(cut, (x, cy, z), (seg, d + over * 2 - k * 0.15, thick), tile, r=(0, side * ang, 0))
    log(cut, (cx, cy - d / 2 - over, ridge + 0.25), (cx, cy + d / 2 + over, ridge + 0.25), 0.3)


def lash(mb, a, b, r):
    """Rope lashing band at point a on a pole along a->b."""
    a, b = Vector(a), Vector(b)
    d = (b - a).normalized() * 0.18
    cyl(mb, a - d, a + d, r * 1.12, r * 1.12, "rope", n=7)


# ----------------------------------------------------------------------------- rows
# Each builder gets (m, cut, extra) MBs: m = main mesh, cut = cut-away, extra = dict of suffix -> MB.
# Blender axes: X right, Y = depth (Roblox -Z front is Blender +Y), Z up. Pivot ground centre.


def stone_ring(m, r, n, s, tile="stone"):
    for i in range(n):
        a = i * 2 * math.pi / n + random.uniform(-0.1, 0.1)
        rock(m, (math.cos(a) * r, math.sin(a) * r, 0), s * random.uniform(0.85, 1.15), tile)


def campfire(m, cut, ex):
    stone_ring(m, 2.4, 9, 1.1, "stone")
    for i in range(9):  # soot inside the ring
        a = i * 2 * math.pi / 9
        rock(m, (math.cos(a) * 1.2, math.sin(a) * 1.2, -0.25), 0.7, "char")
    for i in range(3):
        a = i * 2 * math.pi / 3 + 0.4
        log(m, (math.cos(a) * 1.6, math.sin(a) * 1.6, 0.25), (math.cos(a) * 0.2, math.sin(a) * 0.2, 0.9), 0.32,
            tile="char" if i == 0 else "log")
    top = (0, 0, 5.6)
    for i in range(3):  # cooking tripod
        a = i * 2 * math.pi / 3 + 1.0
        foot = (math.cos(a) * 2.9, math.sin(a) * 2.9, 0)
        log(m, foot, top, 0.14, n=5)
    lash(m, (0, 0, 5.2), top, 0.2)
    cyl(m, (0, 0, 5.1), (0, 0, 2.6), 0.04, 0.04, "rope", n=4, cap=False)
    lathe(m, (0, 0, 1.8), [(0.2, 0), (0.75, 0.25), (0.7, 0.8), (0.5, 0.85)], "metal", n=10, close_bottom=True)
    lathe(ex["ember"], (0, 0, 0.1), [(1.0, 0), (0.6, 0.3), (0.1, 0.45)], "ember", n=8)


def bench_legs(m, w, d, h, r=0.3, tile="log"):
    for x in (-w / 2, w / 2):
        for y in (-d / 2, d / 2):
            log(m, (x, y, 0), (x * 0.95, y * 0.95, h), r, tile=tile)
            lash(m, (x * 0.95, y * 0.95, h - 0.4), (x, y, h), r)


def workbench_t1(m, cut, ex):
    w, d, h = 6.4, 3.0, 3.0
    bench_legs(m, w, d, h)
    for i in range(4):  # split-log top
        y = -d / 2 + 0.4 + i * (d - 0.8) / 3
        log(m, (-w / 2 - 0.3, y, h + 0.3), (w / 2 + 0.3, y, h + 0.3), 0.38)
    log(m, (-w / 2, 0, 0.9), (w / 2, 0, 0.9), 0.2)  # stretcher
    box(m, (2.0, 0.2, h + 0.95), (1.4, 1.0, 0.9), "stone")  # stone vise
    box(m, (2.0, 0.2, h + 1.5), (0.5, 0.5, 0.3), "stone")
    log(m, (-w / 2, d / 2 + 0.2, h + 0.4), (-w / 2, d / 2 + 0.2, h + 3.3), 0.15)  # tool post
    log(m, (w / 2, d / 2 + 0.2, h + 0.4), (w / 2, d / 2 + 0.2, h + 3.3), 0.15)
    log(m, (-w / 2, d / 2 + 0.2, h + 3.1), (w / 2, d / 2 + 0.2, h + 3.1), 0.12)
    for i, x in enumerate((-1.8, -0.6, 0.6)):  # hanging mallet, hatchet, saw
        cyl(m, (x, d / 2 + 0.2, h + 3.0), (x, d / 2 + 0.2, h + 1.6), 0.07, 0.07, "log", n=5)
        box(m, (x, d / 2 + 0.2, h + 1.6), (0.6 if i else 0.5, 0.25, 0.35), "metal" if i else "log")
    rock(m, (-2.2, -0.2, h + 0.55), 0.7, "stone")


def workbench_t2(m, cut, ex):
    w, d, h = 7.0, 3.2, 3.1
    for x in (-w / 2 + 0.3, w / 2 - 0.3):
        for y in (-d / 2 + 0.3, d / 2 - 0.3):
            box(m, (x, y, h / 2), (0.45, 0.45, h), "plank")
    box(m, (0, 0, h + 0.15), (w + 0.4, d + 0.3, 0.3), "plank")
    box(m, (1.4, -d / 2 + 0.05, h - 0.55), (2.6, 0.3, 0.7), "plank")  # drawer front
    box(m, (1.4, -d / 2 - 0.15, h - 0.55), (0.6, 0.1, 0.12), "metal")
    box(m, (0, 0, 0.8), (w - 0.6, d - 0.6, 0.2), "plank")  # shelf
    for i in range(3):
        box(m, (-2 + i * 0.3, 0, 1.1 + i * 0.22), (3.0, 0.7, 0.2), "plank")
    # sawhorse beside
    for x in (-1.0, 1.0):
        for s in (-1, 1):
            log(m, (5.0 + x, s * 0.7, 0), (5.0 + x, 0, 2.0), 0.14, n=5)
    log(m, (3.8, 0, 2.1), (6.2, 0, 2.1), 0.22)
    box(m, (-2.3, 0.3, h + 0.5), (1.6, 0.9, 0.5), "plank")
    box(m, (-2.3, 0.3, h + 0.85), (0.9, 0.12, 0.25), "metal")


def workbench_t3(m, cut, ex):
    workbench_t2(m, cut, ex)
    for x in (-3.8, 3.8):  # framed awning
        box(m, (x, 2.0, 3.5), (0.5, 0.5, 7.0), "plank")
        box(m, (x, -2.0, 2.8), (0.5, 0.5, 5.6), "plank")
    box(m, (0, 2.0, 7.0), (8.2, 0.5, 0.5), "plank")
    box(m, (0, -2.0, 5.6), (8.2, 0.5, 0.5), "plank")
    sheet(cut, (-4.3, -2.6, 5.7), (4.3, -2.6, 5.7), (-4.3, 2.5, 7.25), 6, 3, "canvas", sag=0.3)
    for x in (-3.8, 3.8):
        box(m, (x, 2.0, 1.2), (0.7, 0.7, 0.25), "metal")
    box(m, (0, 2.2, 4.2), (6.5, 0.2, 2.2), "plank")  # tool wall
    for i in range(5):
        box(m, (-2.6 + i * 1.3, 2.0, 4.4), (0.18, 0.2, 1.4), "metal")


def kiln_t1(m, cut, ex):
    lathe(m, (0, 0, 0), [(2.9, 0), (3.0, 1.0), (2.7, 2.4), (2.0, 3.6), (1.0, 4.4), (0.6, 4.7)], "clay", n=14,
          jitter=0.03)
    lathe(m, (0, 0, 4.6), [(0.65, 0), (0.55, 0.6)], "clay", n=8, close_top=False)
    for i in range(7):  # stone footing
        a = i * 2 * math.pi / 7
        rock(m, (math.cos(a) * 2.9, math.sin(a) * 2.9, 0), 1.0, "stone")
    box(m, (0, -2.75, 0.9), (1.8, 0.8, 1.8), "char")  # fire mouth
    lathe(ex["ember"], (0, -2.8, 0.1), [(0.7, 0), (0.3, 0.6)], "ember", n=6)
    for i, (x, y) in enumerate(((2.6, -2.4), (3.2, -1.6), (-2.9, -2.0))):  # pots
        lathe(m, (x, y, 0), [(0.25, 0), (0.45, 0.4), (0.4, 0.9), (0.3, 1.05)], "clay", n=8, close_bottom=True)


def kiln_t2(m, cut, ex):
    w, d, h = 5.6, 5.6, 4.2
    for z in range(6):
        off = 0.3 if z % 2 else 0
        box(m, (0, 0, 0.35 + z * 0.7), (w - off, d - off, 0.7), "brick")
    box(m, (0, -d / 2 - 0.05, 1.0), (2.0, 0.4, 1.8), "char")
    box(m, (0, 0, h + 0.2), (w + 0.3, d + 0.3, 0.4), "stone")
    box(m, (1.4, 1.2, h + 2.4), (1.4, 1.4, 4.4), "brick")  # chimney
    box(m, (1.4, 1.2, h + 4.7), (1.7, 1.7, 0.3), "stone")
    lathe(ex["ember"], (0, -2.9, 0.15), [(0.7, 0), (0.3, 0.6)], "ember", n=6)
    for x in (-2.2, 2.4):
        box(m, (x, -3.6, 0.4), (1.0, 0.8, 0.8), "plank")


def kiln_t3(m, cut, ex):
    for cx in (-2.0, 2.0):
        lathe(m, (cx, 0.2, 0), [(2.1, 0), (2.1, 1.5), (1.6, 3.0), (0.6, 4.0)], "brick", n=12)
        box(m, (cx, -1.9, 0.8), (1.2, 0.5, 1.4), "char")
        lathe(ex["ember"], (cx, -2.0, 0.1), [(0.5, 0), (0.2, 0.5)], "ember", n=6)
    box(m, (0, 0.2, 1.6), (1.8, 2.6, 3.2), "brick")
    box(m, (0, 1.6, 4.6), (1.2, 1.2, 5.2), "brick")
    # bellows: two boards and a leather bag
    box(m, (-4.6, -1.5, 0.9), (2.2, 1.4, 0.15), "plank", r=(0, 0, 0))
    box(m, (-4.6, -1.5, 1.6), (2.2, 1.4, 0.15), "plank", r=(0, -8, 0))
    lathe(m, (-4.6, -1.5, 0.95), [(0.8, 0), (0.95, 0.3), (0.7, 0.6)], "hide", n=8)
    cyl(m, (-3.5, -1.5, 1.2), (-2.6, -1.0, 1.0), 0.15, 0.12, "metal", n=6)


def mud_kiln(m, cut, ex):
    lathe(m, (0, 0, 0), [(2.8, 0), (2.7, 0.8), (2.2, 2.0), (1.0, 2.8), (0.5, 3.0)], "clay", n=12, jitter=0.07)
    for i in range(14):  # reed bundles around
        a = i * 2 * math.pi / 14
        cyl(m, (math.cos(a) * 2.6, math.sin(a) * 2.6, 0), (math.cos(a) * 2.0, math.sin(a) * 2.0, 2.4), 0.2, 0.12,
            "thatch", n=5)
    box(m, (0, -2.5, 0.6), (1.4, 0.7, 1.2), "char")
    lathe(ex["ember"], (0, -2.5, 0.05), [(0.55, 0), (0.25, 0.5)], "ember", n=6)


def tanning_frame(m, cut, ex):
    w, h = 6.0, 6.4
    log(m, (-w / 2, 0, 0), (-w / 2 + 0.2, 0, h), 0.25)
    log(m, (w / 2, 0, 0), (w / 2 - 0.2, 0, h), 0.25)
    log(m, (-w / 2 - 0.4, 0, h - 0.3), (w / 2 + 0.4, 0, h - 0.3), 0.2)
    log(m, (-w / 2 - 0.2, 0, 1.0), (w / 2 + 0.2, 0, 1.0), 0.18)
    for x in (-w / 2, w / 2):  # braces
        log(m, (x, -1.6, 0), (x, 0, 3.0), 0.14, n=5)
        lash(m, (x, 0, h - 0.4), (x, 0, h), 0.25)
    pts = []  # stretched hide, laced to the frame
    sheet(m, (-2.1, 0.0, 1.5), (2.1, 0.0, 1.5), (-2.3, 0.0, 5.6), 5, 5, "hide", sag=0.0, noise=0.05)
    for i in range(5):
        z = 1.6 + i * 1.0
        cyl(m, (-2.2, 0, z), (-2.95, 0, z + 0.1), 0.04, 0.04, "rope", n=4, cap=False)
        cyl(m, (2.2, 0, z), (2.95, 0, z + 0.1), 0.04, 0.04, "rope", n=4, cap=False)
    box(m, (2.0, -1.6, 0.5), (1.2, 0.8, 1.0), "plank")  # scraper stand
    box(m, (2.0, -1.6, 1.1), (0.9, 0.15, 0.2), "stone")


def joiner_bench(m, cut, ex):
    w, d, h = 10.4, 3.0, 3.0
    for x in (-4.6, -1.5, 1.5, 4.6):
        for y in (-1.1, 1.1):
            box(m, (x, y, h / 2), (0.5, 0.5, h), "plank")
    box(m, (0, 0, h + 0.2), (w + 0.6, d + 0.3, 0.4), "plank")
    for i in range(4):  # plank pile
        box(m, (-1.5, 2.7, 0.2 + i * 0.32), (8.0, 1.6, 0.3), "plank", r=(0, 0, random.uniform(-2, 2)))
    box(m, (3.2, 0, h + 0.75), (0.4, 1.8, 0.8), "metal")  # clamp
    box(m, (3.2, 0, h + 1.2), (1.4, 0.3, 0.2), "metal")
    box(m, (-3.0, 0.2, h + 0.55), (2.2, 0.5, 0.3), "plank")


def mason_bench(m, cut, ex):
    box(m, (-1.5, 0, 1.4), (5.4, 3.4, 2.8), "stone")
    box(m, (-1.5, 0, 3.0), (3.6, 2.4, 0.5), "stone")
    rock(m, (3.4, 0.6, 0), 1.8, "stone")
    rock(m, (4.4, -1.5, 0), 1.2, "stone")
    for i in range(3):
        cyl(m, (-2.5 + i * 0.6, -0.8, 3.3), (-2.3 + i * 0.6, 0.6, 3.3), 0.08, 0.06, "metal", n=5)
    for x in (2.6, 5.4):  # dust tarp on two poles
        log(m, (x, 1.8, 0), (x, 1.8, 5.0), 0.15, n=5)
    sheet(m, (2.4, 1.8, 5.0), (5.6, 1.8, 5.0), (2.4, -1.4, 3.6), 4, 4, "canvas", sag=0.35)
    for i in range(5):
        rock(m, (random.uniform(-4, 5), random.uniform(-2.8, -1.8), 0), 0.45, "stone")


def refrigerator(m, cut, ex):
    stone_ring(m, 2.5, 12, 0.9)
    box(m, (0, 0, 0.35), (3.4, 3.4, 0.5), "plank")
    for i in range(5):
        box(m, (0, -1.4 + i * 0.7, 0.66), (3.2, 0.55, 0.12), "plank")
    box(m, (0, 0, 0.8), (0.3, 3.2, 0.15), "metal")
    cyl(m, (0.9, 0, 0.8), (0.9, 0, 1.2), 0.12, 0.12, "rope", n=5)
    for i in range(6):  # frost crust
        a = i * 1.05
        rock(m, (math.cos(a) * 1.9, math.sin(a) * 1.9, 0.5), 0.35, "seaglass")


def tent(m, cut, ex):
    w, d, h = 6.4, 6.8, 5.4
    log(m, (0, -d / 2 - 0.4, 0), (0, -d / 2 - 0.4, h + 0.4), 0.16, n=5)
    log(m, (0, d / 2 + 0.4, 0), (0, d / 2 + 0.4, h + 0.4), 0.16, n=5)
    log(m, (0, -d / 2 - 0.6, h), (0, d / 2 + 0.6, h), 0.14, n=5)
    for s in (-1, 1):  # canvas flanks, cut-away
        sheet(cut, (0, -d / 2, h), (0, d / 2, h), (s * w / 2, -d / 2, 0.15), 4, 4, "canvas", sag=0.25, noise=0.03)
    sheet(cut, (-w / 2, d / 2, 0.15), (w / 2, d / 2, 0.15), (0, d / 2, h), 4, 3, "canvas", sag=0.0)
    for s in (-1, 1):  # open front flaps tied back
        sheet(m, (0, -d / 2, h), (s * 1.8, -d / 2 - 0.9, 0.3), (s * 0.4, -d / 2, h), 2, 2, "canvas", sag=0.0)
    for x in (-1, 1):  # guy ropes and pegs
        for y in (-1, 1):
            peg = (x * (w / 2 + 1.6), y * (d / 2 - 0.8), 0)
            cyl(m, (x * w * 0.3, y * (d / 2 - 0.8), h * 0.42), peg, 0.035, 0.035, "rope", n=4, cap=False)
            box(m, (peg[0], peg[1], 0.25), (0.15, 0.15, 0.6), "log")
    box(m, (0, 0.8, 0.12), (2.6, 4.2, 0.25), "hide")  # bedroll inside


def bed(m, cut, ex):
    w, d = 3.8, 6.6
    for x in (-w / 2, w / 2):
        log(m, (x, -d / 2, 0.55), (x, d / 2, 0.55), 0.35)
    for y in (-d / 2, d / 2):
        log(m, (-w / 2 - 0.3, y, 0.55), (w / 2 + 0.3, y, 0.55), 0.3)
    box(m, (0, 0, 0.9), (w - 0.3, d - 0.4, 0.6), "thatch")
    sheet(m, (-w / 2, -0.4, 1.25), (w / 2, -0.4, 1.25), (-w / 2, d / 2 - 0.3, 1.25), 4, 4, "canvas", sag=-0.1, noise=0.05)
    lathe(m, (0, -2.5, 1.15), [(0.9, 0), (0.95, 0.2), (0.7, 0.45)], "canvas", n=8)
    log(m, (-w / 2, d / 2, 0), (-w / 2, d / 2, 2.2), 0.25)
    log(m, (w / 2, d / 2, 0), (w / 2, d / 2, 2.2), 0.25)
    log(m, (-w / 2, d / 2, 2.0), (w / 2, d / 2, 2.0), 0.2)


def well(m, cut, ex):
    lathe(m, (0, 0, 0), [(2.6, 0), (2.7, 0.3), (2.5, 2.6), (2.7, 2.9)], "stone", n=14, jitter=0.03)
    lathe(m, (0, 0, 2.6), [(1.9, 0), (1.9, -2.0)], "char", n=12, close_top=False)
    lathe(m, (0, 0, 0.9), [(1.85, 0)], "slate", n=10)  # dark water disc
    for x in (-2.6, 2.6):
        box(m, (x, 0, 4.4), (0.45, 0.45, 3.2), "plank")
    log(m, (-3.0, 0, 5.4), (3.0, 0, 5.4), 0.3)
    cyl(m, (0.3, 0, 5.1), (0.3, 0, 3.6), 0.04, 0.04, "rope", n=4, cap=False)
    lathe(m, (0.3, 0, 2.95), [(0.3, 0), (0.42, 0.65)], "plank", n=8, close_bottom=True)
    box(m, (3.4, 0, 5.4), (0.2, 0.2, 1.4), "plank")
    box(m, (3.4, 0.5, 4.8), (0.2, 1.2, 0.2), "plank")
    for s in (-1, 1):  # small shingle hood
        box(m, (s * 0.9, 0, 6.6), (2.4, 2.4, 0.18), "plank", r=(0, s * 30, 0))


def signal_relay(m, cut, ex):
    top = (0, 0, 10.5)
    for i in range(3):
        a = i * 2 * math.pi / 3 + 0.3
        log(m, (math.cos(a) * 3.2, math.sin(a) * 3.2, 0), top, 0.2, n=5)
    for z in (3.5, 6.8):  # braces
        r = 3.2 * (1 - z / 10.5)
        pts = [(math.cos(i * 2 * math.pi / 3 + 0.3) * r, math.sin(i * 2 * math.pi / 3 + 0.3) * r, z) for i in range(3)]
        for i in range(3):
            log(m, pts[i], pts[(i + 1) % 3], 0.1, n=4)
    lash(m, (0, 0, 10.0), top, 0.3)
    box(m, (0, 0, 10.9), (2.6, 2.6, 0.25), "plank")
    for i in range(4):  # mirror array
        a = i * math.pi / 2
        c = (math.cos(a) * 0.9, math.sin(a) * 0.9, 11.6)
        box(m, c, (0.9, 0.1, 0.9), "metal", r=(25, 0, math.degrees(a) + 90))
        box(ex["glow"], (c[0] * 1.06, c[1] * 1.06, c[2]), (0.7, 0.05, 0.7), "glow", r=(25, 0, math.degrees(a) + 90))
    cyl(m, (0, 0, 11.0), (0, 0, 12.6), 0.3, 0.25, "metal", n=8)
    lathe(ex["glow"], (0, 0, 12.6), [(0.45, 0), (0.45, 0.35), (0.2, 0.55)], "glow", n=8)



def laboratory(m, cut, ex):
    w, d, h = 7.0, 7.0, 6.2
    for x in (-w / 2, w / 2):
        for y in (-d / 2, d / 2):
            log(m, (x, y, 0), (x, y, 4.0), 0.18, n=5)
    log(m, (0, -d / 2 - 0.3, 0), (0, -d / 2 - 0.3, h), 0.18, n=5)
    log(m, (0, d / 2 + 0.3, 0), (0, d / 2 + 0.3, h), 0.18, n=5)
    log(m, (0, -d / 2 - 0.5, h), (0, d / 2 + 0.5, h), 0.15, n=5)
    for s in (-1, 1):
        sheet(cut, (0, -d / 2, h), (0, d / 2, h), (s * (w / 2 + 0.3), -d / 2, 4.0), 4, 4, "canvas", sag=0.2)
        sheet(cut, (s * (w / 2), -d / 2, 4.0), (s * (w / 2), d / 2, 4.0), (s * (w / 2), -d / 2, 0.1), 4, 2,
              "canvas", sag=0.0)
    sheet(cut, (-w / 2, d / 2, 0.1), (w / 2, d / 2, 0.1), (-w / 2, d / 2, 4.0), 3, 2, "canvas")
    box(m, (0, 1.2, 2.4), (4.4, 1.8, 0.2), "plank")  # specimen table
    for x in (-2.0, 2.0):
        box(m, (x, 1.2, 1.15), (0.25, 1.5, 2.3), "plank")
    for i in range(6):
        lathe(ex["glow"], (-1.6 + i * 0.65, 1.0 + (i % 2) * 0.5, 2.5), [(0.18, 0), (0.22, 0.4), (0.12, 0.6)], "seaglass",
              n=6, close_bottom=True)
    box(m, (2.6, -1.8, 0.6), (1.2, 1.2, 1.2), "plank")
    box(m, (2.6, -1.8, 1.5), (1.0, 1.0, 0.6), "plank")


def clan_hall(m, cut, ex):
    w, d, eave, ridge = 24.0, 16.0, 7.0, 14.0
    for x in (-w / 2, -w / 6, w / 6, w / 2):  # carved posts
        for y in (-d / 2, d / 2):
            log(m, (x, y, 0), (x, y, eave + 0.4), 0.55, n=8)
            lathe(m, (x, y, eave - 1.6), [(0.7, 0), (0.75, 0.4), (0.6, 0.8)], "char", n=8)
    log(m, (0, -d / 2 - 1, ridge - 0.6), (0, d / 2 + 1, ridge - 0.6), 0.5)
    box(m, (0, 0, 0.3), (w + 1.0, d + 1.0, 0.6), "plank")  # floor deck
    for y in (-d / 2, d / 2):  # long log walls with a door gap on the front
        for k in range(6):
            z = 0.9 + k * 0.95
            if y < 0:
                for a, b in ((-w / 2, -2.2), (2.2, w / 2)):
                    log(cut, (a, y, z), (b, y, z), 0.45, n=6)
            else:
                log(cut, (-w / 2, y, z), (w / 2, y, z), 0.45, n=6)
    for x in (-w / 2, w / 2):
        for k in range(6):
            log(cut, (x, -d / 2, 0.9 + k * 0.95), (x, d / 2, 0.9 + k * 0.95), 0.45, n=6)
        for k in range(5):  # gable fill
            z = eave + 0.6 + k * 1.2
            half = (d / 2 + 1) * (1 - (z - eave) / (ridge - eave))
            if half > 0.4:
                box(cut, (x, 0, z), (0.6, half * 2, 1.1), "plank")
    # thatch roof (ridge along X here: roof slopes face +-Y)
    half = d / 2 + 1.8
    rise = ridge - eave
    ang = math.degrees(math.atan2(rise, half))
    slope = math.hypot(half, rise)
    for s in (-1, 1):
        for k in range(4):
            frac = (k + 0.5) / 4
            box(cut, (0, s * half * (1 - frac), eave + rise * frac + 0.3), (w + 3.4 - k * 0.3, slope / 4 * 1.3, 0.55),
                "thatch", r=(-s * ang, 0, 0))
    for x in (-w / 2 - 3, w / 2 + 3):  # banner poles
        log(m, (x, -d / 2 - 2, 0), (x, -d / 2 - 2, 12), 0.2, n=6)
        sheet(ex["tag"], (x + 0.2, -d / 2 - 2, 11.6), (x + 2.6, -d / 2 - 2, 11.6), (x + 0.2, -d / 2 - 2, 7.0), 2, 4,
              "teal", sag=0.0)
    for i in range(4):  # steps
        box(m, (0, -d / 2 - 1.0 - i * 0.7, 0.45 - i * 0.12), (4.6, 0.8, 0.3), "plank")


def animal_pen(m, cut, ex):
    s = 3.8
    corners = [(-s, -s), (s, -s), (s, s), (-s, s)]
    for i, (x, y) in enumerate(corners):
        log(m, (x, y, 0), (x, y, 3.6), 0.25)
        nx, ny = corners[(i + 1) % 4]
        for z in (1.2, 2.5):
            if i == 0 and z == 1.2:
                continue
            if i == 0:  # gate side
                log(m, (x, y, z), (x + 3.0, y, z + 0.1), 0.15, n=5)
                continue
            log(m, (x, y, z), (nx, ny, z + random.uniform(-0.1, 0.1)), 0.17, n=5)
    for k in range(3):  # gate leaf, slightly open
        box(m, (1.9, -s - 0.9, 0.9 + k * 0.8), (3.2, 0.15, 0.25), "plank", r=(0, 0, 18))
    box(m, (1.5, 1.8, 0.6), (3.2, 1.0, 0.5), "log")  # feed trough
    box(m, (1.5, 1.8, 0.95), (2.8, 0.7, 0.2), "thatch")
    for x in (0.0, 3.0):
        box(m, (x, 1.8, 0.25), (0.3, 1.2, 0.5), "log")


def storage(m, cut, ex):
    box(m, (0, 0, 1.0), (4.6, 3.0, 2.0), "plank")
    box(m, (0, 0, 2.25), (4.8, 3.2, 0.5), "plank")
    for x in (-1.6, 1.6):
        box(m, (x, 0, 1.25), (0.35, 3.15, 2.6), "rope")
        box(m, (x, 0, 1.25), (0.35, 3.15, 0.0001), "rope")
    box(m, (0, -1.62, 1.6), (0.6, 0.12, 0.7), "metal")
    for x in (-2.0, 2.0):
        for y in (-1.25, 1.25):
            box(m, (x, y, 0.2), (0.6, 0.6, 0.4), "log")


# ---------------------------------------------------------------- modules (8x8 / 8x4 cells)


def timber_floor(m, cut, ex):
    for i in range(7):
        box(m, (-3.43 + i * 1.143, 0, 0.45), (1.1, 8.0, 0.3), "plank", r=(0, 0, random.uniform(-0.6, 0.6)))
    for y in (-3.2, 0, 3.2):
        log(m, (-4, y, 0.15), (4, y, 0.15), 0.18, n=5)


def stone_floor(m, cut, ex):
    random.seed(SEED + 11)
    for i in range(4):
        for j in range(4):
            box(m, (-3 + i * 2, -3 + j * 2, 0.2), (1.9 + random.uniform(-0.1, 0), 1.9, 0.4 + random.uniform(0, 0.1)),
                "stone")


def brick_floor(m, cut, ex):
    for j in range(5):
        off = 0.7 if j % 2 else 0.0
        for i in range(3):
            box(m, (-2.67 + i * 2.67 + (off if i < 2 else -off), -3.2 + j * 1.6, 0.2), (2.6, 1.55, 0.4), "brick")


def log_wall(m, cut, ex, door=False):
    # 8 wide (X), 1 deep (Y), 7 tall; whole wall fades indoors
    for k in range(7):
        z = 0.5 + k * 0.95
        if door and z < 5.4:
            log(cut, (-4, 0, z), (-1.5, 0, z), 0.47, n=6)
            log(cut, (1.5, 0, z), (4, 0, z), 0.47, n=6)
        else:
            log(cut, (-4.2, 0, z), (4.2, 0, z), 0.47, n=6)
    box(m, (0, 0, 0.15), (8.0, 1.0, 0.3), "stone")  # sill
    for x in (-4, 4):
        box(m, (x, 0, 3.5), (0.6, 1.1, 7.0), "plank")
    if door:
        for x in (-1.5, 1.5):
            box(m, (x, 0, 2.8), (0.4, 1.0, 5.6), "plank")
        box(m, (0, 0, 5.6), (3.4, 1.0, 0.45), "plank")
        for i in range(4):  # plank door, ajar
            box(cut, (-0.95 + i * 0.66, -0.2 - i * 0.12, 2.7), (0.62, 0.2, 5.2), "plank", r=(0, 0, -12))
        box(cut, (0.0, -0.45, 2.0), (2.6, 0.12, 0.25), "plank", r=(0, 0, -12))


def timber_wall(m, cut, ex):
    log_wall(m, cut, ex)


def timber_door(m, cut, ex):
    log_wall(m, cut, ex, door=True)


def stone_wall(m, cut, ex, tile="stone"):
    random.seed(SEED + 21)
    for k in range(5):
        x = -4.0
        while x < 4.0:
            w = min(random.uniform(1.2, 2.2), 4.0 - x)
            box(cut, (x + w / 2, random.uniform(-0.05, 0.05), 0.65 + k * 1.3), (w - 0.06, 1.0, 1.24), tile,
                r=(0, 0, random.uniform(-2, 2)))
            x += w
    box(m, (0, 0, 0.1), (8.2, 1.1, 0.2), "stone")


def brick_wall(m, cut, ex):
    for k in range(7):
        off = 1.0 if k % 2 else 0.0
        x = -4.0
        while x < 3.99:
            w = min(2.0 - (off if x == -4.0 else 0.0), 4.0 - x)
            box(cut, (x + w / 2, 0, 0.5 + k * 0.96), (w - 0.06, 1.0, 0.92), "brick")
            x += w
    box(m, (0, 0, 6.95), (8.2, 1.2, 0.3), "plank")


def volcanic_wall(m, cut, ex):
    stone_wall(m, cut, ex, tile="char")
    for i in range(4):
        box(m, (-3 + i * 2, 0.55, 3.0 + random.uniform(-1, 1)), (0.3, 0.05, 2.5), "clay")


def roof_segment(m, cut, ex, tile, thick):
    gable(m, cut, 0, 0, 8.0, 8.0, 0.0, 4.2, tile, layers=3, thick=thick, over=0.5)


def timber_roof(m, cut, ex):
    roof_segment(m, cut, ex, "thatch", 0.5)


def stone_roof(m, cut, ex):
    roof_segment(m, cut, ex, "slate", 0.3)


def brick_roof(m, cut, ex):
    roof_segment(m, cut, ex, "tile", 0.35)


def timber_stairs(m, cut, ex):
    for i in range(10):
        box(m, (0, -3.6 + i * 0.8, 0.6 + i * 1.2), (5.0, 0.9, 0.25), "plank")
    for x in (-2.6, 2.6):
        box(m, (x, 0, 6.0), (0.35, 10.2, 0.6), "log", r=(-56, 0, 0))
    for x in (-2.6, 2.6):
        log(m, (x, -4, 0), (x, -4, 3.0), 0.2, n=5)
        log(m, (x, 4, 0), (x, 4, 12.0), 0.2, n=5)


def timber_pillar(m, cut, ex):
    box(m, (0, 0, 3.5), (1.0, 1.0, 7.0), "log")
    box(m, (0, 0, 0.2), (1.5, 1.5, 0.4), "stone")
    box(m, (0, 0, 7.1), (1.6, 1.6, 0.3), "plank")



# ---------------------------------------------------------------- town kit and set pieces


def trading_post(m, cut, ex):
    w, d, h = 20.0, 14.0, 8.0
    box(m, (0, 0, 0.4), (w + 1, d + 1, 0.8), "plank")
    for x in (-w / 2, -w / 4, 0, w / 4, w / 2):
        for y in (-d / 2, d / 2):
            log(m, (x, y, 0.8), (x, y, h), 0.45, n=8)
    for y in (-d / 2, d / 2):
        log(m, (-w / 2 - 0.5, y, h), (w / 2 + 0.5, y, h), 0.4)
    for x in (-w / 2, 0, w / 2):
        log(m, (x, -d / 2 - 0.5, h), (x, d / 2 + 0.5, h), 0.35)
    # shallow plank roof with overhang (open hall, no cut needed)
    for s in (-1, 1):
        box(m, (0, s * (d / 4 + 0.4), h + 1.4), (w + 3.0, d / 2 + 2.2, 0.35), "plank", r=(s * -12, 0, 0))
    log(m, (-w / 2 - 1.5, 0, h + 2.6), (w / 2 + 1.5, 0, h + 2.6), 0.35)
    box(m, (0, -2.0, 2.0), (12.0, 2.0, 2.4), "plank")  # counting counter
    box(m, (0, -2.0, 3.3), (12.6, 2.4, 0.25), "plank")
    for i, x in enumerate((-4.0, 3.5)):  # scale
        cyl(m, (x, -2.0, 3.4), (x, -2.0, 5.2), 0.08, 0.08, "metal", n=5)
        box(m, (x, -2.0, 5.2), (2.4, 0.12, 0.12), "metal")
        for s in (-1, 1):
            lathe(m, (x + s * 1.1, -2.0, 4.0), [(0.05, 0), (0.5, 0.2)], "metal", n=8, close_top=True)
    for k in range(3):  # back shelving with goods
        box(m, (0, d / 2 - 1.2, 1.5 + k * 1.6), (16.0, 1.6, 0.2), "plank")
        for i in range(7):
            x = -7 + i * 2.3
            if (i + k) % 3 == 0:
                lathe(m, (x, d / 2 - 1.2, 1.6 + k * 1.6), [(0.35, 0), (0.45, 0.5), (0.25, 0.9)], "clay", n=7)
            else:
                box(m, (x, d / 2 - 1.2, 2.0 + k * 1.6), (1.4, 1.0, 0.8), "rope" if i % 2 else "plank")
    for i, x in enumerate((-6.0, 0.0, 6.0)):  # hanging cloth awnings at the front
        sheet(m, (x - 2.6, -d / 2 - 0.2, h - 0.2), (x + 2.6, -d / 2 - 0.2, h - 0.2), (x - 2.6, -d / 2 - 3.2, h - 2.0), 4, 3,
              "teal" if i == 1 else "canvas", sag=0.35)
    for x, y in ((-8.5, -5.5), (8.6, -5.0), (-8.0, 4.0)):
        box(m, (x, y, 1.6), (1.6, 1.6, 1.6), "plank")
        box(m, (x + 0.3, y, 2.9), (1.2, 1.2, 1.0), "rope")


def dock(m, cut, ex):
    L, W = 48.0, 10.0
    for i in range(int(L / 1.2)):
        y = -L / 2 + 0.6 + i * 1.2
        box(m, (random.uniform(-0.1, 0.1), y, 0.0), (W, 1.12, 0.3), "plank", r=(0, random.uniform(-1, 1), 0))
    for y in range(-24, 25, 6):
        for x in (-W / 2 + 0.3, W / 2 - 0.3):
            log(m, (x, y, -9.0), (x, y, 0.9), 0.38)
    for y in (-W / 2 + 0.5, 0.5):
        log(m, (-W / 2, -L / 2, -0.4), (-W / 2, L / 2, -0.4), 0.25)
        log(m, (W / 2, -L / 2, -0.4), (W / 2, L / 2, -0.4), 0.25)
    for y in (-14, 4, 20):  # bollards + rope coils
        for x in (-W / 2 + 0.7, W / 2 - 0.7):
            lathe(m, (x, y, 0.15), [(0.5, 0), (0.45, 0.8), (0.6, 1.0), (0.55, 1.2)], "log", n=8)
        lathe(m, (W / 2 - 2.0, y + 1.6, 0.15), [(0.9, 0), (0.9, 0.35), (0.4, 0.35)], "rope", n=10)
    for y in (-20, 0, 20):  # lantern posts
        x = -W / 2 + 0.6
        log(m, (x, y, 0.1), (x, y, 7.0), 0.2, n=6)
        box(m, (x + 0.7, y, 6.8), (1.6, 0.2, 0.2), "log")
        box(m, (x + 1.3, y, 6.1), (0.6, 0.6, 0.8), "metal")
        box(ex["glow"], (x + 1.3, y, 6.1), (0.45, 0.62, 0.55), "ember")


def rift_ring(m, cut, ex):
    """Our rift: a split standing stone of sea-glass with a glowing vertical fissure and a shard halo.
    Not a ground crater."""
    for s in (-1, 1):  # two leaning slabs that almost meet at the top
        for k in range(6):
            z = 0.9 + k * 2.2
            lean = (1 - z / 14) * 2.6
            box(m, (s * (lean + 1.2 + random.uniform(-0.1, 0.1)), 0, z), (2.4 - k * 0.15, 3.0 - k * 0.2, 2.3),
                "seaglass", r=(random.uniform(-4, 4), s * -10, random.uniform(-6, 6)))
    box(m, (0, 0, 13.7), (2.6, 2.4, 1.4), "seaglass", r=(0, 0, 8))
    for i in range(9):  # broken base stones
        a = i * 2 * math.pi / 9
        rock(m, (math.cos(a) * 5.0, math.sin(a) * 3.0, 0), 1.6, "stone")
    # the fissure: a jagged vertical glowing blade between the slabs
    pts = [(0.0, 0.6)]
    for k in range(1, 12):
        pts.append((random.uniform(-0.45, 0.45), 0.6 + k * 1.1))
    for k in range(len(pts) - 1):
        (x0, z0), (x1, z1) = pts[k], pts[k + 1]
        wdt = 0.9 * math.sin(math.pi * (k + 0.5) / len(pts)) + 0.15
        for side in (0.06, -0.06):
            q = [(x0 - wdt, side, z0), (x0 + wdt, side, z0), (x1 + wdt * 0.9, side, z1), (x1 - wdt * 0.9, side, z1)]
            ex["glow"].face(q if side > 0 else list(reversed(q)), "glow")
    for i in range(10):  # shard halo (rotated at runtime)
        a = i * 2 * math.pi / 10
        c = (math.cos(a) * 6.2, math.sin(a) * 1.2, 8.0 + math.sin(a) * 4.5)
        lathe(ex["halo"], c, [(0.35, -0.7), (0.4, 0), (0.0, 0.9)], "seaglass", n=4)


def plot_marker(m, cut, ex):
    box(m, (0, 0, 1.6), (0.5, 0.5, 3.6), "log", r=(0, 0, 45))
    lathe(m, (0, 0, 3.4), [(0.35, 0), (0.0, 0.7)], "log", n=4)
    rock(m, (0, 0, 0), 1.1, "stone")
    sheet(ex["tag"], (0.25, 0.0, 3.0), (1.6, 0.3, 2.7), (0.25, 0.0, 1.9), 2, 2, "teal")


def fence_rail(m, cut, ex):
    for x in (-4.0, 4.0):
        log(m, (x, 0, 0), (x, 0, 3.6), 0.22)
        lathe(m, (x, 0, 3.6), [(0.22, 0), (0.0, 0.4)], "log", n=6)
    for z in (1.2, 2.6):
        log(m, (-4.3, 0, z), (4.3, 0, z + random.uniform(-0.1, 0.1)), 0.15, n=5)
    lash(m, (-4.0, 0, 2.6), (-4.0, 0, 3.0), 0.22)
    lash(m, (4.0, 0, 2.6), (4.0, 0, 3.0), 0.22)


def lamp_post(m, cut, ex):
    log(m, (0, 0, 0), (0.2, 0, 8.0), 0.25, n=6)
    log(m, (0.2, 0, 7.8), (1.6, 0, 7.4), 0.12, n=5)
    box(m, (1.6, 0, 6.6), (0.75, 0.75, 1.1), "metal")
    box(ex["glow"], (1.6, 0, 6.6), (0.6, 0.78, 0.8), "ember")
    rock(m, (0, 0, 0), 1.0, "stone")


def notice_board(m, cut, ex):
    for x in (-2.4, 2.4):
        log(m, (x, 0, 0), (x, 0, 6.2), 0.2, n=6)
    box(m, (0, 0, 3.6), (4.6, 0.3, 3.0), "plank")
    for i in range(5):
        box(m, (-1.6 + i * 0.8 + random.uniform(-0.1, 0.1), -0.18, 3.6 + random.uniform(-0.7, 0.7)), (0.6, 0.04, 0.8),
            "canvas", r=(0, random.uniform(-6, 6), 0))
    for s in (-1, 1):
        box(m, (0, s * 0.6, 6.4), (5.6, 1.6, 0.18), "plank", r=(s * -25, 0, 0))


def market_stall(m, cut, ex):
    w, d = 6.0, 4.0
    for x in (-w / 2, w / 2):
        log(m, (x, -d / 2, 0), (x, -d / 2, 5.0), 0.18, n=6)
        log(m, (x, d / 2, 0), (x, d / 2, 5.8), 0.18, n=6)
    box(m, (0, -d / 2 + 0.6, 1.6), (w, 1.4, 0.25), "plank")
    box(m, (0, -d / 2 + 0.6, 0.8), (w - 0.4, 1.2, 1.4), "plank")
    sheet(m, (-w / 2 - 0.4, -d / 2 - 0.8, 4.8), (w / 2 + 0.4, -d / 2 - 0.8, 4.8), (-w / 2 - 0.4, d / 2 + 0.2, 5.9), 6, 3,
          "canvas", sag=0.25)
    for i in range(5):  # stripes of teal cloth valance
        x = -w / 2 + 0.6 + i * 1.2
        sheet(m, (x - 0.5, -d / 2 - 0.82, 4.8), (x + 0.5, -d / 2 - 0.82, 4.8), (x - 0.5, -d / 2 - 0.82, 4.3), 1, 1,
              "teal" if i % 2 else "canvas")
    for i in range(4):
        lathe(m, (-2.1 + i * 1.4, -d / 2 + 0.6, 1.72), [(0.5, 0), (0.55, 0.3), (0.3, 0.35)], "rope", n=8)
        lathe(m, (-2.1 + i * 1.4, -d / 2 + 0.6, 2.0), [(0.4, 0), (0.0, 0.3)], "leaf" if i % 2 else "flower", n=6)


def crate(m, c, s, r=0):
    box(m, c, (s, s, s), "plank", r=(0, 0, r))
    box(m, c, (s + 0.04, s * 0.18, s + 0.04), "rope", r=(0, 0, r))


def crate_stack(m, cut, ex):
    crate(m, (-0.9, 0, 1.0), 2.0, 5)
    crate(m, (1.2, 0.2, 0.9), 1.8, -8)
    crate(m, (0.1, 0.1, 2.85), 1.7, 20)


def banner_pole(m, cut, ex):
    log(m, (0, 0, 0), (0, 0, 12.0), 0.22, n=6)
    log(m, (0, 0, 11.4), (2.8, 0, 11.4), 0.1, n=5)
    sheet(ex["tag"], (0.2, 0, 11.3), (2.8, 0, 11.3), (0.2, 0, 6.3), 3, 5, "teal", noise=0.06)
    rock(m, (0, 0, 0), 1.2, "stone")


def boat(m, cut, ex):
    L, W = 28.0, 9.0
    prof = []
    for k in range(9):
        t = k / 8
        y = -L / 2 + t * L
        half = W / 2 * math.sin(math.pi * min(1.0, 0.1 + t * 0.95)) ** 0.7
        prof.append((y, max(half, 0.3)))
    for k in range(len(prof) - 1):  # hull strakes
        (y0, h0), (y1, h1) = prof[k], prof[k + 1]
        for s in (-1, 1):
            for z0, z1, f0 in ((0.0, 1.6, 0.55), (1.6, 3.4, 1.0)):
                a = (s * h0 * (f0 if z0 else 0.45), y0, z0)
                b = (s * h1 * (f0 if z0 else 0.45), y1, z0)
                q = [a, b, (s * h1 * f0, y1, z1), (s * h0 * f0, y0, z1)]
                m.face(q, "plank")
                m.face(list(reversed(q)), "plank")
        m.face([(-h0 * 0.95, y0, 2.6), (h0 * 0.95, y0, 2.6), (h1 * 0.95, y1, 2.6), (-h1 * 0.95, y1, 2.6)], "plank",
               center=(0, (y0 + y1) / 2, 1.0))
        m.face([(-h0 * 0.45, y0, 0), (-h1 * 0.45, y1, 0), (h1 * 0.45, y1, 0), (h0 * 0.45, y0, 0)], "plank",
               center=(0, (y0 + y1) / 2, 1.0))
    log(m, (0, -L / 2 - 1.0, 2.8), (0, L / 2 + 3.5, 3.6), 0.25)  # keel line / bowsprit
    log(m, (0, 2.0, 2.6), (0, 2.0, 24.0), 0.35)  # mast
    log(m, (0, -8.0, 6.0), (0, 2.0, 6.0), 0.2)  # boom
    sheet(m, (0, 1.6, 6.3), (0, -7.6, 6.3), (0, 1.6, 22.5), 4, 6, "canvas", sag=0.0, noise=0.08)
    sheet(m, (0, 3.0, 4.5), (0, 15.5, 3.8), (0, 2.6, 21.0), 3, 5, "canvas", noise=0.06)
    box(m, (0, -7.5, 4.2), (5.0, 6.0, 3.2), "plank")  # small cabin
    box(m, (0, -7.5, 6.0), (5.6, 6.6, 0.3), "plank")
    for y in (-11.0, 6.0):
        lathe(m, (2.6, y, 2.6), [(0.6, 0), (0.6, 0.3), (0.3, 0.3)], "rope", n=8)


def bridge(m, cut, ex):
    L = 16.0
    for i in range(14):
        y = -L / 2 + 0.6 + i * 1.14
        z = 0.6 + math.sin(math.pi * (i + 0.5) / 14) * 1.2
        box(m, (0, y, z), (5.0, 1.08, 0.25), "plank", r=(math.degrees(math.cos(math.pi * (i + 0.5) / 14) * 0.25), 0, 0))
    for x in (-2.4, 2.4):
        for k in range(5):
            y = -L / 2 + k * L / 4
            z = 0.6 + math.sin(math.pi * k / 4) * 1.2
            log(m, (x, y, -1.5), (x, y, z + 3.0), 0.2, n=6)
        for k in range(4):
            y0, y1 = -L / 2 + k * L / 4, -L / 2 + (k + 1) * L / 4
            z0 = 0.6 + math.sin(math.pi * k / 4) * 1.2 + 2.8
            z1 = 0.6 + math.sin(math.pi * (k + 1) / 4) * 1.2 + 2.8
            log(m, (x, y0, z0), (x, y1, z1), 0.14, n=5)


def shipwright_yard(m, cut, ex):
    for x in (-3.0, 3.0):  # slipway rails
        box(m, (x, 0, 0.3), (0.8, 30.0, 0.6), "log", r=(-3, 0, 0))
    for y in range(-13, 14, 3):
        box(m, (0, y, 0.15), (8.0, 0.8, 0.3), "plank")
    log(m, (0, -11, 1.5), (0, 10, 2.0), 0.4)  # keel
    for k in range(7):  # half-built ribs
        y = -9 + k * 3
        h = 3.6 * math.sin(math.pi * (k + 1) / 8) + 1.2
        for s in (-1, 1):
            cyl(m, (0, y, 1.6), (s * h, y, 3.6), 0.2, 0.2, "log", n=5)
            cyl(m, (s * h, y, 3.6), (s * h * 1.08, y, 6.4), 0.2, 0.18, "log", n=5)
    for s in (-1, 1):
        sheet(m, (s * 2.3, -9, 2.6), (s * 2.3, 0, 2.6), (s * 3.9, -9, 5.4), 4, 2, "plank")
    for k in range(5):  # timber stack
        box(m, (9.0, 4.0, 0.4 + k * 0.7), (2.4, 12.0, 0.6), "log", r=(0, 0, random.uniform(-2, 2)))
    for x in (7.0, 11.0):
        log(m, (x, -6, 0), (x, -6, 6.0), 0.2, n=5)
    log(m, (6.6, -6, 5.8), (11.4, -6, 5.8), 0.18, n=5)


def road_sign(m, cut, ex):
    log(m, (0, 0, 0), (0, 0, 7.5), 0.2, n=6)
    for i, (z, ang, ln) in enumerate(((6.6, 20, 3.2), (5.6, -65, 2.8), (4.6, 150, 3.0), (3.6, 240, 2.6))):
        a = math.radians(ang)
        c = (math.cos(a) * ln / 2, math.sin(a) * ln / 2, z)
        box(m, c, (ln, 0.15, 0.7), "plank", r=(0, 0, ang))
        tip = (math.cos(a) * (ln + 0.25), math.sin(a) * (ln + 0.25), z)
        lathe(m, (tip[0], tip[1], z - 0.35), [(0.3, 0), (0.0, 0.7)], "plank", n=3)
    rock(m, (0, 0, 0), 1.0, "stone")


def flower_bed(m, cut, ex):
    for s in (-1, 1):
        log(m, (-3.0, s * 1.5, 0.35), (3.0, s * 1.5, 0.35), 0.35)
        log(m, (s * 3.0, -1.5, 0.35), (s * 3.0, 1.5, 0.35), 0.35)
    box(m, (0, 0, 0.55), (5.6, 2.6, 0.3), "clay")
    for i in range(9):
        x, y = random.uniform(-2.5, 2.5), random.uniform(-1.1, 1.1)
        lathe(m, (x, y, 0.65), [(0.05, 0), (0.35, 0.7), (0.0, 0.9)], "leaf", n=5)
        if i % 2 == 0:
            lathe(m, (x, y, 1.45), [(0.22, 0), (0.0, 0.25)], "flower", n=5)


def barrel(m, cut, ex):
    lathe(m, (0, 0, 0), [(1.0, 0), (1.18, 0.9), (1.2, 1.4), (1.18, 1.9), (1.0, 2.8)], "plank", n=12, close_bottom=True)
    for z in (0.35, 2.45):
        lathe(m, (0, 0, z), [(1.07, 0), (1.07, 0.18)], "metal", n=12, close_top=False)
    lathe(m, (0, 0, 2.6), [(0.92, 0)], "slate", n=10)


def npc_booth(m, cut, ex):
    w, d = 6.0, 4.0
    box(m, (0, -d / 2 + 0.6, 1.4), (w, 1.0, 2.8), "plank")
    box(m, (0, -d / 2 + 0.6, 2.9), (w + 0.4, 1.4, 0.2), "plank")
    for x in (-w / 2, w / 2):
        log(m, (x, -d / 2, 0), (x, -d / 2, 5.6), 0.2, n=6)
        log(m, (x, d / 2, 0), (x, d / 2, 6.4), 0.2, n=6)
    box(m, (0, d / 2, 3.0), (w, 0.25, 6.0), "plank")
    for s in (-1, 1):
        box(m, (0, s * 1.2 + 0.2, 6.3 + (0.3 if s > 0 else 0)), (w + 1.2, 3.0, 0.25), "thatch", r=(s * -12, 0, 0))
    box(m, (-1.8, -d / 2 + 0.6, 3.25), (1.2, 0.8, 0.5), "plank")
    lathe(m, (1.6, -d / 2 + 0.6, 3.0), [(0.3, 0), (0.35, 0.6), (0.15, 0.8)], "clay", n=7)


def chart_table(m, cut, ex):
    box(m, (0, 0, 2.6), (5.0, 3.4, 0.25), "plank")
    for x in (-2.2, 2.2):
        for y in (-1.4, 1.4):
            box(m, (x, y, 1.25), (0.3, 0.3, 2.5), "log")
    sheet(m, (-2.0, -1.3, 2.76), (2.0, -1.3, 2.76), (-2.0, 1.3, 2.76), 2, 2, "canvas", both=False)
    lathe(m, (1.6, 0.9, 2.75), [(0.25, 0), (0.2, 0.15)], "metal", n=6)
    for x in (-3.5, 3.5):  # lean-to
        log(m, (x, -2.6, 0), (x, -2.6, 5.0), 0.2, n=6)
        log(m, (x, 2.6, 0), (x, 2.6, 7.0), 0.2, n=6)
    sheet(m, (-4.0, -3.2, 4.8), (4.0, -3.2, 4.8), (-4.0, 3.0, 7.2), 4, 3, "thatch")


def post_box(m, cut, ex):
    log(m, (0, 0, 0), (0, 0, 3.2), 0.2, n=6)
    box(m, (0, 0, 3.8), (1.6, 1.2, 1.4), "plank")
    box(m, (0, 0, 4.6), (1.9, 1.5, 0.25), "plank", r=(8, 0, 0))
    box(m, (0, -0.62, 4.0), (0.9, 0.05, 0.15), "metal")
    sheet(ex["tag"], (-0.6, -0.65, 3.6), (0.6, -0.65, 3.6), (-0.6, -0.65, 3.3), 1, 1, "teal")


def rescue_bell(m, cut, ex):
    for x in (-2.0, 2.0):
        log(m, (x, 0, 0), (x * 0.8, 0, 7.0), 0.25)
        log(m, (x, -1.2, 0), (x * 0.8, 0, 4.0), 0.14, n=5)
    log(m, (-2.0, 0, 6.8), (2.0, 0, 6.8), 0.25)
    for s in (-1, 1):
        box(m, (0, s * 0.6, 7.6), (5.0, 1.6, 0.18), "plank", r=(s * -30, 0, 0))
    lathe(m, (0, 0, 4.7), [(1.0, 0), (0.95, 0.2), (0.7, 1.0), (0.45, 1.6), (0.15, 1.9)], "metal", n=12)
    cyl(m, (0, 0, 6.6), (0, 0, 6.2), 0.1, 0.1, "metal", n=5)
    cyl(m, (0.4, 0, 4.7), (0.6, 0, 1.4), 0.06, 0.06, "rope", n=4, cap=False)  # straight pull cord


def drift_walkway(m, cut, ex):
    for i in range(10):
        box(m, (random.uniform(-0.15, 0.15), -7.2 + i * 1.6, 0.6), (4.2, 1.5, 0.22), "plank",
            r=(0, random.uniform(-2, 2), random.uniform(-3, 3)))
    for y in (-7.5, 0.0, 7.5):
        for x in (-2.0, 2.0):
            log(m, (x, y, -2.0), (x, y, 1.2), 0.25, n=6)
    for x in (-2.2, 2.2):
        log(m, (x, -8, 0.4), (x, 8, 0.4), 0.18, n=5)


def balloon_wreck(m, cut, ex):
    """Opening set piece: a deflated research balloon envelope over reef rocks, wicker gondola on its side."""
    for i in range(7):  # reef rocks
        rock(m, (random.uniform(-10, 10), random.uniform(-6, 6), -0.6), random.uniform(2.0, 3.8), "stone")
    # gondola: wicker basket tipped on its side
    gc = Vector((-4.0, -2.0, 2.2))
    for k in range(5):
        ang = k * 2 * math.pi / 4
    box(m, gc, (4.4, 4.4, 3.6), "thatch", r=(0, 70, 15))
    box(m, gc + Vector((1.4, 0.4, 1.9)), (4.6, 4.6, 0.35), "rope", r=(0, 70, 15))
    for k in range(4):  # gondola struts to the envelope
        a = gc + Vector((1.5 + k * 0.1, -1.5 + k, 2.0))
        cyl(m, a, (3.0 + k, -2.0 + k * 1.2, 2.6), 0.08, 0.08, "rope", n=4, cap=False)
    # envelope: a crumpled canvas mound draped over rocks
    nu, nv = 14, 10
    G = []
    for j in range(nv + 1):
        row = []
        for i in range(nu + 1):
            u, v = i / nu, j / nv
            x = 1.0 + u * 14.0
            y = -6.0 + v * 12.0
            z = 0.4 + 3.4 * math.sin(math.pi * v) * (0.5 + 0.5 * math.sin(math.pi * u * 0.9)) * (0.6 + 0.4 * math.sin(u * 9 + v * 5))
            z += random.uniform(-0.25, 0.25)
            row.append(Vector((x, y, max(z, 0.2))))
        G.append(row)
    for j in range(nv):
        for i in range(nu):
            q = [G[j][i], G[j][i + 1], G[j + 1][i + 1], G[j + 1][i]]
            tile = "canvas" if (i // 3 + j // 3) % 2 == 0 else "teal"
            m.face(q, tile)
            m.face(list(reversed(q)), tile)
    for k in range(5):  # load lines across the envelope
        cyl(m, (1.5 + k * 3, -6.0, 0.4), (1.5 + k * 3, 6.0, 0.4), 0.05, 0.05, "rope", n=3, cap=False)
    for x, y in ((-8.0, 3.0), (-6.5, 4.5), (-9.5, -4.5)):  # spilled crates and a barrel
        crate(m, (x, y, 0.9), 1.6, random.uniform(-30, 30))
    lathe(m, (-1.2, 5.0, 0), [(0.7, 0), (0.8, 0.9), (0.7, 1.8)], "plank", n=10)
    box(m, (-6.0, -6.0, 0.6), (2.6, 1.2, 0.3), "metal", r=(0, 0, 30))  # instrument box


def beacon_tower(m, cut, ex):
    s = 2.8
    for x in (-s, s):
        for y in (-s, s):
            log(m, (x, y, 0), (x * 0.45, y * 0.45, 13.0), 0.3)
    for z in (3.5, 7.5, 11.0):
        r = s * (1 - z / 13.0 * 0.55)
        c = [(-r, -r), (r, -r), (r, r), (-r, r)]
        for i in range(4):
            log(m, (*c[i], z), (*c[(i + 1) % 4], z), 0.16, n=5)
        log(m, (*c[0], z - 3.0), (*c[2], z), 0.12, n=4)
    box(m, (0, 0, 13.2), (3.2, 3.2, 0.35), "plank")
    lathe(m, (0, 0, 13.4), [(0.6, 0), (1.3, 1.0), (1.4, 1.3)], "metal", n=10)  # fire basket
    lathe(ex["ember"], (0, 0, 14.0), [(1.0, 0), (0.4, 1.0)], "ember", n=8)
    for i in range(6):  # mirror crown
        a = i * math.pi / 3
        box(m, (math.cos(a) * 1.6, math.sin(a) * 1.6, 15.6), (1.0, 0.1, 1.0), "metal", r=(20, 0, math.degrees(a) + 90))
        box(ex["glow"], (math.cos(a) * 1.68, math.sin(a) * 1.68, 15.6), (0.8, 0.05, 0.8), "glow", r=(20, 0, math.degrees(a) + 90))
    for i in range(3):  # driftwood skirt
        log(m, (random.uniform(-4, 4), -4.2, 0.3), (random.uniform(-4, 4), 4.2, 0.4), 0.35)


# ---------------------------------------------------------------- rows table
# key, builder, package, tri budget
ROWS = [
    ("bld.campfire", campfire, "RobangoBldA", 1200),
    ("bld.workbench.t1", workbench_t1, "RobangoBldA", 1800),
    ("bld.workbench.t2", workbench_t2, "RobangoBldA", 2200),
    ("bld.workbench.t3", workbench_t3, "RobangoBldA", 2800),
    ("bld.tanning-frame", tanning_frame, "RobangoBldA", 1000),
    ("bld.joiner-bench", joiner_bench, "RobangoBldA", 2000),
    ("bld.clan-hall", clan_hall, "RobangoBldA", 6000),
    ("bld.animal-pen", animal_pen, "RobangoBldA", 1400),
    ("bld.storage", storage, "RobangoBldA", 600),
    ("bld.timber.floor", timber_floor, "RobangoBldA", 200),
    ("bld.timber.wall", timber_wall, "RobangoBldA", 400),
    ("bld.timber.roof", timber_roof, "RobangoBldA", 500),
    ("bld.timber.door", timber_door, "RobangoBldA", 400),
    ("bld.timber.stairs", timber_stairs, "RobangoBldA", 600),
    ("bld.timber.pillar", timber_pillar, "RobangoBldA", 150),
    ("bld.kiln.t1", kiln_t1, "RobangoBldB", 1400),
    ("bld.kiln.t2", kiln_t2, "RobangoBldB", 1800),
    ("bld.kiln.t3", kiln_t3, "RobangoBldB", 2400),
    ("bld.mud-kiln", mud_kiln, "RobangoBldB", 1200),
    ("bld.mason-bench", mason_bench, "RobangoBldB", 1800),
    ("bld.refrigerator", refrigerator, "RobangoBldB", 900),
    ("bld.well", well, "RobangoBldB", 1400),
    ("bld.stone.floor", stone_floor, "RobangoBldB", 250),
    ("bld.stone.wall", stone_wall, "RobangoBldB", 500),
    ("bld.stone.roof", stone_roof, "RobangoBldB", 500),
    ("bld.brick.floor", brick_floor, "RobangoBldB", 250),
    ("bld.brick.wall", brick_wall, "RobangoBldB", 500),
    ("bld.brick.roof", brick_roof, "RobangoBldB", 600),
    ("bld.volcanic-wall", volcanic_wall, "RobangoBldB", 500),
    ("bld.tent", tent, "RobangoBldC", 1200),
    ("bld.bed", bed, "RobangoBldC", 800),
    ("bld.signal-relay", signal_relay, "RobangoBldC", 1600),
    ("bld.laboratory", laboratory, "RobangoBldC", 2400),
    ("town.trading-post", trading_post, "RobangoHero", 9000),
    ("town.rift-ring", rift_ring, "RobangoHero", 3000),
    ("town.dock", dock, "RobangoTownKit", 5000),
    ("town.plot-marker", plot_marker, "RobangoTownKit", 300),
    ("town.fence-rail", fence_rail, "RobangoTownKit", 300),
    ("town.lamp-post", lamp_post, "RobangoTownKit", 400),
    ("town.notice-board", notice_board, "RobangoTownKit", 600),
    ("town.market-stall", market_stall, "RobangoTownKit", 1500),
    ("town.crate-stack", crate_stack, "RobangoTownKit", 500),
    ("town.banner-pole", banner_pole, "RobangoTownKit", 400),
    ("town.boat", boat, "RobangoTownKit", 4000),
    ("town.bridge", bridge, "RobangoTownKit", 1500),
    ("town.shipwright-yard", shipwright_yard, "RobangoTownKit", 4000),
    ("town.road-sign", road_sign, "RobangoTownKit", 300),
    ("town.flower-bed", flower_bed, "RobangoTownKit", 500),
    ("town.barrel", barrel, "RobangoTownKit", 300),
    ("town.npc-booth", npc_booth, "RobangoTownKit", 1200),
    ("town.chart-table", chart_table, "RobangoTownKit", 1200),
    ("town.post-box", post_box, "RobangoTownKit", 400),
    ("town.rescue-bell", rescue_bell, "RobangoTownKit", 600),
    ("town.drift-camp-walkway", drift_walkway, "RobangoTownKit", 800),
    ("town.balloon-wreck", balloon_wreck, "RobangoTownKit", 6000),
    ("town.beacon-tower", beacon_tower, "RobangoTownKit", 3000),
]
SUFFIXES = ("cut", "ember", "glow", "tag", "halo")



# ---------------------------------------------------------------- main


def atlas_material(root):
    alb = C.load_image(os.path.join(root, "atlas_albedo.png"))
    nor = C.load_image(os.path.join(root, "atlas_normal.png"), non_color=True)
    rough = C.load_image(os.path.join(root, "atlas_rough.png"), non_color=True)
    return C.image_material("RobangoBldAtlas", alb, nor, rough)


def bounds(objs):
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in objs:
        for v in o.data.vertices:
            w = o.matrix_world @ v.co
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    return lo, hi


def roblox_box(lo, hi):
    """Blender (X, Y, Z-up) -> Roblox (X, Y-up, Z = -Blender Y)."""
    return {"min": [lo.x, lo.z, -hi.y], "max": [hi.x, hi.z, -lo.y]}


def main():
    root = os.path.abspath(sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "build/b3")
    out = os.path.join(root, "out")
    os.makedirs(out, exist_ok=True)
    only = set(sys.argv[sys.argv.index("--") + 2 :]) if "--" in sys.argv else set()
    C.reset(SEED)
    mat = atlas_material(root)
    packages = {}
    rows = {}
    for key, builder, package, budget in ROWS:
        random.seed(f"{SEED}:{key}")
        m, cut = MB(), MB()
        ex = {s: MB() for s in SUFFIXES if s != "cut"}
        builder(m, cut, ex)
        parts = [(key, m)] + [(f"{key}__cut", cut)] + [(f"{key}__{s}", mb) for s, mb in ex.items()]
        objs = []
        tris = 0
        for name, mb in parts:
            if not mb.faces:
                continue
            o = mb.build(name)
            o.data.materials.append(mat)
            tris += C.triangles(o)
            objs.append(o)
        lo, hi = bounds(objs)
        mlo, mhi = bounds([objs[0]])
        rows[key] = {
            "package": package,
            "tris": tris,
            "budget": budget,
            "fits": tris <= budget,
            "bounds": roblox_box(lo, hi),
            "main": roblox_box(mlo, mhi),
            "meshes": [o.name for o in objs],
        }
        print(f"{key:28s} {package:14s} tris={tris:5d}/{budget:5d} {'ok' if tris <= budget else 'OVER'}")
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
            path_mode="COPY",
            embed_textures=True,
            bake_anim=False,
            mesh_smooth_type="FACE",
        )
        print("exported", path, os.path.getsize(path))
    # silhouettes + previews per row (moderation screen and report)
    for package, entries in packages.items():
        for key, objs in entries:
            for other in bpy.context.scene.objects:
                other.hide_render = True
            for o in objs:
                o.hide_render = False
            C.silhouette(key, out, objs)
            C.preview(key, out, objs)
    print("done")


main()
