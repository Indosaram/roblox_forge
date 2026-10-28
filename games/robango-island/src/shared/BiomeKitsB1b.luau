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
		},
	} :: Kit,
}

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
