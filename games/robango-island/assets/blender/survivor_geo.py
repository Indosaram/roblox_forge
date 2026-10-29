"""L6 survivor geometry helpers (used by gen_survivors.py).

Coordinates are Roblox rig space: X right, Y up, Z back (the character faces -Z), the
HumanoidRootPart centre at the origin. `bv()` converts to Blender (X, -Z, Y); the FBX exporter's
default axes turn that back into Roblox axes.
"""

import math

from mathutils import Vector


def bv(p):
    return Vector((p[0], -p[2], p[1]))


def rv(v):
    return (v.x, v.z, -v.y)


def face(bm, verts, inside, tile, layer):
    f = bm.faces.new(verts)
    f.normal_update()
    if f.normal.dot(f.calc_center_median() - inside) < 0:
        f.normal_flip()
    if layer is not None:
        f[layer] = tile(rv(f.calc_center_median())) if callable(tile) else tile
    f.smooth = True
    return f


def ring(y, rx, rz, cx=0.0, cz=0.0, n=16, p=2.0):
    e = 2.0 / p
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n
        c, s = math.cos(a), math.sin(a)
        pts.append((cx + rx * math.copysign(abs(c) ** e, c), y, cz + rz * math.copysign(abs(s) ** e, s)))
    return pts


def dense(sections, step):
    """Linear resample of (y, rx, rz, cx, cz) sections so no gap exceeds `step` (keeps colour borders crisp)."""
    out = [sections[0]]
    for a, b in zip(sections, sections[1:]):
        k = max(1, int(math.ceil(abs(b[0] - a[0]) / step)))
        for i in range(1, k + 1):
            t = i / k
            out.append(tuple(a[j] + (b[j] - a[j]) * t for j in range(5)))
    return out


def loft(bm, layer, rings, tile=-1, cap0=True, cap1=True):
    """Closed rings (lists of rig points, same length) joined into a tube with optional caps."""
    vs = [[bm.verts.new(bv(p)) for p in r] for r in rings]
    cents = [sum((v.co for v in r), Vector()) / len(r) for r in vs]
    n = len(vs[0])
    for k in range(len(vs) - 1):
        inside = (cents[k] + cents[k + 1]) / 2
        for i in range(n):
            j = (i + 1) % n
            face(bm, (vs[k][i], vs[k][j], vs[k + 1][j], vs[k + 1][i]), inside, tile, layer)
    for idx, nb, on in ((0, 1, cap0), (len(vs) - 1, len(vs) - 2, cap1)):
        if not on:
            continue
        c = bm.verts.new(cents[idx])
        inside = cents[nb]
        for i in range(n):
            face(bm, (vs[idx][i], vs[idx][(i + 1) % n], c), inside, tile, layer)


def ellipsoid(bm, layer, center, radii, tile=-1, nlat=10, nlon=16, deform=None, keep=None):
    """UV ellipsoid; `deform(p)` reshapes rig points, `keep(p)` filters faces by centre (open shells)."""
    cx, cy, cz = center
    grid = []
    for i in range(nlat + 1):
        th = math.pi * i / nlat
        row = []
        for j in range(nlon):
            ph = 2 * math.pi * j / nlon
            p = (cx + radii[0] * math.sin(th) * math.cos(ph), cy + radii[1] * math.cos(th),
                 cz + radii[2] * math.sin(th) * math.sin(ph))
            row.append(deform(p) if deform else p)
        grid.append(row)
    inside = bv(center)
    cache = {}

    def vert(i, j):
        key = (i, 0) if i in (0, nlat) else (i, j % nlon)
        if key not in cache:
            cache[key] = bm.verts.new(bv(grid[key[0]][key[1]]))
        return cache[key]

    for i in range(nlat):
        for j in range(nlon):
            if i == 0:
                quad = [vert(0, 0), vert(1, j + 1), vert(1, j)]
            elif i == nlat - 1:
                quad = [vert(i, j), vert(i, j + 1), vert(nlat, 0)]
            else:
                quad = [vert(i, j), vert(i, j + 1), vert(i + 1, j + 1), vert(i + 1, j)]
            if keep:
                c = sum((v.co for v in quad), Vector()) / len(quad)
                if not keep(rv(c)):
                    continue
            face(bm, quad, inside, tile, layer)
    for v in list(cache.values()):
        if not v.link_faces:
            bm.verts.remove(v)


def torus(bm, layer, y, rx, rz, r, tile, cx=0.0, cz=0.0, n=20, m=6, dy=0.0):
    """Horizontal roll (collar, cuff, belt, hem): tube of radius r around an ellipse at height y."""
    rows = []
    centres = []
    for i in range(n):
        a = 2 * math.pi * i / n
        ox, oz = math.cos(a), math.sin(a)
        c = (cx + rx * ox, y + dy * oz, cz + rz * oz)
        centres.append(bv(c))
        row = []
        for k in range(m):
            b = 2 * math.pi * k / m
            row.append(bm.verts.new(bv((c[0] + r * math.cos(b) * ox, c[1] + r * math.sin(b),
                                        c[2] + r * math.cos(b) * oz))))
        rows.append(row)
    for i in range(n):
        i2 = (i + 1) % n
        inside = (centres[i] + centres[i2]) / 2
        for k in range(m):
            k2 = (k + 1) % m
            face(bm, (rows[i][k], rows[i][k2], rows[i2][k2], rows[i2][k]), inside, tile, layer)
