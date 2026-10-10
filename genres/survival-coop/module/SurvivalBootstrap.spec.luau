--!strict
local Bootstrap = require("./SurvivalBootstrap")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Options = require("../../../core/infra/genre/Options")
local Contract = require("./Contract")
return {
	["server lifecycle option accepts bind close and rejects unknown hooks"] = function()
		local options: any = {
			packConfig = { api = 1, order = { "survival-coop" }, configs = {} },
			contracts = { Contract },
			controls = {},
			storeName = "Lifecycle",
			lifecycle = {
				bind = function() end,
				close = function()
					return { ok = true }
				end,
			},
		}
		Options.validate(options)
		options.lifecycle.afterJoin = function() end
		assert(not pcall(Options.validate, options), "unknown lifecycle hook rejected")
		options.lifecycle.afterJoin = nil
		options.lifecycle.bind = nil
		assert(not pcall(Options.validate, options), "binding callback required")
	end,
	["bootstrap requires explicit durable byte budget before ownership"] = function()
		local ok, err = pcall(function()
			Bootstrap.new({} :: any, {} :: any, Memory.new(), {
				sessionId = "test",
				leaseSeconds = 120,
				now = function()
					return 0
				end,
			})
		end)
		assert(
			not ok and string.find(tostring(err), "SOURCE_BYTE_BUDGET_REQUIRED", 1, true),
			"explicit byte budget required"
		)
	end,
}
