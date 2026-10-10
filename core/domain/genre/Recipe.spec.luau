--!strict
local Contract = require("./Contract")
local Executor = require("./Executor")
local Validation = require("./Validation")
local CLI = require("../../../cli/forge/lib/genrecontract")
local Grow = require("../../../genres/grow-harvest/module/Contract")
local Survival = require("../../../genres/survival-coop/module/Contract")
local GrowFixture = require("../../../genres/grow-harvest/module/Adapter.fixture")
local SurvivalFixture = require("../../../genres/survival-coop/module/Adapter.fixture")
local function pack(): Contract.PackConfig
	local grow = GrowFixture.config()
	grow.startingBalance = 0
	local survival = table.clone(SurvivalFixture.config)
	survival.startingBalance = 0
	return {
		api = 1,
		order = { Grow.id, Survival.id },
		configs = { [Grow.id] = grow, [Survival.id] = survival },
		recipe = "garden-defense-v1",
	}
end
return {
	["composition preflight rejects currency and duplicate funds before any create"] = function()
		local recipe = Survival.recipe
		assert(recipe ~= nil and recipe.validateConfig ~= nil, "typed recipe validator available")
		local creates = 0
		local survival = table.clone(Survival)
		local intercepted = table.clone(recipe)
		intercepted.create = function(_configs, _services)
			creates += 1
			error("invalid config reached create")
		end
		survival.recipe = intercepted
		local runtimes = { [Grow.id] = Grow, [Survival.id] = survival }
		assert(#CLI.validatePack(pack(), runtimes) == 0, "valid recipe preflight")
		for _, mutate in
			{
				function(p: Contract.PackConfig)
					p.configs[Survival.id].startingBalance = 10
				end,
				function(p: Contract.PackConfig)
					p.configs[Grow.id].currency = "Gems"
				end,
			}
		do
			local invalid = pack()
			mutate(invalid)
			local errors = CLI.validatePack(invalid, runtimes)
			assert(#errors > 0, "prewrite rejects composition invariant")
			assert(not pcall(Executor.new, invalid, { Grow, survival }, {
				now = function()
					return 0
				end,
				roll = function(): number
					error("unexpected roll")
				end,
				emit = function(_event)
					error("unexpected event")
				end,
			}), "constructor rejects composition invariant")
			assert(creates == 0, "recipe create never invoked")
		end
	end,
	["recipe validator receives cloned configs and malformed capability rejects"] = function()
		local survival = table.clone(Survival)
		assert(survival.recipe ~= nil, "recipe exists")
		local recipe = table.clone(survival.recipe)
		recipe.validateConfig = function(configs)
			configs[Grow.id].startingBalance = 999
			return { "rejected" }
		end
		survival.recipe = recipe
		local input = pack()
		assert(#CLI.validatePack(input, { [Grow.id] = Grow, [Survival.id] = survival }) == 1, "custom recipe invoked")
		assert(input.configs[Grow.id].startingBalance == 0, "prewrite input unchanged")
		local malformed: any = table.clone(survival)
		malformed.recipe = table.clone(recipe)
		malformed.recipe.validateConfig = true
		assert(#Validation.validateRuntime(malformed) > 0, "nonfunction recipe validator rejected")
	end,
}
