"""Boulder (approach 1, photoscan): Poly Haven boulder_01 (CC0) -> decimate <3k tris -> bake
albedo/normal/roughness 1024 from the full scan -> grade albedo to the Robango rock palette.

Needs build/a2b/src/boulder_01/ (see SOURCES.md). Run from the repo root.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy

import common as C

SEED = 4202
NAME = "RobangoBoulderScan"
TARGET_TRIS = 700  # asset-catalog rock.grassland.grey-boulder / pilot.boulder
SIZE_M = 2.6  # longest horizontal extent in metres (x2.9 in Studio -> ~7.5 studs)


def main():
    outdir = C.out_dir()
    C.reset(SEED)
    parts = C.import_gltf(os.path.join(C.SRC_DIR, "boulder_01", "boulder_01.gltf"))
    high = C.join(parts, "high") if len(parts) > 1 else parts[0]
    bpy.ops.object.select_all(action="DESELECT")
    high.select_set(True)
    bpy.context.view_layer.objects.active = high
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    dims = high.dimensions
    s = SIZE_M / max(dims.x, dims.y)
    high.scale = (s, s, s)
    bpy.ops.object.transform_apply(scale=True)
    # Sit the scan on z=0.
    zmin = min(v.co.z for v in high.data.vertices)
    for v in high.data.vertices:
        v.co.z -= zmin
    low = high.copy()
    low.data = high.data.copy()
    low.name = NAME
    C.link(low)
    low.modifiers.clear()
    # glTF splits verts at UV seams -> open boundaries that block collapse decimation. Weld + drop UVs.
    import bmesh

    bm = bmesh.new()
    bm.from_mesh(low.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.002)
    bm.to_mesh(low.data)
    bm.free()
    while low.data.uv_layers:
        low.data.uv_layers.remove(low.data.uv_layers[0])
    tris = C.decimate_to(low, TARGET_TRIS)
    if tris > 760:
        tris = C.decimate_to(low, TARGET_TRIS)
    C.finish_mesh(low)
    C.unwrap(low, 0.01)
    maps, images = C.bake_to_low(low, high, NAME, outdir, size=512, extrusion=0.04)
    # Grade: the scan is a warm red-brown; pull it toward the ochre-grey rock palette, keep detail.
    img = images["albedo"]
    px, w, h = C.image_array(img)
    # Byte images expose stored (sRGB-encoded) values through .pixels: grade them directly.
    px = C.grade_pixels(px, "rock_mid", strength=0.8, sat=0.6)
    img.pixels.foreach_set(px.ravel())
    img.save()
    bpy.data.objects.remove(high)
    sil = C.silhouette(NAME, outdir, [low])
    pv = C.preview(NAME, outdir, [low])
    fbx = C.export_fbx(NAME, outdir, [low])
    C.report(NAME, [low], {"fbx": fbx, "preview": pv, "silhouettes": sil, **maps}, {"seed": SEED, "tris": tris})


main()
