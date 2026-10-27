# Robango Island Blender generators: third-party sources and licences

Every external input used by the `gen_*.py` generators in this directory is listed here. All of it is **CC0 1.0** (public domain dedication: commercial use allowed, no attribution required). It is recorded anyway for provenance. No AI generative models were used.

- Downloads go to `build/a2b/src/<asset>/` (gitignored).
- The generators read from there (`common.SRC_DIR`).
- Downloads come from the 1k tier of the Poly Haven API: `https://api.polyhaven.com/files/<id>`.

| Source asset | Kind | Used by | URL | Licence |
|---|---|---|---|---|
| boulder_01 | photoscanned rock model (124k tris) + textures | `gen_boulder_scan.py` (high-poly bake source) | https://polyhaven.com/a/boulder_01 | CC0 1.0 |
| fern_02 | scanned fern model + alpha leaf atlas (diff, alpha, nor_gl) | `gen_fern_scan.py` (atlas only; geometry rebuilt) | https://polyhaven.com/a/fern_02 | CC0 1.0 |
| grass_medium_01 | scanned grass atlas (diff, alpha) | `gen_tallgrass_scan.py` (tufts, seed heads) | https://polyhaven.com/a/grass_medium_01 | CC0 1.0 |
| shrub_04 | scanned shrub leaf atlas (diff, alpha, nor_gl) | `gen_berrybush.py` (single leaves stamped into cluster tiles) | https://polyhaven.com/a/shrub_04 | CC0 1.0 |
| palm_tree_bark | scanned bark texture (diff, nor_gl) | `gen_palm_v2.py` (trunk half of the atlas) | https://polyhaven.com/a/palm_tree_bark | CC0 1.0 |
| brown_leather | scanned leather texture (albedo, nor_gl) | `gen_theropod_v2.py` (skin micro-detail, box-projected) | https://polyhaven.com/a/brown_leather | CC0 1.0 |

Downloaded but not used in a shipped asset: `namaqualand_boulder_04`, `shrub_02`, `forest_floor`. All three are CC0 1.0 (polyhaven.com/a/<id>).

- Poly Haven licence page: https://polyhaven.com/license ("CC0").
- ambientCG (CC0) was searched for reptile/scale materials. It has no scale or reptile set, so it is not used.

## Original (procedural) content

These were authored in code and carry no third-party input:

- the frond, palm-boot and fruit textures (`gen_palm_v2.paint_frond`);
- the thin grass blades (`gen_tallgrass_scan.paint_blades`);
- the berry and claw colours;
- the theropod stripes, eyes, mouth line and nostrils;
- all meshes except the boulder bake source.

## Forbidden sources (AGENTS.md)

None of the following were used: AudioCraft weights, Roblox Cube, Hunyuan3D-2, Studio `generate_mesh` / `generate_texture` / `generate_material`.
