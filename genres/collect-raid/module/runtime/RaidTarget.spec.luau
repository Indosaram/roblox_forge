--!strict
local RaidTarget = require("./RaidTarget")
local fs = require("@lune/fs")
local luau = require("@lune/luau")

return {
	["public raid binding discards client selected targets"] = function()
		local source = fs.readFile("genres/collect-raid/module/runtime/Server.luau")
		local binding = string.match(source, "Raid%.OnServerInvoke = (function%b().-\n\tend)")
		assert(binding ~= nil, "remote binding exists")
		local received: any = "unset"
		local create = luau.load("return function(raidHandler) return " .. binding .. " end", { environment = {} })
		local remote = create()(function(_player: any, target: any)
			received = target
			return true
		end)
		assert(remote({}, "Green"), "remote still invokes raid handler")
		assert(received == nil, "untrusted target cannot override default rival")
	end,
	["three team defaults cycle and every opposing vault is reachable"] = function()
		local teams = { "Red", "Blue", "Green" }
		for index, attacker in teams do
			assert(RaidTarget.resolve(teams, attacker, nil) == teams[index % #teams + 1], "cyclic default")
			for _, defender in teams do
				if defender ~= attacker then
					assert(RaidTarget.resolve(teams, attacker, defender) == defender, "explicit vault honored")
				end
			end
		end
	end,
	["self unknown and malformed raid targets are rejected"] = function()
		local teams = { "Red", "Blue", "Green" }
		assert(RaidTarget.resolve(teams, "Red", "Red") == nil, "self target refused")
		assert(RaidTarget.resolve(teams, "Red", "Missing") == nil, "unknown target refused")
		assert(RaidTarget.resolve(teams, "Red", 1) == nil, "malformed target refused")
		assert(RaidTarget.resolve(teams, "Missing", "Blue") == nil, "unknown attacker refused")
		assert(RaidTarget.resolve({ "Red", "Blue" }, "Blue", nil) == "Red", "two team default preserved")
	end,
}
