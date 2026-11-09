--!strict
-- GENERATED from genre-spec.yml. Do not edit: edit the spec and regenerate.
export type World = { [string]: any }
local world: World = {
	["name"] = "World",
	["nodes"] = {
		[1] = {
			["control"] = "grow-harvest:seed-shop",
			["feedback"] = {
				[1] = {
					["cue"] = "grow-harvest-buy",
					["field"] = "balance",
					["kind"] = "counter",
					["label"] = "Coins",
					["labelKey"] = "fb_coins",
				} :: any,
			} :: any,
			["id"] = "seed-crate",
			["kind"] = "station",
			["position"] = { [1] = 0 :: any, [2] = 1 :: any, [3] = 6 :: any } :: any,
			["zone"] = "farm",
		} :: any,
		[2] = {
			["feedback"] = {
				[1] = {
					["cue"] = "grow-harvest-plant",
					["entity"] = "carrot",
					["field"] = "plots.1",
					["kind"] = "growth",
					["label"] = "Crop",
					["labelKey"] = "fb_crop",
				} :: any,
			} :: any,
			["id"] = "plot-a",
			["kind"] = "node",
			["position"] = { [1] = 8 :: any, [2] = 1 :: any, [3] = 0 :: any } :: any,
			["version"] = 1,
			["zone"] = "farm",
		} :: any,
		[3] = {
			["control"] = "grow-harvest:sell",
			["feedback"] = {
				[1] = {
					["cue"] = "grow-harvest-sell",
					["field"] = "balance",
					["kind"] = "counter",
					["label"] = "Coins",
					["labelKey"] = "fb_coins",
				} :: any,
			} :: any,
			["id"] = "market-stall",
			["kind"] = "depot",
			["position"] = { [1] = 22 :: any, [2] = 1 :: any, [3] = 0 :: any } :: any,
			["zone"] = "farm",
		} :: any,
	} :: any,
	["spawn"] = { ["offset"] = { [1] = 0 :: any, [2] = 1 :: any, [3] = 0 :: any } :: any, ["zone"] = "farm" } :: any,
	["zones"] = {
		[1] = {
			["center"] = { [1] = 0 :: any, [2] = 0 :: any, [3] = 0 :: any } :: any,
			["id"] = "farm",
			["kind"] = "plaza",
			["size"] = { [1] = 60 :: any, [2] = 1 :: any, [3] = 60 :: any } :: any,
		} :: any,
		[2] = {
			["center"] = { [1] = 40 :: any, [2] = 0 :: any, [3] = 0 :: any } :: any,
			["id"] = "market",
			["kind"] = "base",
			["size"] = { [1] = 24 :: any, [2] = 1 :: any, [3] = 24 :: any } :: any,
			["team"] = "traders",
		} :: any,
	} :: any,
}
return world
