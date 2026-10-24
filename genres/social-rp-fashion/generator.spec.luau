--!strict
local Executor = require("../../core/domain/genre/Executor")
local Contract = require("./module/Contract")
local Generator = require("./generator")
return {
	["generator driver uses real executor and save envelope"] = function()
		local input = {
			mode = "new" :: "new",
			slug = "fashion",
			pascal = "Fashion",
			title = "Fashion",
			concept = "Garden",
			seed = 2,
			teams = {},
			debugName = "Fashion",
			guiName = "Fashion",
		}
		local generated = Generator.generate(input)
		assert(#Contract.validateConfig(generated.config) == 0 and #generated.controls == 3, "fashion invariant failed")
		local function executor()
			local now = 0
			local runtime = Executor.new(
				{ api = 1, order = { "social-rp-fashion" }, configs = { ["social-rp-fashion"] = generated.config } },
				{ Contract },
				{
					now = function()
						return now
					end,
					roll = function()
						return 0
					end,
					emit = function() end,
				}
			)
			local advance = runtime.advance
			runtime.advance = function(epoch)
				now = epoch
				advance(epoch)
			end
			return runtime
		end
		for _, check in Generator.driver.run(executor(), input) do
			assert(check.ok, check.name)
		end
		local metrics = Generator.driver.simulate(executor(), input, 2, 3)
		assert(
			metrics.sourceTotal == 15 and metrics.acceptedActions == 9 and metrics.rejectedActions == 6,
			"fashion invariant failed"
		)
	end,
}
