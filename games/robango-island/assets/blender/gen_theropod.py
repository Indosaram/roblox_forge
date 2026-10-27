"""Skinned theropod pilot: skin-modifier body, 11-bone armature with automatic weights.

Bones: Root(pelvis) -> Spine -> Neck -> Head; Root -> Tail1 -> Tail2 -> Tail3;
Root -> ThighL -> ShinL, Root -> ThighR -> ShinR. Units: metres, ~3.2 m nose to tail.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
from mathutils import Vector

import common as C

SEED = 4105
NAME = "RobangoTheropod"

# Skeleton chain for the skin modifier: (name, position, radius x, radius y).
SPINE = [
    ("tail_tip", (0.0, 1.75, 0.95), 0.03, 0.03),
    ("tail_c", (0.0, 1.30, 0.98), 0.07, 0.08),
    ("tail_b", (0.0, 0.85, 1.03), 0.12, 0.14),
    ("tail_a", (0.0, 0.42, 1.08), 0.19, 0.22),
    ("pelvis", (0.0, 0.0, 1.10), 0.25, 0.30),
    ("chest", (0.0, -0.45, 1.15), 0.24, 0.32),
    ("neck_a", (0.0, -0.75, 1.32), 0.14, 0.16),
    ("neck_b", (0.0, -0.92, 1.55), 0.11, 0.12),
    ("head", (0.0, -1.08, 1.68), 0.13, 0.13),
    ("snout", (0.0, -1.38, 1.63), 0.08, 0.07),
    ("nose", (0.0, -1.52, 1.60), 0.04, 0.035),
]
LEG = [  # per side, x mirrored
    ("hip", (0.17, 0.02, 1.02), 0.13, 0.15),
    ("knee", (0.24, -0.12, 0.62), 0.09, 0.09),
    ("ankle", (0.22, 0.12, 0.22), 0.05, 0.05),
    ("toe", (0.22, -0.12, 0.03), 0.045, 0.03),
]
ARM = [
    ("shoulder", (0.15, -0.55, 1.10), 0.05, 0.05),
    ("elbow", (0.19, -0.62, 0.92), 0.035, 0.035),
    ("hand", (0.17, -0.75, 0.85), 0.025, 0.02),
]


def build_body():
    me = bpy.data.meshes.new(NAME)
    obj = C.link(bpy.data.objects.new(NAME, me))
    bm = bmesh.new()
    idx = {}
    radii = {}

    def add(key, pos, rx, ry):
        v = bm.verts.new(Vector(pos))
        idx[key] = v
        radii[key] = (rx, ry)
        return v

    prev = None
    for name, pos, rx, ry in SPINE:
        v = add(name, pos, rx, ry)
        if prev is not None:
            bm.edges.new((prev, v))
        prev = v
    for side in (1, -1):
        for chain, anchor in ((LEG, "pelvis"), (ARM, "chest")):
            prev = idx[anchor]
            for name, (x, y, z), rx, ry in chain:
                v = add(f"{name}{side}", (x * side, y, z), rx, ry)
                bm.edges.new((prev, v))
                prev = v
    bm.to_mesh(me)
    bm.free()
    skin = obj.modifiers.new("skin", "SKIN")
    # Radii are stored on the mesh skin layer after the modifier exists.
    keys = list(idx.keys())
    for i, key in enumerate(keys):
        sv = me.skin_vertices[0].data[i]
        sv.radius = radii[key]
    me.skin_vertices[0].data[0].use_root = False
    me.skin_vertices[0].data[keys.index("pelvis")].use_root = True
    sub = obj.modifiers.new("sub", "SUBSURF")
    sub.levels = 2
    C.apply_modifiers(obj)
    # Organic surface noise (scales/skin folds) at low amplitude.
    tex = bpy.data.textures.new("lump", "CLOUDS")
    tex.noise_scale = 0.12
    disp = obj.modifiers.new("disp", "DISPLACE")
    disp.texture = tex
    disp.strength = 0.015
    dec = obj.modifiers.new("dec", "DECIMATE")
    dec.ratio = 0.6
    C.apply_modifiers(obj)
    C.finish_mesh(obj)
    return obj


BONES = [
    # name, head, tail, parent
    ("Root", (0, 0.10, 1.10), (0, -0.20, 1.12), None),
    ("Spine", (0, -0.20, 1.12), (0, -0.62, 1.22), "Root"),
    ("Neck", (0, -0.62, 1.22), (0, -0.95, 1.58), "Spine"),
    ("Head", (0, -0.95, 1.58), (0, -1.52, 1.60), "Neck"),
    ("Tail1", (0, 0.10, 1.10), (0, 0.65, 1.05), "Root"),
    ("Tail2", (0, 0.65, 1.05), (0, 1.20, 0.99), "Tail1"),
    ("Tail3", (0, 1.20, 0.99), (0, 1.75, 0.95), "Tail2"),
    ("ThighL", (0.17, 0.02, 1.02), (0.24, -0.12, 0.62), "Root"),
    ("ShinL", (0.24, -0.12, 0.62), (0.22, 0.12, 0.22), "ThighL"),
    ("ThighR", (-0.17, 0.02, 1.02), (-0.24, -0.12, 0.62), "Root"),
    ("ShinR", (-0.24, -0.12, 0.62), (-0.22, 0.12, 0.22), "ThighR"),
]


def build_armature():
    arm_data = bpy.data.armatures.new(NAME + "Rig")
    arm = C.link(bpy.data.objects.new(NAME + "Rig", arm_data))
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    made = {}
    for name, h, t, parent in BONES:
        b = arm_data.edit_bones.new(name)
        b.head = Vector(h)
        b.tail = Vector(t)
        if parent:
            b.parent = made[parent]
            b.use_connect = (made[parent].tail - b.head).length < 1e-4
        made[name] = b
    bpy.ops.object.mode_set(mode="OBJECT")
    return arm


def skin_mat(nodes, links):
    coord = nodes.new("ShaderNodeTexCoord").outputs["Object"]
    geo = nodes.new("ShaderNodeNewGeometry")
    sep = nodes.new("ShaderNodeSeparateXYZ")
    links.new(geo.outputs["Normal"], sep.inputs["Vector"])
    # Countershading: darker olive-brown back, pale ochre belly.
    shade = C.ramp(nodes, links, sep.outputs["Z"], [(-0.6, (0.62, 0.55, 0.40)), (0.4, (0.36, 0.33, 0.22))])
    # Irregular dorsal stripes.
    pos = nodes.new("ShaderNodeSeparateXYZ")
    links.new(coord, pos.inputs["Vector"])
    wave = nodes.new("ShaderNodeTexWave")
    wave.wave_type = "BANDS"
    wave.bands_direction = "Y"
    wave.inputs["Scale"].default_value = 3.0
    wave.inputs["Distortion"].default_value = 6.0
    links.new(coord, wave.inputs["Vector"])
    stripe = C.ramp(nodes, links, wave.outputs["Fac"], [(0.55, (1, 1, 1)), (0.8, (0.55, 0.50, 0.45))])
    back = C.ramp(nodes, links, sep.outputs["Z"], [(0.0, (0, 0, 0)), (0.5, (1, 1, 1))])
    stripes = C.mix(nodes, links, back.outputs["Color"], shade.outputs["Color"], stripe.outputs["Color"])
    mul = nodes.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    mul.inputs["Factor"].default_value = 1.0
    links.new(shade.outputs["Color"], mul.inputs["A"])
    links.new(stripes, mul.inputs["B"])
    scales = nodes.new("ShaderNodeTexVoronoi")
    scales.inputs["Scale"].default_value = 90.0
    links.new(coord, scales.inputs["Vector"])
    fine = C.ramp(nodes, links, scales.outputs["Distance"], [(0.0, (0.80, 0.78, 0.74)), (0.45, (1, 1, 1))])
    mul2 = nodes.new("ShaderNodeMix")
    mul2.data_type = "RGBA"
    mul2.blend_type = "MULTIPLY"
    mul2.inputs["Factor"].default_value = 1.0
    links.new(mul.outputs["Result"], mul2.inputs["A"])
    links.new(fine.outputs["Color"], mul2.inputs["B"])
    normal = C.bump(nodes, links, scales.outputs["Distance"], 0.25)
    rough = C.ramp(nodes, links, scales.outputs["Distance"], [(0.0, (0.6, 0.6, 0.6)), (0.5, (0.85, 0.85, 0.85))])
    return mul2.outputs["Result"], rough.outputs["Color"], normal


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    body = build_body()
    body.data.materials.append(C.material("hide", skin_mat))
    C.unwrap(body, 0.01)
    sil = C.silhouette(NAME, outdir, [body])
    maps = C.bake(body, NAME, outdir, size=1024)
    arm = build_armature()
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")
    weighted = sum(1 for v in body.data.vertices if len(v.groups) > 0)
    pv = C.preview(NAME, outdir, [body])
    fbx = C.export_fbx(NAME, outdir, [arm, body])
    C.report(
        NAME,
        [body],
        {"fbx": fbx, "preview": pv, "silhouettes": sil, **maps},
        {
            "seed": SEED,
            "bones": len(arm.data.bones),
            "vertex_groups": len(body.vertex_groups),
            "weighted_vertices": weighted,
            "vertices": len(body.data.vertices),
        },
    )


main()
