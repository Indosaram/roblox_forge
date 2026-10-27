"""Palm pilot: curved segmented trunk + drooping pinnate fronds (alpha-free leaflet strips)."""

import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
from mathutils import Matrix, Vector

import common as C

SEED = 4101
NAME = "RobangoPalm"
HEIGHT = 7.0


def trunk_curve(t):
    # Gentle S lean so the palm does not read as a pole.
    return Vector((0.9 * math.sin(t * 1.4) * t, 0.25 * t * t, HEIGHT * t))


def build_trunk():
    bm = bmesh.new()
    rings = 18
    sides = 9
    prev = None
    first = None
    for i in range(rings + 1):
        t = i / rings
        c = trunk_curve(t)
        r = 0.32 * (1 - 0.45 * t) + 0.04 * (1 if i % 2 == 0 else 0)  # ring bumps
        if i == 0:
            r = 0.48
        ring = []
        for k in range(sides):
            a = 2 * math.pi * k / sides
            ring.append(bm.verts.new(c + Vector((math.cos(a) * r, math.sin(a) * r, 0))))
        if prev:
            for k in range(sides):
                bm.faces.new((prev[k], prev[(k + 1) % sides], ring[(k + 1) % sides], ring[k]))
        else:
            first = ring
        prev = ring
    bm.faces.new(list(reversed(first)))
    bm.faces.new(prev)
    obj = C.mesh_object("trunk", bm)
    C.finish_mesh(obj)
    return obj


def build_fronds():
    bm = bmesh.new()
    top = trunk_curve(1.0)
    count = 13
    for f in range(count):
        yaw = 2 * math.pi * f / count + random.uniform(-0.15, 0.15)
        pitch = random.uniform(0.15, 0.75)  # upward start angle
        length = random.uniform(3.2, 4.3)
        d = Vector((math.cos(yaw), math.sin(yaw), 0))
        pts = []
        steps = 10
        for s in range(steps + 1):
            u = s / steps
            # Parabolic droop.
            z = math.sin(pitch) * length * u - 1.9 * (u**2) * length / 4
            pts.append(top + d * (math.cos(pitch) * length * u) + Vector((0, 0, z)))
        rachis_w = [0.05 * (1 - 0.8 * s / steps) for s in range(steps + 1)]
        C.strip(bm, pts, rachis_w)
        side = d.cross(Vector((0, 0, 1))).normalized()
        # Leaflets: pairs along the rachis, hanging down and out.
        for s in range(1, steps):
            u = s / steps
            base = pts[s]
            ll = 0.95 * math.sin(math.pi * min(1.0, u * 1.1)) + 0.15
            for sgn in (-1, 1):
                tipdir = (side * sgn * 0.85 + d * 0.35 + Vector((0, 0, -0.55))).normalized()
                lp = [base + tipdir * ll * q for q in (0.0, 0.33, 0.66, 1.0)]
                lp[1].z -= 0.04
                lp[2].z -= 0.10
                C.strip(bm, lp, [0.07, 0.09, 0.07, 0.01], normal_twist=0.6)
    obj = C.mesh_object("fronds", bm)
    C.finish_mesh(obj)
    return obj


def bark(nodes, links):
    coord = nodes.new("ShaderNodeTexCoord").outputs["Object"]
    sep = nodes.new("ShaderNodeSeparateXYZ")
    links.new(coord, sep.inputs["Vector"])
    rings = nodes.new("ShaderNodeMath")
    rings.operation = "SINE"
    sc = nodes.new("ShaderNodeMath")
    sc.operation = "MULTIPLY"
    sc.inputs[1].default_value = 9.0
    links.new(sep.outputs["Z"], sc.inputs[0])
    links.new(sc.outputs["Value"], rings.inputs[0])
    n = C.noise(nodes, 6.0, 8, 0.7, coord, links)
    add = nodes.new("ShaderNodeMath")
    add.operation = "ADD"
    links.new(rings.outputs["Value"], add.inputs[0])
    links.new(n.outputs["Fac"], add.inputs[1])
    col = C.ramp(
        nodes,
        links,
        add.outputs["Value"],
        [(0.0, (0.20, 0.16, 0.11)), (0.6, (0.42, 0.35, 0.25)), (1.3, (0.58, 0.51, 0.40))],
    )
    return col.outputs["Color"], None, C.bump(nodes, links, add.outputs["Value"], 0.5)


def leaf(nodes, links):
    coord = nodes.new("ShaderNodeTexCoord").outputs["Object"]
    n = C.noise(nodes, 3.0, 5, 0.6, coord, links)
    col = C.ramp(
        nodes,
        links,
        n.outputs["Fac"],
        [(0.3, (0.20, 0.25, 0.10)), (0.55, (0.33, 0.37, 0.15)), (0.75, (0.50, 0.46, 0.24))],
    )
    return col.outputs["Color"], None, None


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    trunk = build_trunk()
    trunk.data.materials.append(C.material("bark", bark))
    fronds = build_fronds()
    fronds.data.materials.append(C.material("leaf", leaf))
    obj = C.join([trunk, fronds], NAME)
    C.unwrap(obj, 0.004)
    sil = C.silhouette(NAME, outdir, [obj])
    maps = C.bake(obj, NAME, outdir, size=1024, passes=("albedo", "normal"))
    pv = C.preview(NAME, outdir, [obj])
    fbx = C.export_fbx(NAME, outdir, [obj])
    C.report(NAME, [obj], {"fbx": fbx, "preview": pv, "silhouettes": sil, **maps}, {"seed": SEED})


main()
