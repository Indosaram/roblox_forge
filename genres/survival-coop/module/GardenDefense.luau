--!strict
local Shared = require("../../../core/domain/genre/Contract")
local Grow = require("../../grow-harvest/module/Adapter")
local Survival = require("./Adapter")
local GardenDefense = {}

-- Validate both schemas and the ownership invariant before constructing either instance.
function GardenDefense.validateConfig(configs: { [string]: Shared.ConfigData }): { string }
	local errors: { string } = {}
	for id in configs do
		if id ~= "grow-harvest" and id ~= "survival-coop" then
			table.insert(errors, "garden-defense-v1: unknown partner config " .. id)
		end
	end
	local grow, survival = configs["grow-harvest"], configs["survival-coop"]
	if grow == nil then
		table.insert(errors, "garden-defense-v1: missing grow-harvest config")
	else
		for _, err in Grow.validateConfig(grow) do
			table.insert(errors, "grow-harvest: " .. err)
		end
	end
	if survival == nil then
		table.insert(errors, "garden-defense-v1: missing survival-coop config")
	else
		for _, err in Survival.validateConfig(survival) do
			table.insert(errors, "survival-coop: " .. err)
		end
		if survival.startingBalance ~= 0 then
			table.insert(errors, "garden-defense-v1: survival startingBalance must be zero; grow owns currency")
		end
	end
	if grow ~= nil and survival ~= nil and (grow.currency ~= survival.currency or grow.currency ~= "Coins") then
		table.insert(errors, "garden-defense-v1: partners must share Coins")
	end
	table.sort(errors)
	return errors
end

function GardenDefense.create(
	configs: { [string]: Shared.ConfigData },
	services: Shared.Services
): { [string]: Shared.Instance }
	local errors = GardenDefense.validateConfig(configs)
	assert(#errors == 0, table.concat(errors, "; "))
	local grow = Grow.create(configs["grow-harvest"], services)
	local survival = Survival.new(configs["survival-coop"] :: any, services, grow.walletPort)
	-- Executor alone owns lifecycle; these are the original instances, not forwarding wrappers.
	return { ["grow-harvest"] = grow, ["survival-coop"] = survival }
end

GardenDefense.recipe = {
	id = "garden-defense-v1",
	partners = { "grow-harvest", "survival-coop" },
	validateConfig = GardenDefense.validateConfig,
	create = GardenDefense.create,
}
return GardenDefense
