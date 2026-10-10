--!strict
local Contract = require("./Contract")
local Validation = require("./Validation")
local Data = require("./SerializedData")
local M = {}
function M.new(
	pack: Contract.PackConfig,
	contracts: { Contract.RuntimeContract },
	services: Contract.Services,
	hooks: Contract.HookMap?
)
	assert(Validation.dense(contracts, 64) and Validation.dense(pack.order, 64), "invalid descriptor/order list")
	assert(Data.data(pack), "invalid pack data")
	for key in pack do
		assert(key == "api" or key == "order" or key == "configs" or key == "recipe", "unknown pack field")
	end
	assert(pack.api == 1 and #pack.order > 0 and #contracts == #pack.order, "invalid pack selection")
	local descriptors: { [string]: Contract.RuntimeContract } = {}
	local actions: { [string]: Contract.Action } = {}
	local queue: { Contract.Event } = {}
	local clock = { value = services.now() }
	assert(Data.finite(clock.value), "invalid clock")
	for i, descriptor in contracts do
		assert(#Validation.validateRuntime(descriptor) == 0, "invalid runtime descriptor")
		assert(
			descriptor.api == 1 and descriptor.configVersion == 1 and descriptor.saveVersion == 1,
			"unsupported runtime version"
		)
		assert(descriptor.id == pack.order[i] and descriptors[descriptor.id] == nil, "invalid runtime order")
		descriptors[descriptor.id] = descriptor
		assert(
			type(pack.configs[descriptor.id]) == "table"
				and #descriptor.validateConfig(Data.clone(pack.configs[descriptor.id])) == 0,
			"invalid config: " .. descriptor.id
		)
		for _, action in descriptor.actions do
			local id = descriptor.id .. ":" .. action.id
			assert(actions[id] == nil, "duplicate action")
			assert(
				Data.finite(action.rate.capacity)
					and Data.finite(action.rate.refillPerSecond)
					and action.rate.capacity >= 1
					and action.rate.refillPerSecond > 0,
				"invalid rate"
			)
			actions[id] = action
		end
	end
	for id in pack.configs do
		assert(descriptors[id] ~= nil, "unknown config")
	end
	local hookMap: Contract.HookMap = hooks or {}
	for key in hookMap do
		local genre, name = string.match(key, "^([^:]+):([^:]+)$")
		local descriptor = if genre then descriptors[genre] else nil
		assert(
			name ~= nil
				and descriptor ~= nil
				and table.find(descriptor.hooks, name) ~= nil
				and table.find(descriptor.events, name) ~= nil,
			"unknown hook: " .. key
		)
	end
	local wrapped: Contract.Services = {
		survivalSpatial = services.survivalSpatial,
		survivalDeath = services.survivalDeath,
		survivalSettlement = services.survivalSettlement,
		now = function()
			return clock.value
		end,
		roll = function()
			local n = services.roll()
			assert(Data.finite(n) and n >= 0 and n < 1, "invalid roll")
			return n
		end,
		emit = function(event)
			local descriptor = descriptors[event.genre]
			assert(descriptor ~= nil and table.find(descriptor.events, event.name) ~= nil, "undeclared event")
			assert(
				type(event.genre) == "string"
					and #event.genre <= 64
					and type(event.name) == "string"
					and #event.name <= 64,
				"invalid event identity"
			)
			assert(
				event.playerId == nil
					or (type(event.playerId) == "string" and #event.playerId > 0 and #event.playerId <= 256),
				"invalid event player"
			)
			assert(type(event.data) == "table" and Data.data(event.data), "invalid event data")
			table.insert(queue, Data.clone(event))
		end,
	}
	local instances: { [string]: Contract.Instance } = {}
	if pack.recipe ~= nil then
		local matched: Contract.RuntimeContract? = nil
		for _, descriptor in contracts do
			local recipe = descriptor.recipe
			if recipe ~= nil and recipe.id == pack.recipe and #recipe.partners == #pack.order then
				local exact = true
				for i, id in recipe.partners do
					if id ~= pack.order[i] then
						exact = false
					end
				end
				if exact then
					assert(matched == nil, "ambiguous recipe")
					matched = descriptor
				end
			end
		end
		assert(matched ~= nil and matched.recipe ~= nil, "unsupported recipe")
		if matched.recipe.validateConfig ~= nil then
			local errors = matched.recipe.validateConfig(Data.clone(pack.configs))
			assert(#errors == 0, table.concat(errors, "; "))
		end
		instances = matched.recipe.create(Data.clone(pack.configs), wrapped)
		for id in instances do
			assert(descriptors[id] ~= nil, "extra recipe instance")
		end
	else
		assert(#contracts == 1, "mixed selection requires recipe")
		for _, descriptor in contracts do
			instances[descriptor.id] = descriptor.create(Data.clone(pack.configs[descriptor.id]), wrapped)
		end
	end
	for _, id in pack.order do
		assert(instances[id] ~= nil, "missing recipe instance")
	end
	return descriptors, actions, queue, instances, clock
end
return M
