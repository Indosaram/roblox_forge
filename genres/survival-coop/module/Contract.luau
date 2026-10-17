--!strict
local Shared = require("../../../core/domain/genre/Contract")
local Mode = require("./Mode")
local GardenDefense = require("./GardenDefense")
local Schema = require("../../../core/infra/net/Schema")
local id = Schema.string({ maxLen = 128, pattern = ".+" })
local quantity = Schema.number({ min = 1, max = 1000, integer = true })
local version = Schema.number({ min = 0, max = 2 ^ 53 - 2, integer = true })
local vital = Schema.number({ min = 0, max = 100000, integer = true })
local coordinate = Schema.number({ min = 0, max = 31, integer = true })
local rotation = Schema.number({ min = 0, max = 3, integer = true })
local contract: Shared.RuntimeContract = {
	api = 1,
	id = "survival-coop",
	-- The genre envelope stays at 1: Construction/Executor accept only envelope
	-- version 1, and a mode is selected *inside* a pack config rather than by a
	-- new envelope. Per-mode action/save/content versions live in the capability
	-- descriptors (module/Capabilities.luau) and in each save's version marker.
	configVersion = 1,
	saveVersion = 1,
	actions = {
		{ id = "attack", args = { id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "gather", args = { id, version }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{
			id = "transfer-deposit",
			args = { id, quantity },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "transfer-withdraw",
			args = { id, quantity },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{ id = "vitals-damage", args = { vital }, origin = "server", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "rest-stop", args = {}, origin = "server", rate = { capacity = 5, refillPerSecond = 2 } },
		{
			id = "settlement-invite",
			args = { id, version, version },
			origin = "server",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "settlement-leave",
			args = { id, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "settlement-kick",
			args = { id, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "settlement-transfer-owner",
			args = { id, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "settlement-rejoin",
			args = { id, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "settlement-reserve",
			args = { id, coordinate, coordinate, rotation, version, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "settlement-place",
			args = { id, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "settlement-cancel",
			args = { id, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "settlement-demolish",
			args = { id, version, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{ id = "server-vitals-tick", args = {}, origin = "server", rate = { capacity = 5, refillPerSecond = 2 } },
		{
			id = "settlement-workshop-reserve",
			args = { id, id, version, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "settlement-workshop-start",
			args = { id, id, version, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "settlement-workshop-complete",
			args = { id, id, version, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "settlement-workshop-cancel",
			args = { id, id, version, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{ id = "death-drop", args = {}, origin = "server", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "death-pickup", args = { id }, origin = "server", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "death-expire", args = { id }, origin = "server", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "craft-reserve", args = { id, id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "craft-start", args = { id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "craft-complete", args = { id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "craft-cancel", args = { id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "buy-defense", args = {}, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "defend-active", args = {}, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "tame-hit", args = { id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "tame-capture", args = { id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "tame-feed", args = { id, id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "tame-mount", args = { id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "tame-dismount", args = {}, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "food", args = { id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{
			id = "rest",
			args = { Schema.string({ maxLen = 64, pattern = ".+" }) },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "respawn",
			args = { Schema.number({ min = 1, max = 100000, integer = true }), vital, vital },
			origin = "server",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "inventory-move",
			args = { id, id, id, quantity, id, version, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "inventory-split",
			args = { id, id, quantity, id, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "inventory-merge",
			args = { id, id, id, quantity, version },
			origin = "client",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "inventory-reserve",
			args = { id, id, id, quantity, version },
			origin = "server",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "inventory-release",
			args = { id, id, version },
			origin = "server",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{
			id = "inventory-consume",
			args = { id, id, quantity, version },
			origin = "server",
			rate = { capacity = 5, refillPerSecond = 2 },
		},
		{ id = "shop-prompt", args = { id }, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
		{ id = "shop-sync", args = {}, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
	},
	-- Action ids served by module/Extensions factories. Each id must also be declared in
	-- `actions` above; `forge codegen <pack> --durable` adds it to the pack's durable policy.
	extensionActions = {
		"tame-hit",
		"tame-capture",
		"tame-feed",
		"tame-mount",
		"tame-dismount",
		"shop-prompt",
		"shop-sync",
	},
	events = { "OnWaveSpawn", "OnWaveResolved", "DefenseBought" },
	hooks = { "OnWaveSpawn", "OnWaveResolved", "DefenseBought" },
	validateConfig = Mode.validateConfig,
	validateSave = Mode.validateSave,
	recipe = GardenDefense.recipe,
	create = Mode.create,
}
return contract
