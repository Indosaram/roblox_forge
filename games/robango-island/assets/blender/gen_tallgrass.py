"""Tall-grass card cluster pilot: ~60 tapered geometric blades (no alpha needed), head height."""

import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
from mathutils import Vector

import common as C

SEED = 4104
NAME = "RobangoTallGrass"


def build():
    bm = bmesh.new()
    blades = 64
    for b in range(blades):
        r = 0.7 * math.sqrt(random.random())
        a = random.uniform(0, 2 * math.pi)
        base = Vector((math.cos(a) * r, math.sin(a) * r, 0))
        h = random.uniform(1.4, 2.4)  # head height for a ~1.8 m character
        lean_dir = Vector((math.cos(a), math.sin(a), 0)) * random.uniform(0.2, 0.7) + Vector(
            (random.uniform(-0.3, 0.3), random.uniform(-0.3, 0.3), 0)
        )
        steps = 5
        pts = []
        for s in range(steps + 1):
            u = s / steps
            pts.append(base + lean_dir * (u * u) * h * 0.45 + Vector((0, 0, h * u * (1 - 0.18 * u * u))))
        w = random.uniform(0.025, 0.04)
        C.strip(bm, pts, [w * (1 - u / steps) + 0.002 for u in range(steps + 1)], normal_twist=0.0)
    obj = C.mesh_object(NAME, bm)
    C.finish_mesh(obj)
    return obj


def grass(nodes, links):
    coord = nodes.new("ShaderNodeTexCoord").outputs["Object"]
    sep = nodes.new("ShaderNodeSeparateXYZ")
    links.new(coord, sep.inputs["Vector"])
    n = C.noise(nodes, 2.5, 4, 0.5, coord, links)
    add = nodes.new("ShaderNodeMath")
    add.operation = "MULTIPLY_ADD"
    links.new(sep.outputs["Z"], add.inputs[0])
    add.inputs[1].default_value = 0.35
    links.new(n.outputs["Fac"], add.inputs[2])
    # Olive base -> dry straw tips (R03-3 / R11-1 palette).
    col = C.ramp(
        nodes,
        links,
        add.outputs["Value"],
        [(0.3, (0.16, 0.19, 0.08)), (0.75, (0.36, 0.38, 0.17)), (1.1, (0.62, 0.55, 0.32))],
    )
    return col.outputs["Color"], None, None


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    obj = build()
    obj.data.materials.append(C.material("grass", grass))
    C.unwrap(obj, 0.004)
    sil = C.silhouette(NAME, outdir, [obj])
    maps = C.bake(obj, NAME, outdir, size=512, passes=("albedo",))
    pv = C.preview(NAME, outdir, [obj])
    fbx = C.export_fbx(NAME, outdir, [obj])
    C.report(NAME, [obj], {"fbx": fbx, "preview": pv, "silhouettes": sil, **maps}, {"seed": SEED})


main()
