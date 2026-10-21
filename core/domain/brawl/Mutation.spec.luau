--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Data = require("../genre/SerializedData")
local Policy = require("./Policy.fixture")
local function killed(before: string, after: string)
	local source = fs.readFile("core/domain/brawl/Match.luau")
	local first, last = string.find(source, before, 1, true)
	assert(first and last, "mutation anchor")
	local mutant = luau.load(string.sub(source, 1, first - 1) .. after .. string.sub(source, last + 1), {
		environment = {
			require = function()
				return Data
			end,
		},
	})()
	local specs = luau.load(fs.readFile("core/domain/brawl/Match.spec.luau"), {
		environment = {
			require = function(name)
				return if name == "./Match" then mutant else Policy
			end,
		},
	})()
	local failures = 0
	for _, test in specs do
		if not pcall(test) then
			failures += 1
		end
	end
	assert(failures > 0, "surviving mutation: " .. before)
end
return {
	["level refusal mutation killed"] = function()
		killed("facts.level < state.policy.minimumLevel", "false")
	end,
	["sixteenth admission mutation killed"] = function()
		killed("#state.order >= state.policy.maximumPlayers", "false")
	end,
	["snapshot alias mutation killed"] = function()
		killed("Data.clone(facts.equipment)", "facts.equipment")
	end,
	["fog bypass mutation killed"] = function()
		killed('action == "ranged" and weather.rangeCap and range > weather.rangeCap', "false")
	end,
	["storm bypass mutation killed"] = function()
		killed('action == "mount" and weather.noMount', "false")
	end,
	["receipt bypass mutation killed"] = function()
		killed("if ledger.receipts[state.id] then", "if false then")
	end,
	["quota bypass mutation killed"] = function()
		killed("count < state.policy.dailySettlements", "true")
	end,
	["preparation bypass mutation killed"] = function()
		killed("or now < state.startsAt", "or false")
	end,
	["desertion bypass mutation killed"] = function()
		killed("player.alive, player.health, player.deserted = false, 0, true", "player.deserted = true")
	end,
	["draw picks survivor mutation killed"] = function()
		killed("if #survivors == 1 then survivors[1] else nil", "if #survivors >= 1 then survivors[1] else nil")
	end,
	["UTC rollover mutation killed"] = function()
		killed("math.floor(utc / state.policy.daySeconds)", "0")
	end,
}
