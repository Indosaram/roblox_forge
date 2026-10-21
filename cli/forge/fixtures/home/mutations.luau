--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Catalog = require("../../../../core/domain/inventory/ItemCatalog")
local Capacity = require("../../../../core/domain/survival/CapacityPolicy")
local Rng = require("../../../../core/domain/random/Rng")
local original = fs.readFile("core/domain/home/HomeState.luau")
local specs = fs.readFile("core/domain/home/HomeState.spec.luau")
local mutations = {
	{ "wrong-home-token", "if homeId ~= state.homeId then", "if false then" },
	{ "nonmember-harvest-recover", 'return nil, "FORBIDDEN"', "-- removed authorization refusal" },
	{ "double-harvest", 'return nil, "EMPTY_PLOT"', "return state, nil" },
	{ "growth-clock", "if ctx.now < planted.readyAt then", "if false then" },
	{ "occupied-plot", "if state.plots[args.plot] ~= nil then", "if false then" },
	{ "offline-owner", "return member and (facts.ownerOnline == true or acl.offlineCoop == true)", "return member" },
	{ "real-friendship", "and facts.friend == true", "" },
	{ "clan-membership", "facts.clanId == acl.clanId", "true" },
	{ "unknown-friend", "acl.friends[actor] == true", "true" },
	{ "skill-node", "if ctx.nodes[node] ~= true then", "if false then" },
	{ "seed-identity", "seedItem.catalogId ~= crop.seed", "false" },
	{
		"missing-water",
		"return nil, reason\n\t\t\t\tend\n\t\t\t\tout.storage = storage",
		"return state, nil\n\t\t\t\tend\n\t\t\t\tout.storage = storage",
	},
	{ "land-boundary", "math.abs(position.x) + definition.halfSize > half", "false" },
	{ "unearned-expansion", "state.landRank >= state.developmentRank", "false" },
	{ "dock-required", "args.atDock ~= true", "false" },
	{ "unknown-action", 'return nil, "UNKNOWN_ACTION"', "return state, nil" },
	{ "wrong-home-load", "saved.homeId == M.identity(owner) and saved.owner == owner", "true" },
	{ "overflow-capacity", "out.storageSlots = slots", "out.storageSlots = 45" },
	{ "duplicate-placement", "or state.structures[args.id]", "or false" },
	{ "double-recovery", 'return nil, "UNKNOWN_STRUCTURE"', "return state, nil" },
}
for _, mutation in mutations do
	local start, finish = string.find(original, mutation[2], 1, true)
	assert(start and finish, "mutation target missing: " .. mutation[1])
	assert(not string.find(original, mutation[2], finish + 1, true), "mutation target ambiguous: " .. mutation[1])
	local source = string.sub(original, 1, start - 1) .. mutation[3] .. string.sub(original, finish + 1)
	local mutant = luau.load(source, {
		environment = {
			require = function(path): any
				if string.find(path, "Inventory", 1, true) then
					return Inventory
				end
				if string.find(path, "CapacityPolicy", 1, true) then
					return Capacity
				end
				return Rng
			end,
		},
	})()
	local tests = luau.load(specs, {
		environment = {
			require = function(path)
				if path == "./HomeState" then
					return mutant
				end
				if string.find(path, "ItemCatalog", 1, true) then
					return Catalog
				end
				return Inventory
			end,
		},
	})()
	local killed = false
	for _, test in tests do
		if not pcall(test) then
			killed = true
		end
	end
	assert(killed, "mutation survived: " .. mutation[1])
	print("KILLED " .. mutation[1])
end
