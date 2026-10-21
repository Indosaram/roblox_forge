--!strict
local Project = require("./CrossServerMarketProject")
return {
	["two contributors split without multiplying indivisible rewards"] = function()
		local project = {
			id = "raft",
			contributions = { a = { units = 1, escrowCommitted = true }, b = { units = 2, escrowCommitted = true } },
		}
		local result = Project.complete(project, { plank = 5 })
		assert(result.claims["raft:a"].items.plank == 1, "trade invariant")
		assert(result.claims["raft:b"].items.plank == 4, "trade invariant")
		assert(Project.complete(result, { plank = 5 }) == result, "trade invariant")
		assert(not pcall(Project.complete, result, { plank = 6 }), "trade invariant")
	end,
	["unescrowed and solo contributions cannot mint project rewards"] = function()
		assert(
			not pcall(
				Project.complete,
				{ id = "p", contributions = { a = { units = 1, escrowCommitted = true } } },
				{ plank = 2 }
			),
			"trade invariant"
		)
		assert(not pcall(Project.complete, {
			id = "p",
			contributions = {
				a = { units = 1, escrowCommitted = false },
				b = { units = 1, escrowCommitted = true },
			},
		}, { plank = 2 }), "trade invariant")
	end,
}
