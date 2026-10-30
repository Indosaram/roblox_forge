"""Body lane: one continuous skinned mesh per survivor (used by gen_survivors.py).

The painted pieces are authored in the rest pose; copies are swung into an A-pose (arms and legs out
about the R15 shoulder and hip pivots of SurvivorAvatar.layout) and fused into one watertight shell by a voxel remesh (blended
shoulders, elbows, wrists, hips, knees and ankles; no joint rings), decimated, and baked
selected-to-active from the painted rest-pose pieces into the preset's one colour atlas (the face
islands get a larger share of it). Eyes, brows, lips, nose, hair volumes and garments are all fused
into the shell; the paint comes from the pieces. Weights are capsule-distance blends over a fixed
band, so every joint bends over about a tenth of a stud. Linear blend skinning swings the shell back
to the rest pose (arms down); the mesh is then bound to an armature whose bones carry the R15 part
names plus the preset ("<R15Part>__bone__<preset>"; HumanoidRootPart root, every part bone a direct
child of it). The runtime (SurvivorAvatar) moves every imported Bone onto the character's R15 part of
its name at the Bone's rest offset, so the R15 Motor6D animation drives the skin with no per-frame
script (Roblox skins to Bones that are children of connected parts in the same Model).
"""

import math

import bmesh
import bpy
from mathutils import Matrix, Vector

import common as C
import survivor_geo as G

# R15 joints of SurvivorAvatar.layout (the runtime moves the rig attachments onto these).
NECK, WAIST, SHOULDER_Y, ELBOW, WRIST, HIP, KNEE, ANKLE = 1.6, 0.05, 1.33, 0.685, -0.075, -0.35, -1.172, -2.098
ARM_OUT = math.radians(32)  # A-pose swing: separates the sleeves from the torso for the remesh
LEG_OUT = math.radians(7)

ARM_PARTS = ("UpperArm", "LowerArm", "Hand")
LEG_PARTS = ("UpperLeg", "LowerLeg", "Foot")


def bones(arm_x, hip_x):
    """name -> (head, tail, parent, capsule segments [(a, b)], radius) in rig space, rest pose."""
    out = {
        "LowerTorso": ((0, HIP, 0), (0, WAIST, 0), None,
                       [((0, -0.45, 0), (0, WAIST, 0)), ((-0.17, -0.32, 0), (0.17, -0.32, 0))], 0.2),
        "UpperTorso": ((0, WAIST, 0), (0, NECK, 0), "LowerTorso",
                       [((0, WAIST + 0.05, 0), (0, 1.45, 0)), ((-0.26, 1.3, 0), (0.26, 1.3, 0))], 0.24),
        "Head": ((0, NECK, 0), (0, 2.3, 0), "UpperTorso", [((0, 1.7, 0), (0, 2.2, 0))], 0.15),
    }
    for side, name in ((-1, "Left"), (1, "Right")):
        ax, hx = side * arm_x, side * hip_x
        sh, el, wr, hd = (side * (arm_x - 0.03), SHOULDER_Y, 0), (ax, ELBOW, 0), (ax, WRIST, 0), (ax, -0.38, 0)
        hp, kn, an, toe = (hx, HIP, 0), (hx, KNEE, 0), (hx, ANKLE, 0), (hx, -2.27, -0.26)
        out[name + "UpperArm"] = (sh, el, "UpperTorso", [(sh, el)], 0.08)
        out[name + "LowerArm"] = (el, wr, name + "UpperArm", [(el, wr)], 0.065)
        out[name + "Hand"] = (wr, hd, name + "LowerArm", [(wr, hd)], 0.05)
        out[name + "UpperLeg"] = (hp, kn, "LowerTorso", [((hx, HIP - 0.08, 0), kn)], 0.13)
        out[name + "LowerLeg"] = (kn, an, name + "UpperLeg", [(kn, an)], 0.1)
        out[name + "Foot"] = (an, toe, name + "LowerLeg", [(an, (hx, -2.25, -0.2))], 0.07)
    return out


def swing(part, arm_x, hip_x):
    """A-pose rotation (4x4, rig space) of an R15 part: about Z through its shoulder or hip pivot."""
    side = -1 if part.startswith("Left") else 1
    tail = part[4:] if side < 0 else part[5:]
    if tail in ARM_PARTS:
        pivot, ang = Vector((side * (arm_x - 0.03), SHOULDER_Y, 0)), side * ARM_OUT
    elif tail in LEG_PARTS:
        pivot, ang = Vector((side * hip_x, HIP, 0)), side * LEG_OUT
    else:
        return Matrix.Identity(4)
    return Matrix.Translation(pivot) @ Matrix.Rotation(ang, 4, "Z") @ Matrix.Translation(-pivot)


def pose_bmesh(bm, m):
    for v in bm.verts:
        r = m @ Vector(G.rv(v.co))
        v.co = G.bv(r)


def _closed(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    ok = all(e.is_manifold for e in bm.edges)
    bm.free()
    return ok


def fuse(objs, name, voxel, tris, arm_x, hip_x):
    """A-posed copies of the rest-pose pieces `objs` (named "<R15Part>__..."), open shells
    thickened, voxel-remeshed into one shell and decimated to about `tris`."""
    copies = []
    for o in objs:
        c = o.copy()
        c.data = o.data.copy()
        C.link(c)
        c.modifiers.clear()
        m = swing(o.name.split("__")[0], arm_x, hip_x)
        for v in c.data.vertices:
            v.co = G.bv(m @ Vector(G.rv(v.co)))
        if not _closed(c):
            s = c.modifiers.new("thick", "SOLIDIFY")
            s.thickness = 0.018
            s.offset = -1.0
            C.apply_modifiers(c)
        copies.append(c)
    obj = C.join(copies, name)
    obj.data.materials.clear()
    r = obj.modifiers.new("fuse", "REMESH")
    r.mode = "VOXEL"
    r.voxel_size = voxel
    r.adaptivity = 0.0
    r.use_smooth_shade = True
    C.apply_modifiers(obj)
    now = C.triangles(obj)
    if now > tris:
        d = obj.modifiers.new("lod", "DECIMATE")
        d.decimate_type = "COLLAPSE"
        d.ratio = tris / now
        d.use_symmetry = True
        d.symmetry_axis = "X"
        C.apply_modifiers(obj)
    for p in obj.data.polygons:
        p.use_smooth = True
    return obj


def _uv_islands(bm, uv):
    parent = {}

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    key = {}
    for f in bm.faces:
        parent[f.index] = f.index
        for loop in f.loops:
            k = (loop.vert.index, round(loop[uv].uv.x, 5), round(loop[uv].uv.y, 5))
            if k in key:
                a, b = find(key[k]), find(f.index)
                if a != b:
                    parent[a] = b
            else:
                key[k] = f.index
    groups = {}
    for f in bm.faces:
        groups.setdefault(find(f.index), []).append(f)
    return list(groups.values())


def atlas_uvs(objs, face_scale, is_face):
    """Smart-projects `objs` into one UV space, enlarges the face islands `face_scale` times, repacks."""
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.004)
    bpy.ops.object.mode_set(mode="OBJECT")
    for o in objs:
        bm = bmesh.new()
        bm.from_mesh(o.data)
        bm.faces.ensure_lookup_table()
        uv = bm.loops.layers.uv.active
        for faces in _uv_islands(bm, uv):
            centre = sum((f.calc_center_median() for f in faces), Vector()) / len(faces)
            if not is_face(G.rv(centre)):
                continue
            loops = [lp for f in faces for lp in f.loops]
            mid = sum((lp[uv].uv for lp in loops), Vector((0, 0))) / len(loops)
            for lp in loops:
                lp[uv].uv = mid + (lp[uv].uv - mid) * face_scale
        bm.to_mesh(o.data)
        bm.free()
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.select_all(action="SELECT")
    bpy.ops.uv.pack_islands(rotate=True, margin=0.004)
    bpy.ops.object.mode_set(mode="OBJECT")


def bake_onto(pairs, name, outdir, size=1024, hide=()):
    """Bakes painted high pieces (rig-space shader paint, form light, occlusion) onto each low
    object's atlas UVs, one image for all of them. pairs: [(low, [highs])]. Returns the path."""
    lows = [low for low, _h in pairs]
    for o in hide:
        o.hide_render = True
    img = bpy.data.images.new(f"{name}_albedo", size, size, alpha=False)
    img.generated_color = (0.5, 0.5, 0.5, 1)
    tmp = bpy.data.materials.new(name + "_bake")
    tmp.use_nodes = True
    t = tmp.node_tree.nodes.new("ShaderNodeTexImage")
    t.image = img
    tmp.node_tree.nodes.active = t
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 16
    bs = scene.render.bake
    bs.margin = 6
    bs.use_pass_direct = False
    bs.use_pass_indirect = False
    bs.use_pass_color = True
    for k, (low, highs) in enumerate(pairs):
        bs.use_clear = k == 0  # one shared image: later bakes must not wipe the earlier islands
        low.data.materials.clear()
        low.data.materials.append(tmp)
        bpy.ops.object.select_all(action="DESELECT")
        for h in highs:
            h.select_set(True)
        low.select_set(True)
        bpy.context.view_layer.objects.active = low
        bs.use_selected_to_active = True
        bs.cage_extrusion = 0.045
        bs.max_ray_distance = 0.14
        bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"})
    bs.use_selected_to_active = False
    bs.use_clear = True
    path = f"{outdir}/{name}_albedo.png"
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    baked = bpy.data.materials.new(f"{name}_baked")
    baked.use_nodes = True
    nt = baked.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    nt.links.new(tex.outputs["Color"], nt.nodes["Principled BSDF"].inputs["Base Color"])
    nt.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.85
    for low in lows:
        low.data.materials.clear()
        low.data.materials.append(baked)
    for o in hide:
        o.hide_render = False
    return path


def _seg_dist(p, a, b):
    ab = b - a
    u = max(0.0, min(1.0, (p - a).dot(ab) / max(ab.length_squared, 1e-9)))
    return (a + ab * u - p).length


def skin(body, rig, arm_x, hip_x, band=0.08):
    """Weights the A-posed `body`, swings it back to rest by linear blend skinning and returns
    {bone: [(vertex, weight)]}."""
    swings = {n: swing(n, arm_x, hip_x) for n in rig}
    caps = {}
    for n, (_h, _t, _p, segs, rad) in rig.items():
        m = swings[n]
        caps[n] = ([(m @ Vector(a), m @ Vector(b)) for a, b in segs], rad)
    inv = {n: m.inverted() for n, m in swings.items()}
    groups = {n: [] for n in rig}
    for v in body.data.vertices:
        p = Vector(G.rv(v.co))
        d = {n: max(0.0, min(_seg_dist(p, a, b) for a, b in segs) - rad) for n, (segs, rad) in caps.items()}
        lo = min(d.values())
        ws = {n: (1 - (x - lo) / band) ** 2 for n, x in d.items() if x < lo + band}
        ws = dict(sorted(ws.items(), key=lambda kv: -kv[1])[:4])
        total = sum(ws.values())
        rest = Vector()
        for n, w in ws.items():
            w /= total
            groups[n].append((v.index, w))
            rest += (inv[n] @ p) * w
        v.co = G.bv(rest)
    return groups


def armature(name, rig, body, groups, suffix):
    """Armature with one bone per R15 part (rest pose) under a HumanoidRootPart root bone, `body`
    bound to it with the given weights."""
    data = bpy.data.armatures.new(name)
    arm = C.link(bpy.data.objects.new(name, data))
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    root = data.edit_bones.new(f"HumanoidRootPart__bone__{suffix}")
    root.head = G.bv((0, 0, 0))
    root.tail = G.bv((0, 0.4, 0))
    made = {None: root}
    for n, (h, t, parent, _s, _r) in rig.items():
        b = data.edit_bones.new(f"{n}__bone__{suffix}")
        b.head = G.bv(h)
        b.tail = G.bv(t)
        b.roll = 0.0
        made[n] = b
    for n, (_h, _t, parent, _s, _r) in rig.items():
        made[n].parent = root  # flat: the runtime moves each Bone onto its R15 part
        made[n].use_connect = False
    bpy.ops.object.mode_set(mode="OBJECT")
    for n, entries in groups.items():
        g = body.vertex_groups.new(name=f"{n}__bone__{suffix}")
        for i, w in entries:
            g.add([i], w, "REPLACE")
    mod = body.modifiers.new("rig", "ARMATURE")
    mod.object = arm
    body.parent = arm
    return arm
