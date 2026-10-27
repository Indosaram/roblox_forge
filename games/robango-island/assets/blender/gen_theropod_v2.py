"""Skinned theropod v2: small olive-brown theropod with eyes, painted mouth line + nostrils,
3-toed feet and 2-fingered hands with dark claws, CC0 leather micro-detail + painted irregular stripes.

Bones (17): Root, Spine, Neck, Head, Tail1-3, ThighL/ShinL/FootL, ThighR/ShinR/FootR,
UpperArmL/ForearmL, UpperArmR/ForearmR. Units: metres, ~3.5 m nose to tail, hip 1.15 m.
Needs build/a2b/src/brown_leather/ (see SOURCES.md).
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
from mathutils import Matrix, Vector

import common as C

SEED = 4205
NAME = "RobangoTheropodV2"
TARGET_TRIS = 6150  # body; + eyes/claws -> <=7000 total (asset-catalog M theropod)

# (name, position, radius a, radius b)
SPINE = [
    ("tail_tip", (0.0, 2.05, 0.86), 0.022, 0.022),
    ("tail_d", (0.0, 1.65, 0.93), 0.05, 0.06),
    ("tail_c", (0.0, 1.25, 1.00), 0.09, 0.11),
    ("tail_b", (0.0, 0.82, 1.08), 0.14, 0.17),
    ("tail_a", (0.0, 0.40, 1.13), 0.20, 0.24),
    ("pelvis", (0.0, 0.00, 1.16), 0.24, 0.29),
    ("belly", (0.0, -0.30, 1.13), 0.26, 0.33),
    ("chest", (0.0, -0.56, 1.19), 0.23, 0.31),
    ("neck_a", (0.0, -0.78, 1.36), 0.14, 0.16),
    ("neck_b", (0.0, -0.90, 1.55), 0.11, 0.12),
    ("head_back", (0.0, -1.01, 1.69), 0.13, 0.14),
    ("head", (0.0, -1.15, 1.69), 0.115, 0.125),
    ("snout", (0.0, -1.35, 1.64), 0.08, 0.085),
    ("nose", (0.0, -1.50, 1.61), 0.045, 0.05),
]
LEG = [
    ("hip", (0.18, 0.02, 1.06), 0.16, 0.20),
    ("knee", (0.25, -0.16, 0.66), 0.10, 0.11),
    ("ankle", (0.22, 0.14, 0.25), 0.055, 0.055),
    ("foot", (0.22, -0.04, 0.06), 0.05, 0.03),
]
TOES = [(0.22, -0.27, 0.03), (0.14, -0.21, 0.03), (0.30, -0.21, 0.03)]
ARM = [
    ("shoulder", (0.16, -0.60, 1.12), 0.065, 0.065),
    ("elbow", (0.23, -0.67, 0.92), 0.048, 0.048),
    ("wrist", (0.21, -0.82, 0.83), 0.032, 0.03),
]
FINGERS = [(0.18, -0.91, 0.77), (0.24, -0.91, 0.78)]
EYE = (0.098, -1.13, 1.735)


def build_body():
    me = bpy.data.meshes.new(NAME)
    obj = C.link(bpy.data.objects.new(NAME, me))
    bm = bmesh.new()
    keys, radii, idx = [], [], {}

    def add(key, pos, ra, rb):
        v = bm.verts.new(Vector(pos))
        idx[key] = v
        keys.append(key)
        radii.append((ra, rb))
        return v

    prev = None
    for name, pos, ra, rb in SPINE:
        v = add(name, pos, ra, rb)
        if prev is not None:
            bm.edges.new((prev, v))
        prev = v
    tips = []
    for side in (1, -1):
        prev = idx["pelvis"]
        for name, (x, y, z), ra, rb in LEG:
            v = add(f"{name}{side}", (x * side, y, z), ra, rb)
            bm.edges.new((prev, v))
            prev = v
        for i, (x, y, z) in enumerate(TOES):
            v = add(f"toe{i}{side}", (x * side, y, z), 0.028, 0.02)
            bm.edges.new((idx[f"foot{side}"], v))
            tips.append(("toe", Vector((x * side, y, z))))
        prev = idx["chest"]
        for name, (x, y, z), ra, rb in ARM:
            v = add(f"{name}{side}", (x * side, y, z), ra, rb)
            bm.edges.new((prev, v))
            prev = v
        for i, (x, y, z) in enumerate(FINGERS):
            v = add(f"finger{i}{side}", (x * side, y, z), 0.014, 0.012)
            bm.edges.new((idx[f"wrist{side}"], v))
            tips.append(("finger", Vector((x * side, y, z))))
    bm.to_mesh(me)
    bm.free()
    obj.modifiers.new("skin", "SKIN")
    for i, r in enumerate(radii):
        me.skin_vertices[0].data[i].radius = r
        me.skin_vertices[0].data[i].use_root = keys[i] == "pelvis"
    sub = obj.modifiers.new("sub", "SUBSURF")
    sub.levels = 2
    C.apply_modifiers(obj)
    tex = bpy.data.textures.new("lump", "CLOUDS")
    tex.noise_scale = 0.08
    disp = obj.modifiers.new("disp", "DISPLACE")
    disp.texture = tex
    disp.strength = 0.008
    C.apply_modifiers(obj)
    C.decimate_to(obj, TARGET_TRIS)
    C.finish_mesh(obj)
    return obj, tips


def build_details(tips):
    """Claws (dark cones) and eyes (spheres). Separate objects, joined after material setup."""
    bm = bmesh.new()
    for kind, p in tips:
        fwd = Vector((0, -1, -0.45 if kind == "toe" else -0.9)).normalized()
        length = 0.09 if kind == "toe" else 0.06
        r = 0.022 if kind == "toe" else 0.012
        rot = fwd.to_track_quat("Z", "Y").to_matrix().to_4x4()
        m = Matrix.Translation(p + fwd * 0.01) @ rot @ Matrix.Translation(Vector((0, 0, length / 2)))
        bmesh.ops.create_cone(bm, cap_ends=True, segments=6, radius1=r, radius2=0.002, depth=length, matrix=m)
    claws = C.mesh_object("claws", bm)
    bm = bmesh.new()
    for side in (1, -1):
        bmesh.ops.create_uvsphere(bm, u_segments=10, v_segments=8, radius=0.034, matrix=Matrix.Translation(Vector((EYE[0] * side, EYE[1], EYE[2]))))
    eyes = C.mesh_object("eyes", bm)
    C.finish_mesh(eyes)
    return claws, eyes


def hide_mat(nodes, links):
    coord = nodes.new("ShaderNodeTexCoord").outputs["Object"]
    geo = nodes.new("ShaderNodeNewGeometry")
    nz = nodes.new("ShaderNodeSeparateXYZ")
    links.new(geo.outputs["Normal"], nz.inputs["Vector"])
    pos = nodes.new("ShaderNodeSeparateXYZ")
    links.new(coord, pos.inputs["Vector"])
    # Countershading: olive-brown back -> pale ochre belly.
    shade = C.ramp(nodes, links, nz.outputs["Z"], [(-0.55, C.hexlin("belly")), (-0.05, C.hexlin("hide")), (0.6, C.hexlin("hide"))])
    # Irregular transverse stripes (broken tiger bands), back and flanks only.
    wave = nodes.new("ShaderNodeTexWave")
    wave.wave_type = "BANDS"
    wave.bands_direction = "Y"
    wave.inputs["Scale"].default_value = 2.6
    wave.inputs["Distortion"].default_value = 9.0
    wave.inputs["Detail"].default_value = 3.0
    links.new(coord, wave.inputs["Vector"])
    brk = C.noise(nodes, 3.5, 4, 0.55, coord, links)
    sm = nodes.new("ShaderNodeMath")
    sm.operation = "MULTIPLY"
    links.new(wave.outputs["Fac"], sm.inputs[0])
    links.new(brk.outputs["Fac"], sm.inputs[1])
    band = C.ramp(nodes, links, sm.outputs["Value"], [(0.30, (0, 0, 0)), (0.42, (1, 1, 1))])
    back = C.ramp(nodes, links, nz.outputs["Z"], [(-0.2, (0, 0, 0)), (0.25, (1, 1, 1))])
    m1 = nodes.new("ShaderNodeMath")
    m1.operation = "MULTIPLY"
    links.new(band.outputs["Color"], m1.inputs[0])
    links.new(back.outputs["Color"], m1.inputs[1])
    stripe_col = nodes.new("ShaderNodeRGB")
    stripe_col.outputs[0].default_value = (*C.hexlin("hide_stripe"), 1)
    col = C.mix(nodes, links, m1.outputs["Value"], shade.outputs["Color"], stripe_col.outputs[0])
    # Dark eye stripe + mouth line + nostrils, from object-space position.
    def dist_to(point, radius_in, radius_out):
        vm = nodes.new("ShaderNodeVectorMath")
        vm.operation = "DISTANCE"
        links.new(coord, vm.inputs[0])
        vm.inputs[1].default_value = point
        return C.ramp(nodes, links, vm.outputs["Value"], [(radius_in, (1, 1, 1)), (radius_out, (0, 0, 0))]).outputs["Color"]

    # Mouth: |z - (1.548 + (y+1.5)*-0.12)| small, for y in [-1.52, -1.08], on the sides.
    lin = nodes.new("ShaderNodeMath")
    lin.operation = "MULTIPLY_ADD"
    links.new(pos.outputs["Y"], lin.inputs[0])
    lin.inputs[1].default_value = -0.13
    lin.inputs[2].default_value = 1.588 - 0.13 * 1.5
    dz = nodes.new("ShaderNodeMath")
    dz.operation = "SUBTRACT"
    links.new(pos.outputs["Z"], dz.inputs[0])
    links.new(lin.outputs["Value"], dz.inputs[1])
    adz = nodes.new("ShaderNodeMath")
    adz.operation = "ABSOLUTE"
    links.new(dz.outputs["Value"], adz.inputs[0])
    mline = C.ramp(nodes, links, adz.outputs["Value"], [(0.004, (1, 1, 1)), (0.009, (0, 0, 0))])
    yr = C.ramp(nodes, links, pos.outputs["Y"], [(-1.53, (1, 1, 1)), (-1.08, (1, 1, 1)), (-1.04, (0, 0, 0))])
    mouth = nodes.new("ShaderNodeMath")
    mouth.operation = "MULTIPLY"
    links.new(mline.outputs["Color"], mouth.inputs[0])
    links.new(yr.outputs["Color"], mouth.inputs[1])
    dark = nodes.new("ShaderNodeRGB")
    dark.outputs[0].default_value = (*C.hexlin("#1c1712"), 1)
    col = C.mix(nodes, links, mouth.outputs["Value"], col, dark.outputs[0])
    for side in (1, -1):
        col = C.mix(nodes, links, dist_to((0.028 * side, -1.52, 1.625), 0.008, 0.014), col, dark.outputs[0])
        # eye surround: dark mask band behind the eye
        ring = dist_to((EYE[0] * side, EYE[1] + 0.03, EYE[2]), 0.035, 0.075)
        k = nodes.new("ShaderNodeMath")
        k.operation = "MULTIPLY"
        k.inputs[1].default_value = 0.65
        links.new(ring, k.inputs[0])
        stripe2 = nodes.new("ShaderNodeRGB")
        stripe2.outputs[0].default_value = (*C.hexlin("hide_stripe"), 1)
        col = C.mix(nodes, links, k.outputs["Value"], col, stripe2.outputs[0])
    # CC0 leather scan as micro-detail: luminance multiplier + normal.
    mp = nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (3.0, 3.0, 3.0)
    links.new(coord, mp.inputs["Vector"])
    la = nodes.new("ShaderNodeTexImage")
    la.image = C.load_image(os.path.join(C.SRC_DIR, "brown_leather", "brown_leather_albedo_1k.png"))
    la.projection = "BOX"
    la.projection_blend = 0.3
    links.new(mp.outputs["Vector"], la.inputs["Vector"])
    bw = nodes.new("ShaderNodeRGBToBW")
    links.new(la.outputs["Color"], bw.inputs["Color"])
    det = C.ramp(nodes, links, bw.outputs["Val"], [(0.05, (0.62, 0.62, 0.62)), (0.25, (1.2, 1.2, 1.2))])
    mul = nodes.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    mul.inputs["Factor"].default_value = 1.0
    links.new(col, mul.inputs["A"])
    links.new(det.outputs["Color"], mul.inputs["B"])
    ln = nodes.new("ShaderNodeTexImage")
    ln.image = C.load_image(os.path.join(C.SRC_DIR, "brown_leather", "brown_leather_nor_gl_1k.png"), True)
    ln.projection = "BOX"
    ln.projection_blend = 0.3
    links.new(mp.outputs["Vector"], ln.inputs["Vector"])
    nmap = nodes.new("ShaderNodeNormalMap")
    nmap.inputs["Strength"].default_value = 1.5
    links.new(ln.outputs["Color"], nmap.inputs["Color"])
    # Larger scale bumps on top (voronoi), chained onto the leather normal.
    vor = nodes.new("ShaderNodeTexVoronoi")
    vor.inputs["Scale"].default_value = 55.0
    links.new(coord, vor.inputs["Vector"])
    b = nodes.new("ShaderNodeBump")
    b.inputs["Strength"].default_value = 0.3
    links.new(vor.outputs["Distance"], b.inputs["Height"])
    links.new(nmap.outputs["Normal"], b.inputs["Normal"])
    rough = C.ramp(nodes, links, bw.outputs["Val"], [(0.05, (0.9, 0.9, 0.9)), (0.3, (0.7, 0.7, 0.7))])
    return mul.outputs["Result"], rough.outputs["Color"], b.outputs["Normal"]


def claw_mat(nodes, links):
    c = nodes.new("ShaderNodeRGB")
    c.outputs[0].default_value = (*C.hexlin("claw"), 1)
    r = nodes.new("ShaderNodeValue")
    r.outputs[0].default_value = 0.45
    return c.outputs[0], r.outputs[0], None


def eye_mat(nodes, links):
    geo = nodes.new("ShaderNodeNewGeometry")
    sep = nodes.new("ShaderNodeSeparateXYZ")
    links.new(geo.outputs["Normal"], sep.inputs["Vector"])
    ax = nodes.new("ShaderNodeMath")
    ax.operation = "ABSOLUTE"
    links.new(sep.outputs["X"], ax.inputs[0])
    col = C.ramp(nodes, links, ax.outputs["Value"], [(0.55, C.hexlin("#201a14")), (0.62, C.hexlin("eye")), (0.86, C.hexlin("eye")), (0.9, (0.005, 0.004, 0.003))])
    r = nodes.new("ShaderNodeValue")
    r.outputs[0].default_value = 0.2
    return col.outputs["Color"], r.outputs[0], None


BONES = [
    ("Root", (0, 0.10, 1.16), (0, -0.20, 1.15), None),
    ("Spine", (0, -0.20, 1.15), (0, -0.62, 1.22), "Root"),
    ("Neck", (0, -0.62, 1.22), (0, -0.95, 1.60), "Spine"),
    ("Head", (0, -0.95, 1.60), (0, -1.52, 1.62), "Neck"),
    ("Tail1", (0, 0.10, 1.16), (0, 0.70, 1.10), "Root"),
    ("Tail2", (0, 0.70, 1.10), (0, 1.30, 1.00), "Tail1"),
    ("Tail3", (0, 1.30, 1.00), (0, 2.05, 0.86), "Tail2"),
]
for _s, _n in ((1, "L"), (-1, "R")):
    BONES += [
        (f"Thigh{_n}", (0.18 * _s, 0.02, 1.06), (0.25 * _s, -0.16, 0.66), "Root"),
        (f"Shin{_n}", (0.25 * _s, -0.16, 0.66), (0.22 * _s, 0.14, 0.25), f"Thigh{_n}"),
        (f"Foot{_n}", (0.22 * _s, 0.14, 0.25), (0.22 * _s, -0.27, 0.03), f"Shin{_n}"),
        (f"UpperArm{_n}", (0.16 * _s, -0.60, 1.12), (0.23 * _s, -0.67, 0.92), "Spine"),
        (f"Forearm{_n}", (0.23 * _s, -0.67, 0.92), (0.21 * _s, -0.91, 0.78), f"UpperArm{_n}"),
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


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    body, tips = build_body()
    body.data.materials.append(C.material("hide", hide_mat))
    claws, eyes = build_details(tips)
    claws.data.materials.append(C.material("claw", claw_mat))
    eyes.data.materials.append(C.material("eye", eye_mat))
    body = C.join([body, claws, eyes], NAME)
    C.unwrap(body, 0.006)
    sil = C.silhouette(NAME, outdir, [body])
    maps = C.bake(body, NAME, outdir, size=512)  # catalog: S/M creatures 512 x3
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
        {"seed": SEED, "bones": len(arm.data.bones), "weighted_vertices": weighted, "vertices": len(body.data.vertices)},
    )


main()
