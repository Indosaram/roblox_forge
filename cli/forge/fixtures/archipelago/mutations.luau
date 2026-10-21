--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Expedition = require("../../../../core/domain/island/Expedition")
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local source = fs.readFile("core/domain/island/Archipelago.luau")
local specs = fs.readFile("core/domain/island/Archipelago.spec.luau")
local mutations = {
	{ "expiry", "now >= state.expiresAt", "false" },
	{ "imminent", "now + entryBuffer >= state.expiresAt", "false" },
	{ "inactive", 'state.status ~= "active"', "false" },
	{ "level", "facts.level < (definition.gates.characterLevel or 1)", "false" },
	{ "development", "facts.developmentRank < (definition.gates.developmentRank or 0)", "false" },
	{ "instability", "facts.instabilityAccess < state.index", "false" },
	{ "actor", "receipt.actor ~= state.actor", "false" },
	{ "expedition", "receipt.expedition ~= state.id", "false" },
	{ "revision", "receipt.revision ~= state.revision", "false" },
	{ "action", "receipt.action ~= objective.action", "false" },
	{ "target", "receipt.target ~= objective.target", "false" },
	{ "quantity", "receipt.quantity <= 0", "false" },
	{ "receipt-id", 'receipt.id == ""', "false" },
	{ "duplicate", "state.receipts[receipt.id] then", "false then" },
	{ "departure", "not state.completed[objective.id]", "false" },
	{ "chain-limit", "state.stage == 4", "false" },
	{
		"escort-reset",
		"cause: string): string\n\tstate.escortAtStart = true",
		"cause: string): string\n\tstate.escortAtStart = false",
	},
	{
		"cargo-cleanup",
		'if state.status ~= "active" then\n\t\tstate.questCargo = nil',
		'if state.status ~= "active" then\n\t\tstate.questCargo = state.questCargo',
	},
}
for _, case in mutations do
	local start, stop = string.find(source, case[2], 1, true)
	assert(start and stop, "mutation anchor " .. case[1])
	local changed = string.sub(source, 1, start - 1) .. case[3] .. string.sub(source, stop + 1)
	local mutant = luau.load(changed, { environment = {
		require = function()
			return Expedition
		end,
	} })()
	local tests = luau.load(specs, {
		environment = {
			require = function(path)
				if path == "./Archipelago" then
					return mutant
				elseif path == "@lune/fs" then
					return fs
				elseif path == "@lune/luau" then
					return {
						load = function()
							return function()
								return Content
							end
						end,
					}
				end
				error("unexpected mutation dependency " .. path)
			end,
		},
	})()
	local killed = false
	for _, test in tests do
		if not pcall(test) then
			killed = true
		end
	end
	assert(killed, "SURVIVED " .. case[1])
	print("KILLED " .. case[1])
end
print("mutations: PASS " .. #mutations)
