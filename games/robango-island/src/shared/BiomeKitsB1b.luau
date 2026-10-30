--!strict
-- B1b biome kit data (swamp, desert, tundra, volcano) plus the B1b resource nodes.
-- Data only: no loader lives here. B1a's scatter/loader resolves `package` through
-- Assets (generated from assets/manifest.yml), calls InsertService:LoadAsset once per
-- package at server start, finds each row's MeshPart by `model` inside the loaded
-- package Model and clones it as a template. Rows mirror the asset catalog
-- (.omo/plans/robango-durango-specs/asset-catalog.md); `density` is the per-default-zoom
-- screen target {min, max}; `hide` is the client cull distance in studs; `shadow` says
-- whether the prop casts shadows near the camera. Nodes carry a `full` and a `depleted`
-- model; the depleted one shows while the node respawns.

export type Family = "tree" | "shrub" | "fern" | "grass" | "rock" | "clutter"

export type Row = {
	key: string,
	model: string,
	family: Family,
	density: { number },
	hide: number,
	shadow: boolean,
	collide: boolean,
}

export type Kit = {
	package: string,
	terrain: { [string]: { number } },
	rows: { Row },
}

export type Node = {
	key: string,
	package: string,
	full: string,
	depleted: string,
	biomes: { string },
}

local function row(key: string, family: Family, lo: number, hi: number): Row
	local tall = family == "tree"
	local hide = if family == "grass" then 160 elseif family == "fern" or family == "clutter" then 256 else 512
	return {
		key = key,
		model = (string.gsub(string.gsub(key, "%.", "_"), "%-", "_")),
		family = family,
		density = { lo, hi },
		hide = hide,
		shadow = tall or family == "rock",
		collide = tall or family == "rock",
	}
end

local M = {}

-- Engine-free colour triple {r, g, b} (0-255) so Lune specs load this module; the Roblox side
-- builds Color3.fromRGB(table.unpack(c)) when it applies MaterialColors.
local function rgb(r: number, g: number, b: number): { number }
	return { r, g, b }
end

-- Terrain material colours per biome kit (MaterialColors overrides), tuned against R11.
M.kits = {
	swamp = {
		package = "robango-kit-swamp",
		terrain = {
			Mud = rgb(74, 61, 50),
			Grass = rgb(78, 80, 50),
			LeafyGrass = rgb(70, 74, 44),
			Ground = rgb(82, 70, 56),
		},
		rows = {
			row("veg.swamp.dead-bare", "tree", 2, 4),
			row("veg.swamp.mangrove", "tree", 1, 2),
			row("veg.swamp.mangrove-b", "tree", 0, 1),
			row("veg.swamp.cypress", "tree", 1, 1),
			row("veg.swamp.cypress-b", "tree", 0, 1),
			row("veg.swamp.swamp-bush", "shrub", 4, 8),
			row("veg.swamp.marsh-fern", "fern", 6, 10),
			row("veg.swamp.cordgrass", "grass", 20, 40),
			row("veg.swamp.sedge-card", "grass", 15, 30),
			row("rock.swamp.mud-stone", "rock", 2, 3),
			row("rock.swamp.rotting-log", "rock", 1, 3),
			row("clutter.swamp.litter", "clutter", 4, 8),
			-- Biome2 rows: no uniform scatter (density 0); BiomeKits.groves places them in clumps.
			row("veg.swamp.dead-lean", "tree", 0, 0),
			row("veg.swamp.reed-clump", "shrub", 0, 0),
		},
	} :: Kit,
	desert = {
		package = "robango-kit-desert",
		terrain = {
			Sand = rgb(178, 122, 82),
			Sandstone = rgb(166, 118, 76),
			Ground = rgb(160, 110, 74),
			Grass = rgb(150, 124, 80),
		},
		rows = {
			row("veg.desert.column-cactus", "tree", 3, 6),
			row("veg.desert.dead-snag", "tree", 1, 1),
			row("veg.desert.dead-snag-b", "tree", 0, 1),
			row("veg.desert.barrel-cactus", "shrub", 4, 8),
			row("veg.desert.dry-bush", "shrub", 8, 14),
			row("veg.desert.agave", "fern", 3, 6),
			row("veg.desert.sparse-dry", "grass", 10, 25),
			row("rock.desert.sandstone-chunk", "rock", 2, 4),
			row("rock.desert.wind-boulder", "rock", 1, 2),
			row("clutter.desert.creosote", "clutter", 4, 8),
			row("clutter.desert.pebbles", "clutter", 4, 8),
			row("clutter.desert.twig-litter", "clutter", 2, 4),
			row("veg.desert.scrub", "shrub", 0, 0),
			row("rock.desert.rock-cluster", "rock", 0, 0),
		},
	} :: Kit,
	tundra = {
		package = "robango-kit-tundra",
		terrain = {
			Snow = rgb(216, 221, 224),
			Glacier = rgb(170, 196, 208),
			Grass = rgb(150, 146, 120),
			Ground = rgb(110, 104, 92),
			Rock = rgb(110, 108, 102),
		},
		rows = {
			row("veg.tundra.snow-pine", "tree", 1, 3),
			row("veg.tundra.snow-pine-b", "tree", 1, 1),
			row("veg.tundra.dwarf-birch", "tree", 1, 2),
			row("veg.tundra.dwarf-birch-b", "tree", 0, 1),
			row("veg.tundra.frost-shrub", "shrub", 6, 10),
			row("veg.tundra.lichen-mat", "fern", 4, 8),
			row("veg.tundra.frost-tussock", "grass", 20, 40),
			row("rock.tundra.ice-boulder", "rock", 3, 5),
			row("rock.tundra.ice-shard", "rock", 1, 2),
			row("clutter.tundra.snow-patch", "clutter", 4, 8),
			row("veg.tundra.frozen-shrub", "shrub", 0, 0),
			row("rock.tundra.drift-mound", "rock", 0, 0),
		},
	} :: Kit,
	volcano = {
		package = "robango-kit-volcano",
		terrain = {
			Basalt = rgb(52, 48, 46),
			Ground = rgb(84, 64, 56),
			Grass = rgb(91, 58, 46),
			CrackedLava = rgb(150, 60, 30),
			Slate = rgb(70, 66, 62),
		},
		rows = {
			row("veg.volcano.charred", "tree", 1, 3),
			row("veg.volcano.charred-b", "tree", 1, 1),
			row("veg.volcano.survivor-cycad", "tree", 1, 3),
			row("veg.volcano.ash-scrub", "shrub", 6, 10),
			row("veg.volcano.sulfur-moss", "fern", 2, 6),
			row("veg.volcano.burnt-grass", "grass", 15, 30),
			row("rock.volcano.basalt-columns", "rock", 2, 3),
			row("rock.volcano.obsidian-boulder", "rock", 2, 3),
			row("rock.volcano.lava-crust", "rock", 1, 2),
			row("rock.volcano.hot-spring-rim", "rock", 0, 1),
			row("clutter.volcano.ash-patch", "clutter", 4, 8),
			row("rock.volcano.basalt-stack", "rock", 0, 0),
			row("rock.volcano.dead-stump", "rock", 0, 0),
			row("clutter.volcano.glow-crack", "clutter", 0, 0),
		},
	} :: Kit,
}

-- Biome2: LOD0 triangles per B1b MeshPart, from the generator logs (B1BKIT rows of
-- gen_kit_swamp.py / gen_kit_biomes.py). BiomeKits uses it to keep each island's kit triangles
-- inside the pre-biome2 total when it adds grove clumps.
M.tris = {
	clutter_desert_creosote = 196,
	clutter_desert_pebbles = 70,
	clutter_desert_twig_litter = 70,
	clutter_swamp_litter = 42,
	clutter_tundra_snow_patch = 70,
	clutter_volcano_ash_patch = 70,
	clutter_volcano_glow_crack = 26,
	rock_desert_rock_cluster = 80,
	rock_desert_sandstone_chunk = 960,
	rock_desert_wind_boulder = 640,
	rock_swamp_mud_stone = 400,
	rock_swamp_rotting_log = 204,
	rock_tundra_drift_mound = 80,
	rock_tundra_ice_boulder = 640,
	rock_tundra_ice_shard = 117,
	rock_volcano_basalt_columns = 160,
	rock_volcano_basalt_stack = 112,
	rock_volcano_dead_stump = 76,
	rock_volcano_hot_spring_rim = 1082,
	rock_volcano_lava_crust = 320,
	rock_volcano_obsidian_boulder = 320,
	veg_desert_agave = 336,
	veg_desert_barrel_cactus = 280,
	veg_desert_column_cactus = 496,
	veg_desert_dead_snag = 436,
	veg_desert_dead_snag_b = 460,
	veg_desert_dry_bush = 320,
	veg_desert_scrub = 80,
	veg_desert_sparse_dry = 80,
	veg_swamp_cordgrass = 128,
	veg_swamp_cypress = 1674,
	veg_swamp_cypress_b = 1490,
	veg_swamp_dead_bare = 1010,
	veg_swamp_dead_lean = 180,
	veg_swamp_mangrove = 1342,
	veg_swamp_mangrove_b = 1178,
	veg_swamp_marsh_fern = 480,
	veg_swamp_reed_clump = 56,
	veg_swamp_sedge_card = 112,
	veg_swamp_swamp_bush = 380,
	veg_tundra_dwarf_birch = 470,
	veg_tundra_dwarf_birch_b = 436,
	veg_tundra_frost_shrub = 208,
	veg_tundra_frost_tussock = 112,
	veg_tundra_frozen_shrub = 40,
	veg_tundra_lichen_mat = 70,
	veg_tundra_snow_pine = 556,
	veg_tundra_snow_pine_b = 388,
	veg_volcano_ash_scrub = 112,
	veg_volcano_burnt_grass = 112,
	veg_volcano_charred = 404,
	veg_volcano_charred_b = 428,
	veg_volcano_sulfur_moss = 70,
	veg_volcano_survivor_cycad = 184,
} :: { [string]: number }

local function node(key: string, biomes: { string }): Node
	local base = string.gsub(string.gsub(key, "%.", "_"), "%-", "_")
	return {
		key = key,
		package = "robango-nodes-b1b",
		full = base .. "_full",
		depleted = base .. "_depleted",
		biomes = biomes,
	}
end

M.nodes = {
	node("node.cattail-stand", { "swamp", "lake" }),
	node("node.clay-bank", { "swamp", "lake", "desert", "jungle" }),
	node("node.cordgrass-tussock", { "swamp", "beach" }),
	node("node.reed-bed", { "swamp", "lake" }),
	node("node.samphire-flat", { "swamp", "beach" }),
	node("node.iron-vein", { "desert", "tundra", "jungle", "volcano" }),
	node("node.copper-vein", { "desert", "grassland", "jungle" }),
	node("node.basalt-face", { "volcano", "tundra" }),
	node("node.volcanic-vent", { "volcano" }),
	node("node.charcoal-pit", { "volcano", "desert", "tundra", "jungle" }),
} :: { Node }

-- content biome tag -> B1b kit name (catalog section 2); B1a owns the other tags.
M.biomeKit = {
	swamp = "swamp",
	desert = "desert",
	snow = "tundra",
	volcano = "volcano",
}

return M
