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
| brown_leather | scanned leather texture (albedo, nor_gl) | `gen_theropod_v2.py`, `gen_creatures.py` (skin micro-detail, box-projected) | https://polyhaven.com/a/brown_leather | CC0 1.0 |
| calathea_orbifolia_01 | scanned broadleaf model atlas | `gen_kits.py` | https://polyhaven.com/a/calathea_orbifolia_01 | CC0 1.0 |
| nettle_plant | scanned nettle atlas | `gen_kits.py` | https://polyhaven.com/a/nettle_plant | CC0 1.0 |
| wild_rooibos_bush | scanned bush atlas | `gen_kits.py` | https://polyhaven.com/a/wild_rooibos_bush | CC0 1.0 |
| rock_moss_set_01 | scanned rock model set | `gen_kits.py` (rock scan bake source) | https://polyhaven.com/a/rock_moss_set_01 | CC0 1.0 |
| namaqualand_boulder_02 | scanned boulder model | `gen_kits.py` (rock scan bake source) | https://polyhaven.com/a/namaqualand_boulder_02 | CC0 1.0 |
| coast_rocks_01 | scanned rock texture | `gen_nodes.py` | https://polyhaven.com/a/coast_rocks_01 | CC0 1.0 |
| dry_decay_leaves | scanned leaf-litter texture | `gen_kits.py`, `gen_nodes.py` | https://polyhaven.com/a/dry_decay_leaves | CC0 1.0 |
| coral_gravel | scanned gravel texture | `gen_kits.py` | https://polyhaven.com/a/coral_gravel | CC0 1.0 |
| clean_pebbles | scanned pebble texture | `gen_kits.py`, `gen_nodes.py` | https://polyhaven.com/a/clean_pebbles | CC0 1.0 |
| red_laterite_soil_stones | scanned soil texture | `gen_kits.py` | https://polyhaven.com/a/red_laterite_soil_stones | CC0 1.0 |
| bark_brown_02 | scanned bark texture | `gen_kits.py`, `gen_nodes.py` | https://polyhaven.com/a/bark_brown_02 | CC0 1.0 |
| bark_platanus | scanned bark texture | `gen_kits.py`, `gen_nodes.py` | https://polyhaven.com/a/bark_platanus | CC0 1.0 |
| bark_willow | scanned bark texture | `gen_kits.py` | https://polyhaven.com/a/bark_willow | CC0 1.0 |
| forest_leaves_02 | scanned leaf texture | `gen_kits.py` | https://polyhaven.com/a/forest_leaves_02 | CC0 1.0 |
| gravel_floor_02 | scanned gravel texture | `gen_kits.py`, `gen_nodes.py` | https://polyhaven.com/a/gravel_floor_02 | CC0 1.0 |
| dead_tree_trunk | scanned bark (diff, nor_gl) | B1b `gen_kit_swamp.py`, `gen_kit_biomes.py`, `gen_nodes_b1b.py` (dead, desert-snag, charred bark; rotting log) | https://polyhaven.com/a/dead_tree_trunk | CC0 1.0 |
| bark_willow | scanned bark (diff, nor_gl) | B1b swamp dark bark, tundra birch bark | https://polyhaven.com/a/bark_willow | CC0 1.0 |
| pine_bark | scanned bark (diff, nor_gl) | B1b tundra pine trunk | https://polyhaven.com/a/pine_bark | CC0 1.0 |
| fir_tree_01 | twig atlas only (diff, alpha) | B1b tundra pine needle cards (snow painted over) | https://polyhaven.com/a/fir_tree_01 | CC0 1.0 |
| brown_mud | ground scan (diff, nor_gl, rough) | B1b swamp mud stone, clay-bank node | https://polyhaven.com/a/brown_mud | CC0 1.0 |
| lichen_rock | rock scan (diff, nor_gl, rough) | B1b swamp stone, tundra boulder | https://polyhaven.com/a/lichen_rock | CC0 1.0 |
| sandstone_cracks | rock scan (diff, nor_gl, rough) | B1b desert sandstone chunk | https://polyhaven.com/a/sandstone_cracks | CC0 1.0 |
| rock_face | rock scan (diff, nor_gl, rough) | B1b desert wind boulder, tundra ice shards, ore-vein nodes | https://polyhaven.com/a/rock_face | CC0 1.0 |
| snow_02 | snow scan (diff, nor_gl, rough) | B1b tundra boulder snow cap | https://polyhaven.com/a/snow_02 | CC0 1.0 |
| dark_rock | rock scan (diff, nor_gl, rough) | B1b volcano basalt / obsidian, basalt-face node | https://polyhaven.com/a/dark_rock | CC0 1.0 |
| burned_ground_01 | ground scan (diff, nor_gl, rough) | B1b volcano lava crust, hot-spring rim, vent node | https://polyhaven.com/a/burned_ground_01 | CC0 1.0 |

B1b also reuses `shrub_04` (leaf clusters for swamp, desert, tundra bushes) and `palm_tree_bark` (cycad trunk). Cacti, agave, cycad fronds, grass/sedge/reed blades, twigs, moss strands, lichen, ash, sulfur and pebble textures are painted procedurally in `kit_b1b.py`.

Downloaded but not used in a shipped asset: `namaqualand_boulder_04`, `shrub_02`, `forest_floor`, `dead_tree_trunk`, `lambis_shell`. All are CC0 1.0 (polyhaven.com/a/<id>).

- Poly Haven licence page: https://polyhaven.com/license ("CC0").
- ambientCG (CC0) was searched for reptile/scale materials. It has no scale or reptile set, so it is not used.

## B3 buildings (`build_building_atlas.py`, `gen_buildings.py`)

Downloads go to `build/b3/src/<id>/{diff,nor,rough}.jpg` (1k tier, `https://api.polyhaven.com/files/<id>`). Each is graded into one tile of the shared 1024 building atlas. All geometry is authored in `gen_buildings.py`.

| Source asset | Atlas tile | URL | Licence |
|---|---|---|---|
| bark_brown_02 | log | https://polyhaven.com/a/bark_brown_02 | CC0 1.0 |
| old_planks_02 | plank | https://polyhaven.com/a/old_planks_02 | CC0 1.0 |
| reed_roof_04 | thatch | https://polyhaven.com/a/reed_roof_04 | CC0 1.0 |
| rough_linen | canvas, hide, teal cloth | https://polyhaven.com/a/rough_linen | CC0 1.0 |
| hessian_230 | rope | https://polyhaven.com/a/hessian_230 | CC0 1.0 |
| stacked_stone_wall | stone, char, sea-glass | https://polyhaven.com/a/stacked_stone_wall | CC0 1.0 |
| brick_wall_02 | brick | https://polyhaven.com/a/brick_wall_02 | CC0 1.0 |
| clay_plaster | clay | https://polyhaven.com/a/clay_plaster | CC0 1.0 |
| roof_slates_02 | slate | https://polyhaven.com/a/roof_slates_02 | CC0 1.0 |
| clay_roof_tiles_02 | tile | https://polyhaven.com/a/clay_roof_tiles_02 | CC0 1.0 |
| rusty_metal_02 | metal | https://polyhaven.com/a/rusty_metal_02 | CC0 1.0 |

## Original (procedural) content

These were authored in code and carry no third-party input:

- the frond, palm-boot and fruit textures (`gen_palm_v2.paint_frond`);
- the thin grass blades (`gen_tallgrass_scan.paint_blades`);
- the berry and claw colours;
- the theropod stripes, eyes, mouth line and nostrils;
- all meshes except the boulder bake source.

## Forbidden sources (AGENTS.md)

None of the following were used: AudioCraft weights, Roblox Cube, Hunyuan3D-2, Studio `generate_mesh` / `generate_texture` / `generate_material`.
