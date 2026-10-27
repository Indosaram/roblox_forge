"""Shared helpers for the Robango Blender asset generators (A2 pilot).

Run only headless: blender -b --factory-startup --python gen_<asset>.py -- <outdir>
Every generator is deterministic: it seeds Python's random with a recorded seed.
"""

import math
import os
import random
import sys

import bpy
import bmesh
from mathutils import Vector


def out_dir():
    argv = sys.argv
    args = argv[argv.index("--") + 1 :] if "--" in argv else []
    path = os.path.abspath(args[0] if args else os.path.join(os.getcwd(), "build", "a2-pilot"))
    os.makedirs(path, exist_ok=True)
    return path


def reset(seed):
    random.seed(seed)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 8
    return scene


def link(obj):
    bpy.context.scene.collection.objects.link(obj)
    return obj


def mesh_object(name, bm):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return link(bpy.data.objects.new(name, me))


def strip(bm, points, widths, normal_twist=0.0, droop=None):
    """Tapered double-sided ribbon along a polyline (blade, frond rachis, leaflet).

    points: list of Vector; widths: list of half widths. Returns created faces.
    """
    verts = []
    n = len(points)
    for i, p in enumerate(points):
        t = points[min(i + 1, n - 1)] - points[max(i - 1, 0)]
        t.normalize()
        side = t.cross(Vector((0, 0, 1)))
        if side.length < 1e-4:
            side = Vector((1, 0, 0))
        side.normalize()
        if normal_twist:
            side = side.lerp(Vector((0, 0, 1)), normal_twist).normalized()
        w = widths[i]
        verts.append((bm.verts.new(p - side * w), bm.verts.new(p + side * w)))
    faces = []
    for i in range(n - 1):
        a0, a1 = verts[i]
        b0, b1 = verts[i + 1]
        faces.append(bm.faces.new((a0, a1, b1, b0)))
    return faces


def material(name, build):
    """Create a node material; build(nodes, links) returns (color_socket, rough_socket, normal_socket|None)."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    color, rough, normal = build(nodes, links)
    links.new(color, bsdf.inputs["Base Color"])
    if rough is not None:
        links.new(rough, bsdf.inputs["Roughness"])
    else:
        bsdf.inputs["Roughness"].default_value = 0.85
    if normal is not None:
        links.new(normal, bsdf.inputs["Normal"])
    return mat


def noise(nodes, scale, detail=6.0, rough=0.6, coord=None, links=None):
    n = nodes.new("ShaderNodeTexNoise")
    n.inputs["Scale"].default_value = scale
    n.inputs["Detail"].default_value = detail
    n.inputs["Roughness"].default_value = rough
    if coord is not None:
        links.new(coord, n.inputs["Vector"])
    return n


def ramp(nodes, links, fac, stops):
    r = nodes.new("ShaderNodeValToRGB")
    els = r.color_ramp.elements
    while len(els) > len(stops):
        els.remove(els[-1])
    while len(els) < len(stops):
        els.new(0.5)
    for el, (pos, rgb) in zip(els, stops):
        el.position = pos
        el.color = (rgb[0], rgb[1], rgb[2], 1.0)
    links.new(fac, r.inputs["Fac"])
    return r


def bump(nodes, links, height, strength):
    b = nodes.new("ShaderNodeBump")
    b.inputs["Strength"].default_value = strength
    links.new(height, b.inputs["Height"])
    return b.outputs["Normal"]


def mix(nodes, links, fac, a, b):
    m = nodes.new("ShaderNodeMix")
    m.data_type = "RGBA"
    links.new(fac, m.inputs["Factor"])
    links.new(a, m.inputs["A"])
    links.new(b, m.inputs["B"])
    return m.outputs["Result"]


def finish_mesh(obj, smooth=True):
    bpy.context.view_layer.objects.active = obj
    for o in bpy.context.view_layer.objects:
        o.select_set(o == obj)
    if smooth:
        bpy.ops.object.shade_smooth()
    return obj


def join(objs, name):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    obj.data.name = name
    return obj


def apply_modifiers(obj):
    bpy.context.view_layer.objects.active = obj
    for m in list(obj.modifiers):
        bpy.ops.object.modifier_apply(modifier=m.name)


def unwrap(obj, margin=0.01):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=margin)
    bpy.ops.object.mode_set(mode="OBJECT")


def triangles(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


def bake(obj, name, outdir, size=1024, passes=("albedo", "normal", "roughness")):
    """Bake procedural materials of obj into PNG maps; returns {pass: path}.

    Afterwards every material slot is replaced by ONE baked material using the maps,
    so the FBX carries only image textures (embedded on export).
    """
    scene = bpy.context.scene
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    images = {}
    for kind in passes:
        img = bpy.data.images.new(f"{name}_{kind}", size, size, alpha=False)
        if kind != "albedo":
            img.colorspace_settings.name = "Non-Color"
        images[kind] = img
    nodes_added = []
    for slot in obj.material_slots:
        nt = slot.material.node_tree
        tex = nt.nodes.new("ShaderNodeTexImage")
        nodes_added.append((nt, tex))
    paths = {}
    for kind, img in images.items():
        for nt, tex in nodes_added:
            tex.image = img
            nt.nodes.active = tex
        bake_settings = scene.render.bake
        bake_settings.margin = 4
        if kind == "albedo":
            bake_settings.use_pass_direct = False
            bake_settings.use_pass_indirect = False
            bake_settings.use_pass_color = True
            bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"})
        elif kind == "normal":
            bake_settings.normal_space = "TANGENT"
            bpy.ops.object.bake(type="NORMAL")
        else:
            bpy.ops.object.bake(type="ROUGHNESS")
        path = os.path.join(outdir, f"{name}_{kind}.png")
        img.filepath_raw = path
        img.file_format = "PNG"
        img.save()
        paths[kind] = path
    baked = bpy.data.materials.new(f"{name}_baked")
    baked.use_nodes = True
    nt = baked.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = images["albedo"]
    nt.links.new(t.outputs["Color"], bsdf.inputs["Base Color"])
    if "roughness" in images:
        r = nt.nodes.new("ShaderNodeTexImage")
        r.image = images["roughness"]
        nt.links.new(r.outputs["Color"], bsdf.inputs["Roughness"])
    if "normal" in images:
        nmap = nt.nodes.new("ShaderNodeNormalMap")
        n = nt.nodes.new("ShaderNodeTexImage")
        n.image = images["normal"]
        nt.links.new(n.outputs["Color"], nmap.inputs["Color"])
        nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    obj.data.materials.clear()
    obj.data.materials.append(baked)
    return paths


def export_fbx(name, outdir, objects):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objects:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    path = os.path.join(outdir, f"{name}.fbx")
    bpy.ops.export_scene.fbx(
        filepath=path,
        use_selection=True,
        object_types={"MESH", "ARMATURE"},
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_ALL",
        path_mode="COPY",
        embed_textures=True,
        add_leaf_bones=False,
        bake_anim=False,
        mesh_smooth_type="FACE",
    )
    return path


def silhouette(name, outdir, objects, views=("front", "side", "top")):
    """Render flat black silhouettes for the moderation pre-check (noose/weapon/gesture screen)."""
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "FLAT"
    scene.display.shading.color_type = "SINGLE"
    scene.display.shading.single_color = (0, 0, 0)
    scene.display.shading.background_type = "VIEWPORT"
    scene.display.shading.background_color = (1, 1, 1)
    scene.render.resolution_x = 384
    scene.render.resolution_y = 384
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in objects:
        if o.type != "MESH":
            continue
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    center = (lo + hi) / 2
    extent = max(hi - lo) * 1.15
    cam_data = bpy.data.cameras.new("sil")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = extent
    cam = link(bpy.data.objects.new("sil", cam_data))
    scene.camera = cam
    world = scene.world or bpy.data.worlds.new("w")
    scene.world = world
    paths = []
    dirs = {"front": Vector((0, -1, 0)), "side": Vector((1, 0, 0)), "top": Vector((0, 0, 1))}
    for v in views:
        d = dirs[v]
        cam.location = center + d * extent * 2
        cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        cam_data.clip_end = extent * 5
        p = os.path.join(outdir, f"{name}_sil_{v}.png")
        scene.render.filepath = p
        bpy.ops.render.render(write_still=True)
        paths.append(p)
    bpy.data.objects.remove(cam)
    scene.render.engine = "CYCLES"
    return paths


def preview(name, outdir, objects):
    """One shaded Cycles-free preview (EEVEE-less workbench textured) for the report."""
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "TEXTURE"
    scene.display.shading.background_type = "VIEWPORT"
    scene.display.shading.background_color = (0.55, 0.52, 0.45)
    scene.render.resolution_x = 512
    scene.render.resolution_y = 512
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in objects:
        if o.type != "MESH":
            continue
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    center = (lo + hi) / 2
    extent = max(hi - lo)
    cam_data = bpy.data.cameras.new("pv")
    cam_data.lens = 50
    cam = link(bpy.data.objects.new("pv", cam_data))
    scene.camera = cam
    d = Vector((0.6, -1.0, 0.75)).normalized()
    cam.location = center + d * extent * 2.2
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    cam_data.clip_end = extent * 10
    p = os.path.join(outdir, f"{name}_preview.png")
    scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(cam)
    scene.render.engine = "CYCLES"
    return p


# ---------------------------------------------------------------- A2b helpers

SRC_DIR = os.path.join(os.getcwd(), "build", "a2b", "src")

# Reference palette (sRGB hex, albedo targets derived from R03-3 / R11-1/2/8 samples,
# darkened from the screen values because the references carry a warm grade + haze).
PALETTE = {
    "rock_light": "#8f7d68",
    "rock_mid": "#6c5c4b",
    "rock_dark": "#3e342b",
    "moss": "#5a5a32",
    "olive_dark": "#3c4224",
    "olive": "#5f6638",
    "olive_light": "#7f7f4a",
    "straw": "#9c8a5a",
    "straw_dry": "#7a6440",
    "soil": "#6e5340",
    "bark_dark": "#3b2f25",
    "bark": "#6a5843",
    "hide": "#6b5f3e",
    "hide_stripe": "#33291c",
    "belly": "#a3916a",
    "berry": "#8e2a22",
    "fruit": "#b8622a",
    "claw": "#2a2420",
    "eye": "#c08a2a",
}


def srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hexlin(h):
    """sRGB hex -> linear RGB triple. Node colours are LINEAR: feeding sRGB values washes out (A2 defect)."""
    h = PALETTE.get(h, h).lstrip("#")
    return tuple(srgb_to_lin(int(h[i : i + 2], 16) / 255) for i in (0, 2, 4))


def load_image(path, non_color=False):
    img = bpy.data.images.load(path, check_existing=True)
    if non_color:
        img.colorspace_settings.name = "Non-Color"
    return img


def grade_pixels(px, target_hex, strength=0.75, sat=0.55, mask=None):
    """Grade an sRGB float pixel array (N,4) toward a palette colour: desaturate, shift mean.

    Keeps the luminance detail of the scan; only the colour cast and level move."""
    import numpy as np

    rgb = px[:, :3]
    sel = mask if mask is not None else np.ones(len(px), bool)
    lum = (rgb * np.array([0.2126, 0.7152, 0.0722])).sum(1, keepdims=True)
    rgb2 = lum + (rgb - lum) * sat
    h = PALETTE.get(target_hex, target_hex).lstrip("#")
    tgt = np.array([int(h[i : i + 2], 16) / 255 for i in (0, 2, 4)])
    mean = rgb2[sel].mean(0)
    rgb2 = rgb2 * (1 - strength) + (rgb2 * (tgt / np.maximum(mean, 1e-3))) * strength
    px[:, :3] = np.clip(rgb2, 0, 1)
    return px


def bleed(px):
    """Fill RGB of fully transparent texels with the mean opaque colour: avoids white/black
    fringes once Roblox mipmaps the alpha-cut atlas."""
    m = px[:, 3] > 0.5
    if m.any():
        px[~m, :3] = px[m, :3].mean(0) * 0.8
    return px


def save_rgba(name, outdir, w, h, px, size=None):
    if px.ndim == 2 and px.shape[1] == 4 and (px[:, 3] < 0.5).any():
        px = bleed(px)
    img = bpy.data.images.new(name, w, h, alpha=True)
    img.pixels.foreach_set(px.ravel())
    if size and size != w:
        img.scale(size, size)
    path = os.path.join(outdir, f"{name}.png")
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    return img, path


def image_array(img):
    import numpy as np

    w, h = img.size
    a = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(-1, 4), w, h


def card_material(name, albedo_img, normal_img=None, rough=0.8):
    """Alpha-cutout card material (albedo RGBA). Albedo + normal makes the Roblox importer
    emit a SurfaceAppearance, whose AlphaMode is then set to Transparency in Studio."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = albedo_img
    nt.links.new(t.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(t.outputs["Alpha"], bsdf.inputs["Alpha"])
    bsdf.inputs["Roughness"].default_value = rough
    if normal_img is not None:
        nmap = nt.nodes.new("ShaderNodeNormalMap")
        n = nt.nodes.new("ShaderNodeTexImage")
        n.image = normal_img
        nt.links.new(n.outputs["Color"], nmap.inputs["Color"])
        nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    if hasattr(mat, "surface_render_method"):
        mat.surface_render_method = "DITHERED"
    return mat


def image_material(name, albedo_img, normal_img=None, rough_img=None):
    mat = card_material(name, albedo_img, normal_img)
    nt = mat.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    for l in list(bsdf.inputs["Alpha"].links):
        nt.links.remove(l)
    if rough_img is not None:
        r = nt.nodes.new("ShaderNodeTexImage")
        r.image = rough_img
        nt.links.new(r.outputs["Color"], bsdf.inputs["Roughness"])
    return mat


def flat_normal(outdir, name, size=64):
    import numpy as np

    px = np.zeros((size * size, 4), np.float32)
    px[:] = (0.5, 0.5, 1.0, 1.0)
    img, _ = save_rgba(name, outdir, size, size, px)
    img.colorspace_settings.name = "Non-Color"
    return img


def quad(bm, uvl, corners, uv_rect):
    """One textured quad. corners: 4 Vectors (bl, br, tr, tl); uv_rect: (u0, v0, u1, v1)."""
    vs = [bm.verts.new(c) for c in corners]
    f = bm.faces.new(vs)
    u0, v0, u1, v1 = uv_rect
    for loop, uv in zip(f.loops, ((u0, v0), (u1, v0), (u1, v1), (u0, v1))):
        loop[uvl].uv = uv
    return f


def bent_card(bm, uvl, base, up, side, width, height, uv_rect, bend=0.0, rows=3):
    """Card subdivided along its height, tip bent along `bend` (vector added * u^2)."""
    u0, v0, u1, v1 = uv_rect
    prev = None
    for r in range(rows + 1):
        t = r / rows
        c = base + up * height * t + (bend * (t * t) if not isinstance(bend, float) else Vector())
        row = (bm.verts.new(c - side * width / 2), bm.verts.new(c + side * width / 2))
        if prev:
            f = bm.faces.new((prev[0], prev[1], row[1], row[0]))
            tp = (r - 1) / rows
            for loop, uv in zip(
                f.loops,
                ((u0, v0 + (v1 - v0) * tp), (u1, v0 + (v1 - v0) * tp), (u1, v0 + (v1 - v0) * t), (u0, v0 + (v1 - v0) * t)),
            ):
                loop[uvl].uv = uv
        prev = row


def import_gltf(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.data.objects if o not in before and o.type == "MESH"]


def decimate_to(obj, target_tris):
    t = triangles(obj)
    if t > target_tris:
        dec = obj.modifiers.new("dec", "DECIMATE")
        dec.ratio = target_tris / t
        dec.use_collapse_triangulate = True
        apply_modifiers(obj)
    return triangles(obj)


def bake_to_low(low, high, name, outdir, size=1024, passes=("albedo", "normal", "roughness"), extrusion=0.03):
    """Selected-to-active bake from a (scanned) high-poly onto the decimated low-poly."""
    scene = bpy.context.scene
    low.data.materials.clear()
    tmp = bpy.data.materials.new(name + "_tmp")
    tmp.use_nodes = True
    low.data.materials.append(tmp)
    nt = tmp.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage")
    nt.nodes.active = tex
    bpy.ops.object.select_all(action="DESELECT")
    high.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bs = scene.render.bake
    bs.use_selected_to_active = True
    bs.cage_extrusion = extrusion
    bs.max_ray_distance = extrusion * 4
    bs.margin = 8
    paths, images = {}, {}
    for kind in passes:
        img = bpy.data.images.new(f"{name}_{kind}", size, size, alpha=False)
        if kind != "albedo":
            img.colorspace_settings.name = "Non-Color"
        tex.image = img
        if kind == "albedo":
            bs.use_pass_direct = False
            bs.use_pass_indirect = False
            bs.use_pass_color = True
            bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"})
        elif kind == "normal":
            bs.normal_space = "TANGENT"
            bpy.ops.object.bake(type="NORMAL")
        else:
            bpy.ops.object.bake(type="ROUGHNESS")
        images[kind] = img
    bs.use_selected_to_active = False
    for kind, img in images.items():
        path = os.path.join(outdir, f"{name}_{kind}.png")
        img.filepath_raw = path
        img.file_format = "PNG"
        img.save()
        paths[kind] = path
    low.data.materials.clear()
    low.data.materials.append(
        image_material(name + "_baked", images["albedo"], images.get("normal"), images.get("roughness"))
    )
    return paths, images


def report(name, obj_list, paths, extra=None):
    tris = sum(triangles(o) for o in obj_list if o.type == "MESH")
    line = {"asset": name, "triangles": tris, **paths}
    if extra:
        line.update(extra)
    print("A2PILOT", repr(line))
    return line
