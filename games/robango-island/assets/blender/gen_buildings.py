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
  <key>__wall  L5 house walls above the wainscot (second cut-away layer: walls fade with the roof)
  <key>__lamp  L5 warm window panes / door lanterns (warm Neon + PointLight, no Fire)
  <key>__halo  rift shard halo
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
# Tiles whose texture has a fixed "up" (courses, shingles, reed fall line): V follows world up on
# walls and the fall line on roofs. Grain tiles (log, plank, rope, metal) follow the longest edge.
UPRIGHT = {"thatch", "canvas", "stone", "brick", "clay", "slate", "tile", "hide", "char", "teal", "seaglass"}


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

    def face(self, pts, tile, center=None, uvs=None):
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
                uvs = list(reversed(uvs)) if uvs else uvs
        self.faces.append((pts, tile, uvs))

    def tris(self):
        return sum(len(p) - 2 for p, _, _ in self.faces)

    @staticmethod
    def chunks(pts, tile):
        """Long quads are split along their long side so each piece maps to at most ~one tile span
        (an atlas tile cannot repeat, so one long face would otherwise squeeze or stretch)."""
        if len(pts) != 4 or tile in SOLIDS:
            return [pts]
        p0, p1, p2, p3 = pts
        span = SPAN.get(tile, 6)
        a, b = (p1 - p0).length, (p2 - p1).length
        k = min(6, max(1, math.ceil(max(a, b) / (span * 1.15))))
        if k == 1:
            return [pts]
        out = []
        for i in range(k):
            s, t = i / k, (i + 1) / k
            if a >= b:
                out.append([p0.lerp(p1, s), p0.lerp(p1, t), p3.lerp(p2, t), p3.lerp(p2, s)])
            else:
                out.append([p0.lerp(p3, s), p1.lerp(p2, s), p1.lerp(p2, t), p0.lerp(p3, t)])
        return out

    def build(self, name):
        bm = bmesh.new()
        uv = bm.loops.layers.uv.new("UVMap")
        for whole, tile, uvs in self.faces:
            if uvs:
                self._mapped(bm, uv, whole, tile, uvs)
                continue
            for pts in self.chunks(whole, tile):
                self._face(bm, uv, pts, tile)
        bm.normal_update()
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
        obj = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(obj)
        return obj

    @staticmethod
    def _mapped(bm, uv, pts, tile, uvs):
        try:
            f = bm.faces.new([bm.verts.new(p) for p in pts])
        except ValueError:
            return
        u0, v0, du, dv = tile_rect(tile)
        for loop, (a, b) in zip(f.loops, uvs):
            loop[uv].uv = (u0 + (MARGIN + a * (1 - 2 * MARGIN)) * du, v0 + (MARGIN + b * (1 - 2 * MARGIN)) * dv)

    @staticmethod
    def _face(bm, uv, pts, tile):
        vs = [bm.verts.new(p) for p in pts]
        try:
            f = bm.faces.new(vs)
        except ValueError:
            return
        u0, v0, du, dv = tile_rect(tile)
        if dv == 0.0:
            for loop in f.loops:
                loop[uv].uv = (u0 + random.random() * du, v0 - random.random() * du * 0.5)
            return
        # Newell normal from the points: bmesh face normals are zero until normal_update(), which
        # left every vertical face with a degenerate V axis (the B3 "streak" stretch).
        n = Vector((0, 0, 0))
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            n += Vector(((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)))
        if n.length < 1e-9:
            return
        n.normalize()
        # V follows the grain: the longest edge (logs, planks, posts), or the fall line on roofs.
        edges = [pts[(i + 1) % len(pts)] - pts[i] for i in range(len(pts))]
        if tile in UPRIGHT and abs(n.z) < 0.9:
            grain = Vector((0, 0, 1)) - n * n.z
        else:
            grain = max(edges, key=lambda e: e.length).copy()
        grain -= n * grain.dot(n)
        if grain.length < 1e-6:
            grain = n.orthogonal()
        t2 = grain.normalized()
        t1 = t2.cross(n).normalized()
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
    """Subdivided cloth/hide sheet spanning p00->p10 (u) and p00->p01 (v); sags along -Z.
    The whole sheet maps continuously into one atlas tile (V up the cloth, so the hem grime of
    the cloth tiles sits on the lowest edge) instead of one random patch per cell."""
    p00, p10, p01 = Vector(p00), Vector(p10), Vector(p01)
    du, dv = p10 - p00, p01 - p00
    span = SPAN.get(tile, 6)
    su = min(1.0, du.length / span)
    sv = min(1.0, dv.length / span)
    flip = p01.z < p00.z  # keep V pointing up the cloth
    ou = random.random() * (1 - su)
    ov = random.random() * (1 - sv)
    G, T = [], []
    for j in range(nv + 1):
        row, trow = [], []
        for i in range(nu + 1):
            u, v = i / nu, j / nv
            p = p00 + du * u + dv * v
            p.z -= sag * math.sin(math.pi * u) * math.sin(math.pi * v)
            if noise:
                p.z += random.uniform(-noise, noise)
            row.append(p)
            trow.append((ou + u * su, ov + ((1 - v) if flip else v) * sv))
        G.append(row)
        T.append(trow)
    for j in range(nv):
        for i in range(nu):
            q = [G[j][i], G[j][i + 1], G[j + 1][i + 1], G[j + 1][i]]
            t = [T[j][i], T[j][i + 1], T[j + 1][i + 1], T[j + 1][i]]
            mb.face(q, tile, uvs=t)
            if both:
                mb.face(list(reversed(q)), tile, uvs=list(reversed(t)))


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


# ---------------------------------------------------------------- L5: town houses, plot fences, opening props
# Houses: the door faces Blender +Y (Roblox -Z), ridge along X, pivot = ground centre of the walls.
#   <key>        footing, plank floor, wainscot (lowest wall course), corner posts, door frame,
#                porch deck, interior props, yard dressing (always visible)
#   <key>__wall  wall panels/logs above the wainscot and gable fills (fade: walls)
#   <key>__cut   roof courses, ridge, barge boards, chimney stack above the eave, porch roof (fade: roof)
#   <key>__lamp  warm window panes and the door lantern (L8: warm Neon + PointLight, no Fire)
WAINSCOT = 1.4


def wall_run(mb, a, b, z0, z1, t, tile, holes=()):
    """Straight wall a->b (XY) from z0 to z1, thickness t; holes: (s along the run, width, h0, h1)."""
    a, b = Vector((a[0], a[1], 0)), Vector((b[0], b[1], 0))
    length = (b - a).length
    d = (b - a).normalized()
    ang = math.degrees(math.atan2(d.y, d.x))

    def piece(s0, s1, h0, h1):
        if s1 - s0 < 0.05 or h1 - h0 < 0.05:
            return
        c = a + d * ((s0 + s1) / 2)
        box(mb, (c.x, c.y, (h0 + h1) / 2), (s1 - s0, t, h1 - h0), tile, r=(0, 0, ang))

    s = 0.0
    for hs, hw, h0, h1 in sorted(holes):
        piece(s, hs - hw / 2, z0, z1)
        piece(hs - hw / 2, hs + hw / 2, z0, max(z0, h0))
        piece(hs - hw / 2, hs + hw / 2, min(z1, h1), z1)
        s = hs + hw / 2
    piece(s, length, z0, z1)


def gable_fill(mb, x, d, z0, z1, t, tile):
    """Triangular gable end in the YZ plane at x (base width d), closed both sides."""
    inner = Vector((x, 0, z0 + (z1 - z0) * 0.3))
    for off in (-t / 2, t / 2):
        tri = [(x + off, -d / 2, z0), (x + off, d / 2, z0), (x + off, 0, z1)]
        mb.face(tri, tile, center=inner)
    for k in range(2):
        p, q = ((x, -d / 2, z0), (x, 0, z1)) if k == 0 else ((x, 0, z1), (x, d / 2, z0))
        mb.face([(x - t / 2, p[1], p[2]), (x + t / 2, p[1], p[2]), (x + t / 2, q[1], q[2]), (x - t / 2, q[1], q[2])],
                tile, center=inner)


def course_roof(cut, length, depth, eave, ridge, tile, courses=6, over=1.2, thick=0.3, tilt=4.0):
    """Gable roof (ridge along X) of overlapping courses. Each course is a few degrees steeper
    than the roof plane so its butt edge kicks out: a shingle / thatch read at the town camera."""
    half = depth / 2 + over
    rise = ridge - eave
    a2 = math.atan2(rise, half) + math.radians(tilt)
    slope = math.hypot(half, rise)
    seg = slope / courses * 1.4
    for s in (-1, 1):
        for k in range(courses):
            f1 = (k + 1) / courses
            py, pz = half * (1 - f1), eave - 0.25 + rise * f1
            yc = py + math.cos(a2) * seg / 2 + math.sin(a2) * thick / 2
            zc = pz - math.sin(a2) * seg / 2 + math.cos(a2) * thick / 2
            box(cut, (random.uniform(-0.08, 0.08), s * yc, zc),
                (length + over * 2 + random.uniform(-0.2, 0.2), seg, thick), tile,
                r=(-s * math.degrees(a2) + random.uniform(-0.8, 0.8), 0, random.uniform(-0.4, 0.4)))
        for x in (-length / 2 - over, length / 2 + over):  # barge boards
            log(cut, (x, s * (half + 0.1), eave - 0.4), (x, 0, ridge + 0.3), 0.16, n=5)
    log(cut, (-length / 2 - over - 0.3, 0, ridge + 0.4), (length / 2 + over + 0.3, 0, ridge + 0.4), 0.34, n=6)


def window(walls, lamp, p, out, w, h):
    """Frame + open plank shutters (walls) and a warm pane set into the wall (lamp).
    p: centre on the wall's outer face; out: outward unit vector (axis aligned)."""
    facing_y = abs(out.y) > 0.5
    along = Vector((1, 0, 0)) if facing_y else Vector((0, 1, 0))

    def sz(a, o, z):  # size along the wall, outward, vertical
        return (a, o, z) if facing_y else (o, a, z)

    box(lamp, p - out * 0.25, sz(w, 0.1, h), "ember")
    for k in (-1, 1):
        box(walls, p + along * (k * w / 2) + out * 0.08, sz(0.22, 0.3, h + 0.3), "log")
        box(walls, p + Vector((0, 0, k * h / 2)) + out * 0.1, sz(w + 0.5, 0.32, 0.22), "plank")
        box(walls, p + along * (k * (w * 0.78)) + out * 0.22, sz(w * 0.5, 0.12, h + 0.2), "plank",
            r=(0, 0, k * 10 * (1 if (out.y + out.x) > 0 else -1)))
    box(walls, p + out * 0.1, sz(0.12, 0.25, h), "log")  # mullion


def footing(m, length, depth, h):
    box(m, (0, 0, h / 2 - 0.2), (length + 0.8, depth + 0.8, h + 0.4), "stone")
    for i in range(int((length + depth) * 0.7)):  # loose stones along the base
        t = random.random()
        if random.random() < 0.5:
            p = (-length / 2 + t * length, random.choice((-1, 1)) * (depth / 2 + 0.5))
        else:
            p = (random.choice((-1, 1)) * (length / 2 + 0.5), -depth / 2 + t * depth)
        rock(m, (p[0], p[1], 0), random.uniform(0.6, 1.0), "stone", n=5)


def plank_floor(m, length, depth, z):
    n = max(2, int(depth / 1.6))
    for i in range(n):
        y = -depth / 2 + (i + 0.5) * depth / n
        box(m, (0, y, z), (length, depth / n - 0.06, 0.2), "plank", r=(0, 0, random.uniform(-0.2, 0.2)))


def interior(m, length, depth, z, long=False):
    """Readable props for the R16-3 cut-away view: bed(s), table, chest, pots, rug."""
    beds = (-length / 2 + 2.2,) if not long else (-length / 2 + 2.2, -length / 2 + 5.6)
    for bx in beds:
        box(m, (bx, -depth / 2 + 2.0, z + 0.45), (2.6, 3.2, 0.6), "plank")
        box(m, (bx, -depth / 2 + 2.1, z + 0.85), (2.3, 2.9, 0.25), "canvas")
        box(m, (bx, -depth / 2 + 1.0, z + 1.05), (1.6, 0.7, 0.3), "hide")
    tx = length / 2 - 3.0
    box(m, (tx, 0.4, z + 1.25), (2.8, 1.8, 0.2), "plank")
    for dx in (-1.1, 1.1):
        box(m, (tx + dx, 0.4, z + 0.6), (0.25, 1.4, 1.2), "log")
    for dy in (-1.5, 2.3):
        box(m, (tx, 0.4 + dy * 0.8, z + 0.5), (2.2, 0.5, 0.2), "plank")
    box(m, (length / 2 - 1.5, -depth / 2 + 1.5, z + 0.55), (1.6, 1.0, 1.1), "plank")  # chest
    box(m, (length / 2 - 1.5, -depth / 2 + 1.5, z + 0.75), (1.66, 1.06, 0.15), "metal")
    sheet(m, (-1.6, -1.0, z + 0.13), (1.6, -1.0, z + 0.13), (-1.6, 1.4, z + 0.13), 2, 2, "hide", both=False)
    for i in range(2):
        lathe(m, (-0.6 + i * 0.9, -depth / 2 + 1.0, z), [(0.35, 0), (0.45, 0.5), (0.3, 0.9)], "clay", n=7)


def house(m, cut, ex, length, depth, wall_h, rise, roof_tile, wall_tile, chimney=None, porch=False,
          courses=6, thick=0.3, logs=False, stone_lower=False, long=False, walls_mb=None):
    """Shared house body. walls_mb: where the walls go (default ex["wall"]; the clan hall keeps
    walls in __cut so the existing G24 cut-away fades them)."""
    walls, lamp = walls_mb or ex["wall"], ex["lamp"]
    base = 0.9
    footing(m, length, depth, base)
    plank_floor(m, length - 0.8, depth - 0.8, base + 0.1)
    top = base + wall_h
    hl, hd = length / 2, depth / 2
    dw, dh = 2.6, 4.4
    t = 0.7
    wz, wh, ww = base + 3.0, 1.6, 1.8
    win = lambda s, w=ww: (s, w, wz - wh / 2, wz + wh / 2)
    front = [(hl, dw, base, base + dh), win(hl * 0.4), win(length - hl * 0.4)]
    if long:
        front = [(hl, dw, base, base + dh), win(length * 0.18), win(length * 0.36), win(length * 0.64),
                 win(length * 0.82)]
    back = [win(hl * 0.6), win(length - hl * 0.6)] if long else [win(hl)]
    side = [win(hd)]
    # runs go counter-clockwise seen from above so the outward normal is to the right
    runs = [((hl, hd), (-hl, hd), front, Vector((0, 1, 0))), ((-hl, -hd), (hl, -hd), back, Vector((0, -1, 0))),
            ((-hl, hd), (-hl, -hd), side, Vector((-1, 0, 0))), ((hl, -hd), (hl, hd), side, Vector((1, 0, 0)))]
    for a, b, holes, out in runs:
        door_only = [h for h in holes if h[2] <= base + 0.01]
        wall_run(m, a, b, base, base + WAINSCOT, t, "stone" if stone_lower else wall_tile, door_only)
        if stone_lower:
            mid = base + wall_h * 0.48
            wall_run(walls, a, b, base + WAINSCOT, mid, t, "stone", holes)
            wall_run(walls, a, b, mid, top, t * 0.8, wall_tile, holes)
            box(walls, ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2, mid),
                (abs(b[0] - a[0]) + t + 0.2, abs(b[1] - a[1]) + t + 0.2, 0.3), "log")
        elif logs:
            run_len = (Vector(b) - Vector(a)).length
            d = (Vector((b[0], b[1], 0)) - Vector((a[0], a[1], 0))).normalized()
            n = int(round((wall_h - WAINSCOT) / 0.9))
            for k in range(n):
                z = base + WAINSCOT + 0.45 + k * 0.9
                cuts, s0 = [], 0.0
                for hs, hw, h0, h1 in sorted(holes):
                    if h0 - 0.3 < z < h1 + 0.3:
                        cuts.append((s0, hs - hw / 2))
                        s0 = hs + hw / 2
                cuts.append((s0, run_len))
                for p0, p1 in cuts:
                    e0 = 0.8 if p0 == 0.0 else 0.0  # notched corner overhang
                    e1 = 0.8 if p1 == run_len else 0.0
                    if p1 - p0 < 0.3:
                        continue
                    A = Vector((a[0], a[1], z)) + d * (p0 - e0)
                    B = Vector((a[0], a[1], z)) + d * (p1 + e1)
                    log(walls, A, B, 0.47, n=6)
        else:
            wall_run(walls, a, b, base + WAINSCOT, top, t, wall_tile, holes)
            d = (Vector((b[0], b[1], 0)) - Vector((a[0], a[1], 0)))
            for f in (0.25, 0.75):  # vertical battens between openings
                p = Vector((a[0], a[1], 0)) + d * f + out * (t / 2 + 0.08)
                if all(abs(f * d.length - hs) > hw / 2 + 0.4 for hs, hw, _, _ in holes):
                    box(walls, (p.x, p.y, (base + WAINSCOT + top) / 2), (0.3, 0.3, top - base - WAINSCOT), "log")
        for hs, hw, h0, h1 in holes:
            if h0 <= base + 0.01:
                continue
            d = (Vector((b[0], b[1], 0)) - Vector((a[0], a[1], 0))).normalized()
            p = Vector((a[0], a[1], 0)) + d * hs + out * (t / 2) + Vector((0, 0, (h0 + h1) / 2))
            window(walls, lamp, p, out, hw, h1 - h0)
        if not logs:
            box(walls, ((a[0] + b[0]) / 2 + out.x * 0.05, (a[1] + b[1]) / 2 + out.y * 0.05, top - 0.15),
                (abs(b[0] - a[0]) + 0.6 if abs(out.y) > 0.5 else t + 0.2,
                 abs(b[1] - a[1]) + 0.6 if abs(out.x) > 0.5 else t + 0.2, 0.35), "log")  # top plate
    if not logs:
        for x in (-hl, hl):
            for y in (-hd, hd):
                box(m, (x, y, (base + top) / 2), (0.8, 0.8, top - base + 0.1), "log")
    for x in (-hl, hl):
        gable_fill(walls, x, depth + 0.4, top, top + rise - 0.3, t * 0.8, "plank")
    # door: frame + lintel stay on the main mesh so the doorway reads with the walls faded
    for dx in (-dw / 2 - 0.2, dw / 2 + 0.2):
        box(m, (dx, hd, base + dh / 2), (0.4, t + 0.3, dh), "log")
    box(m, (0, hd, base + dh + 0.2), (dw + 1.0, t + 0.3, 0.4), "log")
    for i in range(3):  # plank leaf, ajar inward
        box(walls, (-dw / 2 + 0.45 + i * 0.85, hd - 0.6 - i * 0.28, base + dh / 2), (0.82, 0.16, dh - 0.1), "plank",
            r=(0, 0, 18))
    box(m, (0, hd + 1.0, base * 0.5), (dw + 1.4, 1.6, base), "stone")  # threshold step
    course_roof(cut, length, depth, top, top + rise, roof_tile, courses=courses, thick=thick)
    box(m, (dw / 2 + 0.9, hd + 0.6, base + dh), (0.12, 0.9, 0.12), "metal")  # door lantern
    box(m, (dw / 2 + 0.9, hd + 1.0, base + dh - 0.55), (0.55, 0.55, 0.75), "metal")
    box(lamp, (dw / 2 + 0.9, hd + 1.0, base + dh - 0.55), (0.42, 0.58, 0.52), "ember")
    if chimney:
        cx, cy = chimney
        h_top = top + rise + 1.2
        box(m, (cx, cy, (base + top) / 2), (1.7, 1.7, top - base), "stone")
        box(cut, (cx, cy, (top + h_top) / 2), (1.6, 1.6, h_top - top), "stone")
        box(cut, (cx, cy, h_top + 0.15), (2.0, 2.0, 0.3), "slate")
    if porch:
        pd = 3.2
        pw = min(length * 0.6, 12.0)
        box(m, (0, hd + pd / 2 + 0.3, base - 0.05), (pw, pd, 0.3), "plank")
        for x in (-pw / 2 + 0.3, pw / 2 - 0.3):
            log(m, (x, hd + pd, 0), (x, hd + pd, base + dh + 0.8), 0.22, n=6)
            lash(m, (x, hd + pd, base + dh + 0.4), (x, hd + pd, base + dh + 0.8), 0.22)
        log(m, (-pw / 2, hd + pd, base + dh + 0.8), (pw / 2, hd + pd, base + dh + 0.8), 0.18, n=5)
        box(cut, (0, hd + pd / 2 + 0.4, base + dh + 1.35), (pw + 1.0, pd + 1.6, 0.28), roof_tile, r=(-16, 0, 0))
    interior(m, length, depth, base + 0.2, long=long)
    # yard dressing: rain barrel, stacked firewood
    lathe(m, (-hl - 1.3, hd - 1.2, 0), [(0.7, 0), (0.82, 0.7), (0.7, 1.6)], "plank", n=9, close_bottom=True)
    lathe(m, (-hl - 1.3, hd - 1.2, 1.55), [(0.62, 0)], "slate", n=8)
    for k in range(3):
        for j in range(3 - k):
            y = -hd + 1.2 + j * 0.62 + k * 0.31
            log(m, (hl + 0.8, y, 0.35 + k * 0.55), (hl + 2.6, y, 0.35 + k * 0.55), 0.28, n=5)


def cottage_a(m, cut, ex):
    """Plank cottage, steep thatch, stone chimney, front porch."""
    house(m, cut, ex, 14.0, 10.0, 6.0, 5.6, "thatch", "plank", chimney=(4.4, -3.2), porch=True, courses=5,
          thick=0.6)


def cottage_b(m, cut, ex):
    """Log cabin with notched corners and a plank-shingle roof."""
    house(m, cut, ex, 12.0, 10.0, 6.2, 4.8, "plank", "log", chimney=(-3.8, -3.0), courses=7, thick=0.26, logs=True)


def cottage_c(m, cut, ex):
    """Stone lower storey, plank upper walls, slate roof (the settled house)."""
    house(m, cut, ex, 13.0, 9.0, 6.8, 5.0, "slate", "plank", chimney=(0.0, -2.6), porch=True, courses=6,
          thick=0.26, stone_lower=True)


def longhouse(m, cut, ex):
    """Long communal house: 26 studs, thatch, two chimneys and a woodpile lean-to at the back."""
    house(m, cut, ex, 26.0, 11.0, 6.0, 6.2, "thatch", "plank", chimney=(-7.0, -3.6), porch=True, courses=5,
          thick=0.6, long=True)
    box(m, (7.0, -3.6, 3.9), (1.7, 1.7, 6.0), "stone")
    box(cut, (7.0, -3.6, 10.6), (1.6, 1.6, 7.4), "stone")
    box(cut, (7.0, -3.6, 14.4), (2.0, 2.0, 0.3), "slate")
    for x in (6.0, 12.0):
        log(m, (x, -8.6, 0), (x, -8.6, 3.6), 0.2, n=5)
    for k in range(4):
        log(m, (6.4, -7.6, 0.35 + k * 0.55), (11.6, -7.6, 0.35 + k * 0.55), 0.26, n=5)
    box(cut, (9.0, -7.4, 4.0), (7.0, 3.2, 0.24), "plank", r=(16, 0, 0))


def workshop(m, cut, ex):
    """Open-front timber workshop: forge with brick chimney, anvil, bench, racks; pent plank roof."""
    walls, lamp = ex["wall"], ex["lamp"]
    L, D, H = 14.0, 10.0, 6.5
    hl, hd = L / 2, D / 2
    footing(m, L, D, 0.6)
    box(m, (0, 0, 0.75), (L - 0.4, D - 0.4, 0.2), "stone")
    wall_run(m, (-hl, -hd), (hl, -hd), 0.6, 0.6 + WAINSCOT, 0.6, "plank")
    wall_run(walls, (-hl, -hd), (hl, -hd), 0.6 + WAINSCOT, H + 1.4, 0.6, "plank")
    for x in (-hl, hl):
        wall_run(m, (x, -hd), (x, hd * 0.2), 0.6, 0.6 + WAINSCOT, 0.6, "plank")
        wall_run(walls, (x, -hd), (x, hd * 0.2), 0.6 + WAINSCOT, H, 0.6, "plank")
    for x in (-hl, -hl / 3, hl / 3, hl):  # open front on posts
        log(m, (x, hd, 0), (x, hd, H), 0.32, n=6)
        lash(m, (x, hd, H - 0.5), (x, hd, H), 0.32)
    log(m, (-hl - 0.6, hd, H), (hl + 0.6, hd, H), 0.3, n=6)
    for x in (-hl, hl):
        log(m, (x, -hd, 0), (x, -hd, H + 1.4), 0.32, n=6)
    rise = 1.4
    ang = math.degrees(math.atan2(rise, D + 2.4))
    for k in range(6):  # pent roof, high at the back
        y = -hd - 0.8 + (k + 0.5) * (D + 2.4) / 6
        z = H + 1.4 - (y + hd + 0.8) / (D + 2.4) * rise + 0.3
        box(cut, (0, y, z), (L + 2.0, (D + 2.4) / 6 * 1.3, 0.28), "plank", r=(-ang - 3, 0, random.uniform(-0.5, 0.5)))
    fx, fy = -hl + 2.2, -hd + 2.2
    box(m, (fx, fy, 1.4), (3.2, 3.0, 1.6), "stone")
    box(m, (fx, fy, 2.25), (2.4, 2.2, 0.15), "char")
    lathe(ex["ember"], (fx, fy, 2.3), [(0.8, 0), (0.3, 0.4)], "ember", n=6)
    lathe(m, (fx, fy, 3.4), [(1.5, 0), (0.6, 1.6)], "brick", n=8, close_top=False)
    box(m, (fx, fy, 6.2), (1.0, 1.0, 2.6), "brick")
    box(cut, (fx, fy, H + 2.6), (1.1, 1.1, 2.6), "brick")
    lathe(m, (-0.8, -0.3, 0.7), [(0.7, 0), (0.75, 1.0), (0.7, 1.4)], "log", n=8)  # anvil stump
    box(m, (-0.8, -0.3, 2.35), (1.6, 0.6, 0.5), "metal")
    box(m, (0.1, -0.3, 2.5), (0.6, 0.35, 0.22), "metal")
    lathe(m, (-hl + 4.8, -hd + 1.2, 0.7), [(0.7, 0), (0.8, 0.8), (0.7, 1.5)], "plank", n=9)  # quench barrel
    lathe(m, (-hl + 4.8, -hd + 1.2, 2.15), [(0.6, 0)], "slate", n=8)
    box(m, (3.0, -hd + 1.3, 2.4), (6.0, 1.8, 0.25), "plank")
    for x in (0.4, 5.6):
        box(m, (x, -hd + 1.3, 1.5), (0.3, 1.5, 1.6), "log")
    box(walls, (3.0, -hd + 0.45, 4.4), (5.4, 0.15, 1.8), "plank")  # tool wall
    for i in range(5):
        box(walls, (0.8 + i * 1.1, -hd + 0.6, 4.3), (0.15, 0.2, 1.3), "metal")
    for k in range(4):  # timber rack
        log(m, (hl - 1.2, -hd + 1.0, 1.0 + k * 0.45), (hl - 1.2, hd - 2.0, 1.0 + k * 0.45), 0.2, n=5)
    for y in (-hd + 1.0, hd - 2.0):
        box(m, (hl - 1.2, y, 1.2), (0.25, 0.25, 2.4), "log")
    box(m, (hl / 3, hd + 0.35, H - 0.6), (0.12, 0.7, 0.12), "metal")
    box(m, (hl / 3, hd + 0.7, H - 1.2), (0.5, 0.5, 0.7), "metal")
    box(lamp, (hl / 3, hd + 0.7, H - 1.2), (0.38, 0.52, 0.5), "ember")
    crate(m, (hl + 1.6, hd - 0.6, 0.8), 1.6, 12)
    crate(m, (hl + 1.5, hd - 2.4, 0.75), 1.5, -6)


def plot_fence(m, cut, ex):
    """8-stud plot fence segment along X (tiles end to end): two posts, two split rails and a row
    of sharpened pickets (R12-1)."""
    for x in (-4.0, 4.0):
        log(m, (x, 0, 0), (x, 0, 3.4), 0.24, n=6)
        lathe(m, (x, 0, 3.4), [(0.24, 0), (0.0, 0.55)], "log", n=6)
        lash(m, (x, 0, 2.6), (x, 0, 3.0), 0.24)
    for z in (1.3, 2.6):
        log(m, (-4.25, 0.05, z), (4.25, 0.05, z + random.uniform(-0.12, 0.12)), 0.15, n=5)
    for i in range(7):
        x = -3.4 + i * (6.8 / 6)
        h = random.uniform(1.7, 2.2)
        lean = random.uniform(0.15, 0.3)
        cyl(m, (x, 0.25, 0), (x, 0.25 + lean, h), 0.13, 0.1, "log", n=5, cap=False)
        lathe(m, (x, 0.25 + lean, h), [(0.1, 0), (0.0, 0.35)], "log", n=5)


def plot_fence_corner(m, cut, ex):
    """Corner post for plot fences: a taller post with a stone collar and a lashed cap."""
    log(m, (0, 0, 0), (0, 0, 4.2), 0.32, n=7)
    lathe(m, (0, 0, 4.2), [(0.32, 0), (0.0, 0.6)], "log", n=7)
    lash(m, (0, 0, 3.2), (0, 0, 3.6), 0.32)
    for i in range(5):
        a = i * 2 * math.pi / 5
        rock(m, (math.cos(a) * 0.6, math.sin(a) * 0.6, 0), 0.6, "stone", n=5)


def plot_gate(m, cut, ex):
    """12-stud plot gateway along X: tall posts, lintel with a hanging claim board (__tag), two
    leaves swung open toward Blender +Y (Roblox -Z, into the plot)."""
    W = 12.0
    for x in (-W / 2, W / 2):
        log(m, (x, 0, 0), (x, 0, 6.2), 0.34, n=7)
        lathe(m, (x, 0, 6.2), [(0.34, 0), (0.0, 0.6)], "log", n=7)
        log(m, (x, -1.3, 0), (x, 0, 2.6), 0.14, n=5)
        rock(m, (x, 0, 0), 1.0, "stone", n=5)
        lash(m, (x, 0, 5.4), (x, 0, 5.8), 0.34)
    log(m, (-W / 2 - 0.8, 0, 5.5), (W / 2 + 0.8, 0, 5.5), 0.26, n=6)
    for x in (-1.4, 1.4):
        cyl(m, (x, 0, 5.3), (x, 0, 4.75), 0.04, 0.04, "rope", n=4, cap=False)
    box(m, (0, 0, 4.25), (3.6, 0.2, 1.0), "plank")
    sheet(ex["tag"], (1.5, -0.13, 3.9), (-1.5, -0.13, 3.9), (1.5, -0.13, 4.6), 2, 1, "teal", both=False)
    for side in (-1, 1):
        hinge = Vector((side * (W / 2 - 0.4), 0, 0))
        dirv = Vector((-side * math.cos(math.radians(70)), math.sin(math.radians(70)), 0))
        leaf = W / 2 - 0.6
        for z in (0.9, 2.9):
            a = hinge + Vector((0, 0, z))
            log(m, a, a + dirv * leaf, 0.13, n=5)
        for k in range(4):
            p = hinge + dirv * (0.4 + k * (leaf - 0.6) / 3)
            log(m, p + Vector((0, 0, 0.3)), p + Vector((0, 0, 3.4)), 0.12, n=5)
        log(m, hinge + Vector((0, 0, 0.9)), hinge + dirv * leaf + Vector((0, 0, 2.9)), 0.1, n=4)


def opening_stake(m, cut, ex):
    """Survey stake for the opening (replaces the Part peg + cap + lashing + guy line): squared
    peg with a split top, rope lashing, a teal cloth strip (__tag) and a guy line to a ground peg
    toward Blender -Y (Roblox +Z). Pivot: ground at the peg."""
    box(m, (0, 0, 1.1), (0.5, 0.5, 2.2), "log", r=(0, 0, 12))
    for s in (-1, 1):
        box(m, (s * 0.13, 0, 2.45), (0.22, 0.48, 0.5), "log", r=(0, s * 8, 12))
    cyl(m, (0, 0, 1.75), (0, 0, 2.05), 0.36, 0.36, "rope", n=7)
    sheet(ex["tag"], (0.25, 0.05, 1.55), (0.95, 0.35, 1.3), (0.25, 0.05, 2.0), 2, 1, "teal")
    cyl(m, (0, -0.1, 1.9), (0, -1.9, 0.15), 0.04, 0.04, "rope", n=4, cap=False)
    box(m, (0, -1.95, 0.2), (0.16, 0.16, 0.6), "log", r=(-20, 0, 0))
    for i in range(4):
        rock(m, (math.cos(i * 1.6) * 0.6, math.sin(i * 1.6) * 0.6, 0), 0.35, "stone", n=4)


def opening_mirror(m, cut, ex):
    """Heliograph mirror on a lashed tripod (replaces the Glass block). The disc faces Blender -Y
    (Roblox +Z), tilted up 15 deg; the pane is __glow. Pivot: tripod centre on the ground."""
    top = Vector((0, 0, 3.2))
    for i in range(3):
        a = i * 2 * math.pi / 3 + math.pi / 2
        log(m, (math.cos(a) * 1.3, math.sin(a) * 1.3, 0), top, 0.1, n=5)
    lash(m, top - Vector((0, 0, 0.3)), top, 0.12)
    for s in (-1, 1):  # yoke
        box(m, (s * 0.88, 0, 3.6), (0.12, 0.2, 0.9), "log")
    box(m, (0, 0, 3.2), (1.9, 0.2, 0.15), "log")
    centre = Vector((0, 0, 3.9))
    tilt = math.radians(15)
    nrm = Vector((0, -math.cos(tilt), math.sin(tilt)))
    up = Vector((0, math.sin(tilt), math.cos(tilt)))
    side = Vector((1, 0, 0))
    R, n = 0.8, 12
    circle = [(side * math.cos(k * 2 * math.pi / n) + up * math.sin(k * 2 * math.pi / n)) for k in range(n)]
    rim = [centre + c * R for c in circle]
    back = [p - nrm * 0.12 for p in rim]
    for k in range(n):
        j = (k + 1) % n
        m.face([rim[k], rim[j], back[j], back[k]], "metal", center=centre - nrm * 0.06)
    m.face(list(back), "metal", center=centre)
    m.face(list(rim), "metal", center=centre - nrm)  # backing behind the pane
    ex["glow"].face([centre + nrm * 0.03 + c * (R - 0.12) for c in circle], "glow", center=centre - nrm)
    box(m, (0.9, -0.3, 0.25), (0.6, 0.4, 0.5), "plank")  # sighting box at the foot


def clan_hall_v2(m, cut, ex):
    """Clan hall v2 (L5): 36 x 22 log hall, 21 studs to the ridge, carved door posts, a central
    hearth, clan banners (__tag). Walls and roof both sit in __cut so the live G24 cut-away
    (StructureMeshes tags __cut) fades the whole shell when a player walks in."""
    house(m, cut, ex, 36.0, 22.0, 8.0, 11.0, "thatch", "log", chimney=None, porch=True, courses=6, thick=0.7,
          logs=True, long=True, walls_mb=cut)
    hd = 11.0
    for x in (-3.4, 3.4):  # carved door posts with a crossbeam
        log(m, (x, hd + 3.6, 0), (x, hd + 3.6, 9.0), 0.5, n=8)
        for z in (2.5, 5.0, 7.5):
            lathe(m, (x, hd + 3.6, z), [(0.62, 0), (0.7, 0.35), (0.55, 0.7)], "char", n=8)
        lathe(m, (x, hd + 3.6, 9.0), [(0.5, 0), (0.0, 0.9)], "log", n=8)
    log(m, (-4.6, hd + 3.6, 8.4), (4.6, hd + 3.6, 8.4), 0.35, n=6)
    for x in (-1.2, 1.2):  # horn pair on the crossbeam
        cyl(m, (x, hd + 3.6, 8.7), (x * 1.9, hd + 3.6, 10.0), 0.2, 0.04, "clay", n=5)
    lathe(m, (0, 0, 1.1), [(1.8, 0), (1.9, 0.5), (1.6, 0.6)], "stone", n=10)  # hearth
    lathe(ex["ember"], (0, 0, 1.6), [(1.0, 0), (0.4, 0.5)], "ember", n=8)
    for i in range(2):  # long tables either side of the hearth
        y = -4.0 + i * 8.0
        box(m, (8.0, y, 2.2), (12.0, 2.0, 0.25), "plank")
        box(m, (-8.0, y, 2.2), (8.0, 2.0, 0.25), "plank")
        for x in (3.0, 13.0, -11.0, -5.0):
            box(m, (x, y, 1.6), (0.3, 1.6, 1.2), "log")
    for x in (-21.0, 21.0):  # banner poles
        log(m, (x, hd + 2.0, 0), (x, hd + 2.0, 15.0), 0.24, n=6)
        log(m, (x, hd + 2.0, 14.4), (x + (-3.0 if x > 0 else 3.0), hd + 2.0, 14.4), 0.1, n=5)
        x0, x1 = (x + 0.2, x + 3.0) if x < 0 else (x - 3.0, x - 0.2)
        sheet(ex["tag"], (x0, hd + 2.0, 8.6), (x1, hd + 2.0, 8.6), (x0, hd + 2.0, 14.2), 3, 5, "teal", noise=0.06)
        rock(m, (x, hd + 2.0, 0), 1.4, "stone")
    for i in range(3):  # entrance steps
        box(m, (0, hd + 4.8 + i * 0.8, 0.75 - i * 0.25), (6.0, 0.9, 0.3), "stone")


def rift_v2(m, cut, ex):
    """Rift v2 (L5): a ground fissure, not a standing gate. A raised broken stone lip (a mound
    of tumbled blocks and two tilted monolith shards) around a dark cleft; the cleft walls are
    char rock and its floor glows (__glow); a slow shard halo (__halo) floats above. Nothing sits
    below y=0, so it works on uncarved terrain. Footprint ~24 x 16, tallest shard ~9 studs."""
    # fissure plan: a jagged lens along X
    n = 14
    left, right = [], []
    for k in range(n + 1):
        t = k / n
        x = -8.5 + t * 17.0
        w = 2.4 * math.sin(math.pi * t) ** 0.8 + 0.15
        wob = random.uniform(-0.35, 0.35)
        left.append((x, -w + wob))
        right.append((x, w + wob))
    depth = 0.15
    rim = 2.0
    for k in range(n):  # cleft walls (inner faces, dark rock), sloping in toward the glow
        for edge, sgn in ((left, -1), (right, 1)):
            (x0, y0), (x1, y1) = edge[k], edge[k + 1]
            q = [(x0, y0, rim), (x1, y1, rim), (x1, y1 * 0.35, depth), (x0, y0 * 0.35, depth)]
            m.face(q, "char", center=(0.5 * (x0 + x1), -sgn * 8.0, rim))
    floor = []  # glowing floor strip
    for k in range(n):
        (x0, l0), (x1, l1) = left[k], left[k + 1]
        r0, r1 = right[k][1], right[k + 1][1]
        q = [(x0, l0 * 0.35, depth + 0.05), (x1, l1 * 0.35, depth + 0.05), (x1, r1 * 0.35, depth + 0.05),
             (x0, r0 * 0.35, depth + 0.05)]
        ex["glow"].face(q, "glow", center=(0.5 * (x0 + x1), 0.0, depth - 2.0))
    for k in range(n):  # dark floor under the glow (closes the cleft from below)
        (x0, l0), (x1, l1) = left[k], left[k + 1]
        r0, r1 = right[k][1], right[k + 1][1]
        m.face([(x0, l0 * 0.35, depth), (x1, l1 * 0.35, depth), (x1, r1 * 0.35, depth), (x0, r0 * 0.35, depth)],
               "char", center=(0.5 * (x0 + x1), 0.0, depth + 2.0))
    for k in range(1, n, 2):  # glowing veins running up the walls
        for edge in (left, right):
            x, y = edge[k]
            f = 0.9  # just inside the wall surface
            ex["glow"].face([(x - 0.12, y * f, rim - 0.4), (x + 0.12, y * f, rim - 0.4), (x + 0.1, y * 0.42, depth + 0.3),
                             (x - 0.1, y * 0.42, depth + 0.3)], "glow", center=(x, y * 3.0, rim))
    # stone lip: ground skirt + tumbled blocks hugging the edge
    for edge, sgn in ((left, -1), (right, 1)):
        for k in range(n):
            (x0, y0), (x1, y1) = edge[k], edge[k + 1]
            q = [(x0, y0, rim), (x1, y1, rim), (x1 * 1.08, y1 + sgn * 3.4, 0.0), (x0 * 1.08, y0 + sgn * 3.4, 0.0)]
            m.face(q, "stone", center=(0.5 * (x0 + x1), y0 - sgn * 1.0, -2.0))
        for k in range(0, n + 1, 1):
            x, y = edge[k]
            s = random.uniform(1.0, 1.9) * (0.6 + 0.6 * math.sin(math.pi * k / n))
            rock(m, (x + random.uniform(-0.4, 0.4), y + sgn * (0.9 + s * 0.4), rim * 0.55), max(s, 0.8), "stone", n=6)
    for x in (-9.6, 9.6):  # cleft ends
        rock(m, (x, 0, 0), 2.6, "stone", n=6)
    # two tilted monolith shards leaning over the cleft (silhouette at the town camera)
    for (x, y, h, lean, yaw) in ((-3.2, -3.4, 9.0, 18, 10), (4.4, 3.2, 6.5, -22, -14)):
        base = Vector((x, y, 0))
        R = rot((lean, 0, yaw))
        prof = [(1.3, 0.0), (1.2, h * 0.35), (0.85, h * 0.7), (0.15, h)]
        rings = []
        for r, z in prof:
            ring_pts = []
            for i in range(5):
                a = i * 2 * math.pi / 5 + 0.3
                rr = r * random.uniform(0.85, 1.15)
                ring_pts.append(base + R @ Vector((math.cos(a) * rr, math.sin(a) * rr * 0.7, z)))
            rings.append(ring_pts)
        c = base + R @ Vector((0, 0, h * 0.4))
        for kk in range(len(rings) - 1):
            for i in range(5):
                j = (i + 1) % 5
                m.face([rings[kk][i], rings[kk][j], rings[kk + 1][j], rings[kk + 1][i]], "stone", center=c)
        m.face(list(reversed(rings[0])), "stone", center=c)
        m.face(rings[-1], "stone", center=c)
        for kk in (1, 2):  # glowing crack up the inner face of each shard
            p0 = base + R @ Vector((0, -0.75 * prof[kk - 1][0] * 0.7, prof[kk - 1][1] + 0.3))
            p1 = base + R @ Vector((0, -0.75 * prof[kk][0] * 0.7, prof[kk][1]))
            side = R @ Vector((0.12, 0, 0))
            d = (p1 - p0).normalized()
            out = R @ Vector((0, -1, 0))
            ex["glow"].face([p0 - side + out * 0.25, p0 + side + out * 0.25, p1 + side + out * 0.25,
                             p1 - side + out * 0.25], "glow", center=p0 - out)
    for i in range(8):  # shard halo (rotated at runtime)
        a = i * 2 * math.pi / 8
        c = (math.cos(a) * 5.5, math.sin(a) * 3.0, 6.5 + math.sin(a * 2) * 1.0)
        lathe(ex["halo"], c, [(0.3, -0.6), (0.35, 0), (0.0, 0.8)], "seaglass", n=4)


# ---------------------------------------------------------------- rows table
# key, builder, package, tri budget
ROWS = [
    ("bld.campfire", campfire, "RobangoBldA", 1200),
    ("bld.workbench.t1", workbench_t1, "RobangoBldA", 1800),
    ("bld.workbench.t2", workbench_t2, "RobangoBldA", 2200),
    ("bld.workbench.t3", workbench_t3, "RobangoBldA", 2800),
    ("bld.tanning-frame", tanning_frame, "RobangoBldA", 1000),
    ("bld.joiner-bench", joiner_bench, "RobangoBldA", 2000),
    ("bld.clan-hall", clan_hall_v2, "RobangoBldA", 9000),
    ("bld.animal-pen", animal_pen, "RobangoBldA", 1400),
    ("bld.storage", storage, "RobangoBldA", 600),
    ("bld.timber.floor", timber_floor, "RobangoBldA", 250),
    ("bld.timber.wall", timber_wall, "RobangoBldA", 400),
    ("bld.timber.roof", timber_roof, "RobangoBldA", 500),
    ("bld.timber.door", timber_door, "RobangoBldA", 450),
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
    ("town.rift-ring", rift_v2, "RobangoHero", 3500),
    ("town.house.cottage-a", cottage_a, "RobangoHero", 5000),
    ("town.house.cottage-b", cottage_b, "RobangoHero", 5000),
    ("town.house.cottage-c", cottage_c, "RobangoHero", 5000),
    ("town.house.longhouse", longhouse, "RobangoHero", 7000),
    ("town.house.workshop", workshop, "RobangoHero", 5000),
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
    ("town.plot-fence", plot_fence, "RobangoTownKit", 600),
    ("town.plot-fence-corner", plot_fence_corner, "RobangoTownKit", 300),
    ("town.plot-gate", plot_gate, "RobangoTownKit", 900),
    ("opening.stake", opening_stake, "RobangoTownKit", 400),
    ("opening.mirror", opening_mirror, "RobangoTownKit", 500),
]
SUFFIXES = ("cut", "wall", "ember", "glow", "lamp", "tag", "halo")



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
