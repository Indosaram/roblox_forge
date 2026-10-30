"""L6b survivor paint: per-slot procedural materials baked into ONE colour atlas per preset.

Used by gen_survivors.py. Everything is evaluated in rig space through the shader Position
(Blender X = rig x, Blender Y = -rig z, so the face looks toward +Y; Blender Z = rig y).
Roblox clients only receive the colour map (MeshTexture.bake moves it onto MeshPart.TextureContent),
so the form light, ambient occlusion, cloth folds and the face are painted into the albedo.
Patterns are woven-cloth only: pinstripe, check, herringbone-like tweed and denim twill. No camouflage
print, no insignia and no lettering.
"""

import math

import bpy
from mathutils import Vector

import common as C

# Soft key from above-front-left, the same direction the creature paint uses.
KEY = Vector((0.35, 0.6, 0.75)).normalized()


def _math(nodes, links, op, a, b=None, clamp=False):
    m = nodes.new("ShaderNodeMath")
    m.operation = op
    m.use_clamp = clamp
    for i, v in enumerate((a, b)):
        if v is None:
            continue
        if isinstance(v, (int, float)):
            m.inputs[i].default_value = v
        else:
            links.new(v, m.inputs[i])
    return m.outputs["Value"]


def _rgb(nodes, hexcol):
    n = nodes.new("ShaderNodeRGB")
    n.outputs["Color"].default_value = (*C.hexlin(hexcol), 1.0)
    return n.outputs["Color"]


def _mix(nodes, links, fac, a, b, blend="MIX"):
    m = nodes.new("ShaderNodeMix")
    m.data_type = "RGBA"
    m.blend_type = blend
    if isinstance(fac, (int, float)):
        m.inputs["Factor"].default_value = fac
    else:
        links.new(fac, m.inputs["Factor"])
    for sock, v in ((m.inputs[6], a), (m.inputs[7], b)):
        if isinstance(v, tuple):
            sock.default_value = (*v, 1.0)
        else:
            links.new(v, sock)
    return m.outputs[2]


def _scale_col(nodes, links, col, k):
    return _mix(nodes, links, 1.0, col, (k, k, k), "MULTIPLY")


def _xyz(nodes, links):
    geo = nodes.new("ShaderNodeNewGeometry")
    sep = nodes.new("ShaderNodeSeparateXYZ")
    links.new(geo.outputs["Position"], sep.inputs[0])
    return geo, sep.outputs["X"], sep.outputs["Y"], sep.outputs["Z"]


def _band(nodes, links, value, period, duty, soft=0.08):
    """1 inside a repeating stripe of width `duty` (0..1 of the period), else 0."""
    f = _math(nodes, links, "FRACT", _math(nodes, links, "DIVIDE", value, period))
    r = C.ramp(nodes, links, f, [(0.0, (1, 1, 1)), (duty, (1, 1, 1)), (min(duty + soft, 0.99), (0, 0, 0))])
    return r.outputs["Color"]


def _dist(nodes, links, x, y, z, centre, mirror=True, sx=1.0, sy=1.0, sz=1.0):
    """Scaled distance from (|x|, y, z) to centre (Blender coords)."""
    ax = _math(nodes, links, "ABSOLUTE", x) if mirror else x
    dx = _math(nodes, links, "MULTIPLY", _math(nodes, links, "SUBTRACT", ax, centre[0]), 1.0 / sx)
    dy = _math(nodes, links, "MULTIPLY", _math(nodes, links, "SUBTRACT", y, centre[1]), 1.0 / sy)
    dz = _math(nodes, links, "MULTIPLY", _math(nodes, links, "SUBTRACT", z, centre[2]), 1.0 / sz)
    comb = nodes.new("ShaderNodeCombineXYZ")
    links.new(dx, comb.inputs[0])
    links.new(dy, comb.inputs[1])
    links.new(dz, comb.inputs[2])
    ln = nodes.new("ShaderNodeVectorMath")
    ln.operation = "LENGTH"
    links.new(comb.outputs[0], ln.inputs[0])
    return ln.outputs["Value"]


def _spot(nodes, links, d, r_in, r_out):
    """1 inside r_in fading to 0 at r_out."""
    r = C.ramp(nodes, links, d, [(r_in, (1, 1, 1)), (r_out, (0, 0, 0))])
    return r.outputs["Color"]


def _shade(nodes, links, col, geo, ao_dist=0.18, key=0.5, dirt=True):
    """Painted form light + local occlusion + crease dirt (multiplicative, mean about 1)."""
    dot = nodes.new("ShaderNodeVectorMath")
    dot.operation = "DOT_PRODUCT"
    links.new(geo.outputs["Normal"], dot.inputs[0])
    dot.inputs[1].default_value = tuple(KEY)
    lo, hi = 1.0 - key * 0.55, 1.0 + key * 0.32
    shade = C.ramp(nodes, links, dot.outputs["Value"],
                   [(-0.3, (lo * 0.96, lo * 0.96, lo * 1.04)), (0.25, (1, 1, 1)), (0.9, (hi, hi * 0.98, hi * 0.93))])
    col = _mix(nodes, links, 1.0, col, shade.outputs["Color"], "MULTIPLY")
    ao = nodes.new("ShaderNodeAmbientOcclusion")
    ao.samples = 16
    ao.inputs["Distance"].default_value = ao_dist
    aor = C.ramp(nodes, links, ao.outputs["AO"], [(0.1, (0.45, 0.42, 0.42)), (0.9, (1, 1, 1))])
    col = _mix(nodes, links, 1.0, col, aor.outputs["Color"], "MULTIPLY")
    if dirt:
        pr = C.ramp(nodes, links, geo.outputs["Pointiness"],
                    [(0.42, (0.7, 0.66, 0.62)), (0.5, (1, 1, 1)), (0.58, (1.1, 1.08, 1.05))])
        col = _mix(nodes, links, 1.0, col, pr.outputs["Color"], "MULTIPLY")
    return col


def _folds(nodes, links, col, x, y, z, strength=0.22, vertical=True, scale=7.0):
    """Soft cloth folds: noise stretched along the limb (mostly vertical drape)."""
    comb = nodes.new("ShaderNodeCombineXYZ")
    links.new(x, comb.inputs[0])
    links.new(y, comb.inputs[1])
    links.new(_math(nodes, links, "MULTIPLY", z, 0.25 if vertical else 1.0), comb.inputs[2])
    n = C.noise(nodes, scale, 3.0, 0.5, comb.outputs[0], links)
    f = C.ramp(nodes, links, n.outputs["Fac"],
               [(0.3, (1 - strength,) * 3), (0.55, (1, 1, 1)), (0.75, (1 + strength * 0.4,) * 3)])
    return _mix(nodes, links, 1.0, col, f.outputs["Color"], "MULTIPLY")


def _grain(nodes, links, col, scale, strength, geo):
    n = C.noise(nodes, scale, 8.0, 0.7, geo.outputs["Position"], links)
    f = C.ramp(nodes, links, n.outputs["Fac"], [(0.35, (1 - strength,) * 3), (0.65, (1 + strength,) * 3)])
    return _mix(nodes, links, 1.0, col, f.outputs["Color"], "MULTIPLY")


def cloth(pal, slot, look):
    """look: {"pattern": None|"pinstripe"|"check"|"tweed"|"denim"|"canvas", "accent": hex}."""

    def build(nodes, links):
        geo, x, y, z = _xyz(nodes, links)
        base = _rgb(nodes, pal[slot])
        pat = look.get("pattern")
        acc = look.get("accent")
        col = base
        u = _math(nodes, links, "ADD", x, y)  # runs around the body: front uses x, sides use y
        if pat == "pinstripe":
            col = _mix(nodes, links, _band(nodes, links, u, 0.07, 0.16), col, _rgb(nodes, acc))
        elif pat == "check":
            a = _band(nodes, links, u, 0.16, 0.42)
            b = _band(nodes, links, z, 0.16, 0.42)
            both = _mix(nodes, links, 1.0, a, b, "MULTIPLY")
            one = _mix(nodes, links, 0.5, a, b)
            col = _mix(nodes, links, one, col, _rgb(nodes, acc))
            col = _mix(nodes, links, both, col, _scale_col(nodes, links, _rgb(nodes, acc), 0.62))
            thin = _band(nodes, links, _math(nodes, links, "ADD", u, 0.08), 0.16, 0.06)
            col = _mix(nodes, links, _mix(nodes, links, 0.6, thin, (0, 0, 0)), col, (0.85, 0.8, 0.68))
        elif pat == "tweed":
            col = _grain(nodes, links, col, 420.0, 0.22, geo)
            col = _mix(nodes, links, _mix(nodes, links, 0.35, _band(nodes, links, _math(nodes, links, "ADD", u, z), 0.035, 0.5), (0, 0, 0)),
                       col, _rgb(nodes, acc))
        elif pat == "denim":
            tw = _band(nodes, links, _math(nodes, links, "SUBTRACT", u, z), 0.018, 0.45, 0.3)
            col = _mix(nodes, links, _mix(nodes, links, 0.18, tw, (0, 0, 0)), col, (0.5, 0.56, 0.64))
            col = _grain(nodes, links, col, 300.0, 0.12, geo)
        elif pat == "canvas":
            col = _grain(nodes, links, col, 260.0, 0.1, geo)
        col = _grain(nodes, links, col, 900.0, 0.06, geo)  # weave
        col = _folds(nodes, links, col, x, y, z, 0.2 if slot not in ("belt", "braces", "band") else 0.05)
        # Pointiness is unreliable on these low-poly shells (it bleached whole pieces), so the
        # cloth gets form light and occlusion only.
        col = _shade(nodes, links, col, geo, dirt=False)
        return col, None, None

    return build


def leather(pal, slot, buckle=False):
    def build(nodes, links):
        geo, x, y, z = _xyz(nodes, links)
        col = _grain(nodes, links, _rgb(nodes, pal[slot]), 120.0, 0.18, geo)
        scuff = C.noise(nodes, 18.0, 4.0, 0.6, geo.outputs["Position"], links)
        sr = C.ramp(nodes, links, scuff.outputs["Fac"], [(0.62, (0, 0, 0)), (0.72, (0.55, 0.55, 0.55))])
        col = _mix(nodes, links, sr.outputs["Color"], col, (0.62, 0.52, 0.4))
        if slot == "boots":
            # Darker welt and sole at the floor.
            sole = C.ramp(nodes, links, z, [(-2.34, (1, 1, 1)), (-2.29, (0, 0, 0))])
            col = _mix(nodes, links, sole.outputs["Color"], col, _rgb(nodes, "#1e1712"))
            # Laces: a short ladder down the front of the boot.
            front = C.ramp(nodes, links, y, [(0.04, (0, 0, 0)), (0.08, (1, 1, 1))])
            lace = _band(nodes, links, z, 0.06, 0.3)
            ax = _math(nodes, links, "ABSOLUTE", _math(nodes, links, "SUBTRACT", _math(nodes, links, "ABSOLUTE", x), 0.2))
            mid = C.ramp(nodes, links, ax, [(0.025, (1, 1, 1)), (0.04, (0, 0, 0))])
            m = _mix(nodes, links, 1.0, _mix(nodes, links, 1.0, front.outputs["Color"], lace, "MULTIPLY"), mid.outputs["Color"], "MULTIPLY")
            col = _mix(nodes, links, _mix(nodes, links, 0.6, m, (0, 0, 0)), col, (0.42, 0.34, 0.24))
        if buckle:
            d = _dist(nodes, links, x, y, z, (0.0, 0.3, 0.07), sx=1.0, sy=3.0, sz=0.8)
            col = _mix(nodes, links, _spot(nodes, links, d, 0.045, 0.055), col, (0.62, 0.55, 0.38))
        col = _shade(nodes, links, col, geo, key=0.6, dirt=False)
        return col, None, None

    return build


def skin(pal, head_s, cy=1.95, lip="#9a5a4a"):
    """Skin with a painted face: warm cheeks/nose/ears, eye sockets, lid line, lips, jaw shade."""
    s = head_s

    def build(nodes, links):
        geo, x, y, z = _xyz(nodes, links)
        col = _rgb(nodes, pal["skin"])
        col = _grain(nodes, links, col, 200.0, 0.05, geo)
        warm = _rgb(nodes, "#b8604c")
        cheek = _spot(nodes, links, _dist(nodes, links, x, y, z, (0.1 * s, 0.17 * s, cy - 0.05)), 0.02, 0.08)
        col = _mix(nodes, links, _mix(nodes, links, 0.35, cheek, (0, 0, 0)), col, warm)
        nose = _spot(nodes, links, _dist(nodes, links, x, y, z, (0.0, 0.25 * s, cy - 0.03), mirror=False), 0.015, 0.05)
        col = _mix(nodes, links, _mix(nodes, links, 0.3, nose, (0, 0, 0)), col, warm)
        ear = _spot(nodes, links, _dist(nodes, links, x, y, z, (0.19 * s, -0.02, cy)), 0.02, 0.06)
        col = _mix(nodes, links, _mix(nodes, links, 0.3, ear, (0, 0, 0)), col, warm)
        # Eye sockets and an upper-lid line: the face reads as two dark marks at play distance.
        sock = _spot(nodes, links, _dist(nodes, links, x, y, z, (0.075 * s, 0.2 * s, cy + 0.045), sz=0.75), 0.04, 0.085)
        col = _mix(nodes, links, _mix(nodes, links, 0.7, sock, (0, 0, 0)), col, _scale_col(nodes, links, _rgb(nodes, pal["skin"]), 0.45))
        lid = _spot(nodes, links, _dist(nodes, links, x, y, z, (0.075 * s, 0.2 * s, cy + 0.068), sz=0.35), 0.03, 0.04)
        col = _mix(nodes, links, lid, col, _rgb(nodes, "#2a1d16"))
        mouth = _spot(nodes, links, _dist(nodes, links, x, y, z, (0.0, 0.2 * s, cy - 0.12 * s), mirror=False, sz=0.3), 0.04, 0.055)
        col = _mix(nodes, links, _mix(nodes, links, 0.75, mouth, (0, 0, 0)), col, _rgb(nodes, lip))
        # Neck and under-jaw in shade.
        jaw = C.ramp(nodes, links, z, [(cy - 0.32, (0.72, 0.68, 0.68)), (cy - 0.2, (1, 1, 1))])
        col = _mix(nodes, links, 1.0, col, jaw.outputs["Color"], "MULTIPLY")
        col = _shade(nodes, links, col, geo, ao_dist=0.1, key=0.45, dirt=False)
        return col, None, None

    return build


def eye(pal, head_s, cy=1.95):
    """Eyeball: off-white sclera, a large dark iris and pupil facing forward, a baked catchlight."""
    s = head_s

    def build(nodes, links):
        geo, x, y, z = _xyz(nodes, links)
        col = _rgb(nodes, "#e8e0d2")
        c = (0.07 * s, 0.0, cy + 0.045)
        d = _dist(nodes, links, x, y, z, c, sy=100.0)
        col = _mix(nodes, links, _spot(nodes, links, d, 0.017, 0.021), col, _rgb(nodes, pal.get("iris", "#4a3220")))
        col = _mix(nodes, links, _spot(nodes, links, d, 0.008, 0.011), col, (0.01, 0.008, 0.006))
        hl = _dist(nodes, links, x, y, z, (c[0] - 0.007, 0.0, c[2] + 0.008), sy=100.0)
        col = _mix(nodes, links, _spot(nodes, links, hl, 0.003, 0.005), col, (1, 1, 1))
        top = C.ramp(nodes, links, z, [(cy + 0.05, (1, 1, 1)), (cy + 0.075, (0.45, 0.42, 0.4))])
        col = _mix(nodes, links, 1.0, col, top.outputs["Color"], "MULTIPLY")
        return col, None, None

    return build


def hair(pal, slot="hair"):
    def build(nodes, links):
        geo, x, y, z = _xyz(nodes, links)
        base = _rgb(nodes, pal[slot])
        comb = nodes.new("ShaderNodeCombineXYZ")
        links.new(_math(nodes, links, "MULTIPLY", x, 30.0), comb.inputs[0])
        links.new(_math(nodes, links, "MULTIPLY", y, 30.0), comb.inputs[1])
        links.new(_math(nodes, links, "MULTIPLY", z, 3.0), comb.inputs[2])
        n = C.noise(nodes, 6.0, 6.0, 0.6, comb.outputs[0], links)
        strands = C.ramp(nodes, links, n.outputs["Fac"], [(0.3, (0.6, 0.6, 0.6)), (0.5, (1, 1, 1)), (0.7, (1.35, 1.3, 1.2))])
        col = _mix(nodes, links, 1.0, base, strands.outputs["Color"], "MULTIPLY")
        col = _shade(nodes, links, col, geo, ao_dist=0.08, key=0.7, dirt=False)
        return col, None, None

    return build


def flat(hexcol, key=0.4):
    def build(nodes, links):
        geo, _x, _y, _z = _xyz(nodes, links)
        return _shade(nodes, links, _rgb(nodes, hexcol), geo, key=key, dirt=False), None, None

    return build


def material_for(slot, preset_name, pal, looks, head_s):
    """Node material for one slot of one preset."""
    name = f"{slot}.{preset_name}"
    if slot == "anchor":
        return C.material(name, flat("#808080"))
    if slot == "skin":
        return C.material(name, skin(pal, head_s, lip=pal.get("lip", "#9a5a4a")))
    if slot == "eye":
        return C.material(name, eye(pal, head_s))
    if slot in ("hair", "brow"):
        return C.material(name, hair(pal, "hair" if slot == "hair" else "brow"))
    if slot == "lip":
        return C.material(name, flat(pal.get("lip", "#9a5a4a")))
    if slot in ("boots", "belt", "braces"):
        return C.material(name, leather(pal, slot, buckle=slot == "belt"))
    return C.material(name, cloth(pal, slot, looks.get(slot, {})))


def bake_atlas(objs, name, outdir, size=1024, hide=()):
    """Smart-projects all pieces of one preset into one UV space and bakes their colour into one image.
    Every piece then shares one image material (the FBX embeds it once)."""
    for o in hide:
        o.hide_render = True
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.004)
    bpy.ops.object.mode_set(mode="OBJECT")
    img = bpy.data.images.new(f"{name}_albedo", size, size, alpha=False)
    seen = set()
    for o in objs:
        for slot in o.material_slots:
            m = slot.material
            if m.name in seen:
                continue
            seen.add(m.name)
            t = m.node_tree.nodes.new("ShaderNodeTexImage")
            t.image = img
            m.node_tree.nodes.active = t
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 16
    scene.render.bake.margin = 4
    scene.render.bake.use_pass_direct = False
    scene.render.bake.use_pass_indirect = False
    scene.render.bake.use_pass_color = True
    bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"})
    path = f"{outdir}/{name}_albedo.png"
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    baked = bpy.data.materials.new(f"{name}_baked")
    baked.use_nodes = True
    nt = baked.node_tree
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = img
    nt.links.new(t.outputs["Color"], nt.nodes["Principled BSDF"].inputs["Base Color"])
    nt.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.85
    for o in objs:
        o.data.materials.clear()
        o.data.materials.append(baked)
    for o in hide:
        o.hide_render = False
    return path
