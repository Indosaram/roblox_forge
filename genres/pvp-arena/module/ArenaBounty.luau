--!strict
-- arena-bounty-v1: collect-raid + pvp-arena. The arena is where the free hatch economy is
-- funded: a pack starts every player with no Coins, and each arena match decided by play (a
-- knockout or the timed health decision) pays its winner a fixed Coins bounty into the
-- collect-raid wallet, which is the only wallet. Forfeits and draws pay nothing, so leaving a
-- match cannot mint coins. The bounty is deterministic (no paid or random grant) and team siege
-- on the collect side is untouched.
local Shared = require("../../../core/domain/genre/Contract")
local Collect = require("../../collect-raid/module/Adapter")
local Arena = require("./Adapter")
local ArenaBounty = {}

ArenaBounty.BOUNTY = 50

function ArenaBounty.validateConfig(configs: { [string]: Shared.ConfigData }): { string }
	local errors: { string } = {}
	for id in configs do
		if id ~= "collect-raid" and id ~= "pvp-arena" then
			table.insert(errors, "arena-bounty-v1: unknown partner config " .. id)
		end
	end
	local collect, arena = configs["collect-raid"], configs["pvp-arena"]
	if collect == nil then
		table.insert(errors, "arena-bounty-v1: missing collect-raid config")
	else
		local collectErrors = Collect.validateConfig(collect)
		for _, err in collectErrors do
			table.insert(errors, "collect-raid: " .. err)
		end
		if #collectErrors == 0 then
			if collect.currency ~= "Coins" then
				table.insert(errors, "arena-bounty-v1: collect-raid currency must be Coins")
			end
			if collect.startingCoins ~= 0 then
				table.insert(errors, "arena-bounty-v1: collect startingCoins must be zero; the arena funds hatching")
			end
			local affordable = false
			for _, source in collect.sources do
				if source.price <= ArenaBounty.BOUNTY then
					affordable = true
				end
			end
			if not affordable then
				table.insert(errors, "arena-bounty-v1: one arena bounty must afford a source")
			end
		end
	end
	if arena == nil then
		table.insert(errors, "arena-bounty-v1: missing pvp-arena config")
	else
		for _, err in Arena.validateConfig(arena) do
			table.insert(errors, "pvp-arena: " .. err)
		end
	end
	table.sort(errors)
	return errors
end

function ArenaBounty.create(
	configs: { [string]: Shared.ConfigData },
	services: Shared.Services
): { [string]: Shared.Instance }
	local errors = ArenaBounty.validateConfig(configs)
	assert(#errors == 0, table.concat(errors, "; "))
	local collect = Collect.create(configs["collect-raid"], services)
	local arena = Arena.create(configs["pvp-arena"], services, function(winner)
		-- A wallet already at the exact-integer ceiling drops the bounty rather than wrapping.
		collect.walletPort.credit(winner, ArenaBounty.BOUNTY)
	end)
	return { ["collect-raid"] = collect, ["pvp-arena"] = arena }
end

ArenaBounty.recipe = {
	id = "arena-bounty-v1",
	partners = { "collect-raid", "pvp-arena" },
	validateConfig = ArenaBounty.validateConfig,
	create = ArenaBounty.create,
}
return ArenaBounty
