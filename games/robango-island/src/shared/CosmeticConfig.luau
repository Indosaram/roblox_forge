--!strict
-- Robango Island paid cosmetics: what each sold cosmetic set looks like (genre CosmeticVisual).
-- Every cosmeticSetId in game.yml `monetization` must have an entry here (cosmetics.spec.luau).
-- Appearance only: no entry may carry speed, carry or any gameplay value.
local CosmeticVisual = require("../../../../genres/survival-coop/module/CosmeticVisual")
local config: CosmeticVisual.Config = {
	mountSkins = {
		-- "Ridge Strider" is the gold breed of the Gallimimus, the long-legged strider of the 24
		-- rideable species. The saved skin id stays `ridge-strider-gold` so owners keep it.
		["ridge-strider-gold"] = {
			species = "gallimimus",
			body = { r = 226, g = 180, b = 58 },
			accent = { r = 132, g = 40, b = 36 },
			belly = { r = 252, g = 236, b = 176 },
			marking = { r = 118, g = 78, b = 22 },
			sheen = 0.3,
			parts = { "stripes", "saddle" },
		},
	},
	wear = {
		-- Route Guild monthly set: a guild cloak with a gold clasp and a back banner.
		["route-guild-monthly"] = {
			slot = "back",
			pieces = {
				{
					id = "cloak",
					part = "UpperTorso",
					fallback = "Torso",
					size = { 2.1, 2.6, 0.18 },
					offset = { 0, -0.55, 0.62 },
					color = { r = 28, g = 74, b = 112 },
					material = "Fabric",
				},
				{
					id = "clasp",
					part = "UpperTorso",
					fallback = "Torso",
					size = { 0.5, 0.5, 0.2 },
					offset = { 0, 0.6, -0.55 },
					color = { r = 232, g = 186, b = 64 },
					material = "Foil",
				},
				{
					id = "banner-pole",
					part = "UpperTorso",
					fallback = "Torso",
					size = { 0.16, 4.2, 0.16 },
					offset = { 0.75, 1.3, 0.9 },
					color = { r = 104, g = 72, b = 40 },
					material = "Wood",
				},
				{
					id = "banner",
					part = "UpperTorso",
					fallback = "Torso",
					size = { 1.3, 1, 0.08 },
					offset = { 1.45, 2.9, 0.9 },
					color = { r = 232, g = 186, b = 64 },
					material = "Fabric",
				},
			},
		},
	},
}
return config
