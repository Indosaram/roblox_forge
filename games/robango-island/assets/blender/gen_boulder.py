"""Boulder pilot: displaced icosphere, weathered ochre-grey stone with moss on top faces."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
from mathutils import Vector, noise as mnoise

import common as C

SEED = 4102
NAME = "RobangoBoulderProc"


def build():
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=4, radius=1.0)
    off = Vector((SEED * 0.013, 3.1, 7.7))
    for v in bm.verts:
        p = v.co
        # Low-frequency mass only (A2 spikes came from high-freq noise + collapse decimation).
        d = 1.0 + 0.22 * mnoise.fractal(p * 0.7 + off, 0.5, 2.0, 3)
        q = p * d
        q.x *= 1.4
        q.y *= 1.1
        q.z *= 0.72
        # Flat, slightly tilted top (R11-1/R11-8 field stones) and a flat base.
        top = 0.42 + 0.08 * q.x
        if q.z > top:
            q.z = top + (q.z - top) * 0.18
        if q.z < -0.3:
            q.z = -0.3 + (q.z + 0.3) * 0.2
        # Horizontal strata steps on the flanks.
        band = math.floor((q.z + 0.3) / 0.17)
        q.x *= 1.0 - 0.025 * (band % 2)
        q.y *= 1.0 - 0.025 * (band % 2)
        v.co = q
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    obj = C.mesh_object(NAME, bm)
    obj.scale = (1.6, 1.6, 1.6)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    C.finish_mesh(obj)
    return obj


def stone(nodes, links):
    coord = nodes.new("ShaderNodeTexCoord").outputs["Object"]
    big = C.noise(nodes, 1.6, 8, 0.65, coord, links)
    fine = C.noise(nodes, 14.0, 10, 0.7, coord, links)
    rock = C.ramp(
        nodes,
        links,
        big.outputs["Fac"],
        [(0.30, C.hexlin("rock_dark")), (0.50, C.hexlin("rock_mid")), (0.70, C.hexlin("rock_light"))],
    )
    grain = C.ramp(nodes, links, fine.outputs["Fac"], [(0.35, (0.55, 0.52, 0.48)), (0.65, (1.0, 1.0, 1.0))])
    mul = nodes.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    mul.inputs["Factor"].default_value = 1.0
    links.new(rock.outputs["Color"], mul.inputs["A"])
    links.new(grain.outputs["Color"], mul.inputs["B"])
    # Moss on upward faces, broken up by noise.
    geo = nodes.new("ShaderNodeNewGeometry")
    sep = nodes.new("ShaderNodeSeparateXYZ")
    links.new(geo.outputs["Normal"], sep.inputs["Vector"])
    mossn = C.noise(nodes, 4.0, 6, 0.6, coord, links)
    add = nodes.new("ShaderNodeMath")
    add.operation = "ADD"
    links.new(sep.outputs["Z"], add.inputs[0])
    links.new(mossn.outputs["Fac"], add.inputs[1])
    mask = C.ramp(nodes, links, add.outputs["Value"], [(1.25, (0, 0, 0)), (1.4, (1, 1, 1))])
    moss = C.ramp(nodes, links, fine.outputs["Fac"], [(0.3, C.hexlin("olive_dark")), (0.7, C.hexlin("moss"))])
    color = C.mix(nodes, links, mask.outputs["Color"], mul.outputs["Result"], moss.outputs["Color"])
    rough = C.ramp(nodes, links, fine.outputs["Fac"], [(0.3, (0.75, 0.75, 0.75)), (0.7, (0.95, 0.95, 0.95))])
    height = nodes.new("ShaderNodeMath")
    height.operation = "ADD"
    links.new(big.outputs["Fac"], height.inputs[0])
    links.new(fine.outputs["Fac"], height.inputs[1])
    normal = C.bump(nodes, links, height.outputs["Value"], 0.35)
    return color, rough.outputs["Color"], normal


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    obj = build()
    obj.data.materials.append(C.material("stone", stone))
    C.unwrap(obj, 0.02)
    sil = C.silhouette(NAME, outdir, [obj])
    maps = C.bake(obj, NAME, outdir, size=1024)
    pv = C.preview(NAME, outdir, [obj])
    fbx = C.export_fbx(NAME, outdir, [obj])
    C.report(NAME, [obj], {"fbx": fbx, "preview": pv, "silhouettes": sil, **maps}, {"seed": SEED})


main()
