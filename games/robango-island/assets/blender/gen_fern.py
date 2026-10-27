"""Fern clump pilot: ~14 arching pinnate fronds from a shared crown."""

import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
from mathutils import Vector

import common as C

SEED = 4103
NAME = "RobangoFern"


def build():
    bm = bmesh.new()
    count = 14
    for f in range(count):
        yaw = 2 * math.pi * f / count + random.uniform(-0.25, 0.25)
        pitch = random.uniform(0.7, 1.25)
        length = random.uniform(1.1, 1.7)
        d = Vector((math.cos(yaw), math.sin(yaw), 0))
        steps = 9
        pts = []
        for s in range(steps + 1):
            u = s / steps
            z = math.sin(pitch) * length * u - 1.1 * u * u * length * 0.8
            pts.append(d * (math.cos(pitch) * length * u + 0.05) + Vector((0, 0, z)))
        C.strip(bm, pts, [0.015] * (steps + 1))
        side = d.cross(Vector((0, 0, 1))).normalized()
        for s in range(1, steps):
            u = s / steps
            ll = 0.32 * math.sin(math.pi * (0.15 + 0.85 * u)) + 0.04
            for sgn in (-1, 1):
                tipdir = (side * sgn + d * 0.45 + Vector((0, 0, -0.15))).normalized()
                lp = [pts[s] + tipdir * ll * q for q in (0.0, 0.5, 1.0)]
                C.strip(bm, lp, [0.045, 0.05, 0.008], normal_twist=0.7)
    obj = C.mesh_object(NAME, bm)
    C.finish_mesh(obj)
    return obj


def leaf(nodes, links):
    coord = nodes.new("ShaderNodeTexCoord").outputs["Object"]
    n = C.noise(nodes, 5.0, 6, 0.6, coord, links)
    # Darker toward the crown, sun-bleached at the tips (matches R03-3 fern tone).
    grad = nodes.new("ShaderNodeVectorMath")
    grad.operation = "LENGTH"
    links.new(coord, grad.inputs[0])
    add = nodes.new("ShaderNodeMath")
    add.operation = "ADD"
    links.new(grad.outputs["Value"], add.inputs[0])
    links.new(n.outputs["Fac"], add.inputs[1])
    col = C.ramp(
        nodes,
        links,
        add.outputs["Value"],
        [(0.4, (0.10, 0.15, 0.06)), (1.0, (0.24, 0.32, 0.12)), (1.7, (0.46, 0.48, 0.22))],
    )
    return col.outputs["Color"], None, None


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    obj = build()
    obj.data.materials.append(C.material("fern", leaf))
    C.unwrap(obj, 0.004)
    sil = C.silhouette(NAME, outdir, [obj])
    maps = C.bake(obj, NAME, outdir, size=512, passes=("albedo",))
    pv = C.preview(NAME, outdir, [obj])
    fbx = C.export_fbx(NAME, outdir, [obj])
    C.report(NAME, [obj], {"fbx": fbx, "preview": pv, "silhouettes": sil, **maps}, {"seed": SEED})


main()
