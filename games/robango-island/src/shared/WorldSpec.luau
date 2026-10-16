--!strict
-- GENERATED from genre-spec.yml. Do not edit: edit the spec and regenerate.
export type World = { [string]: any }
local world: World = {
	["name"] = "World",
	["nodes"] = {
		[1] = {
			["control"] = "survival-coop:buy-defense",
			["id"] = "campfire",
			["kind"] = "station",
			["position"] = { [1] = 6 :: any, [2] = 1 :: any, [3] = 0 :: any } :: any,
			["zone"] = "camp",
		} :: any,
		[2] = {
			["id"] = "ridge-node",
			["kind"] = "node",
			["position"] = { [1] = 0 :: any, [2] = 1 :: any, [3] = -70 :: any } :: any,
			["version"] = 1,
			["zone"] = "ridge",
		} :: any,
	} :: any,
	["spawn"] = { ["offset"] = { [1] = 0 :: any, [2] = 1 :: any, [3] = 0 :: any } :: any, ["zone"] = "camp" } :: any,
	["zones"] = {
		[1] = {
			["center"] = { [1] = 0 :: any, [2] = 0 :: any, [3] = 0 :: any } :: any,
			["id"] = "camp",
			["kind"] = "plaza",
			["size"] = { [1] = 60 :: any, [2] = 1 :: any, [3] = 60 :: any } :: any,
		} :: any,
		[2] = {
			["center"] = { [1] = 0 :: any, [2] = 0 :: any, [3] = -70 :: any } :: any,
			["id"] = "ridge",
			["kind"] = "wild",
			["size"] = { [1] = 80 :: any, [2] = 1 :: any, [3] = 80 :: any } :: any,
		} :: any,
	} :: any,
}
return world
