--!strict
local Ledger = require("./Ledger")

local function fixture(): Ledger.Ledger
	return {
		version = 2,
		epoch = 7,
		stateVersion = 1,
		epochs = {
			["2"] = {
				createdAt = 0,
				expiresAt = 10,
				outcomes = {
					late = {
						binding = "finish",
						result = { ok = true, stateVersion = 1 },
						createdAt = 9,
						expiresAt = 19,
					},
				},
			},
			["7"] = { createdAt = 10, expiresAt = 20, outcomes = {} },
		},
	}
end

return {
	["open acceptance with no outcomes retains its epoch"] = function()
		local ledger: Ledger.Ledger = {
			version = 2,
			epoch = 0,
			stateVersion = 0,
			epochs = { ["0"] = { createdAt = 0, expiresAt = 10, outcomes = {} } },
		}
		assert(Ledger.retentionFloor(ledger, 0) == 0, "initial epoch retained")
		assert(Ledger.retentionFloor(ledger, 9.999) == 0, "acceptance remains open")
		assert(Ledger.retentionFloor(ledger, 10) == 1, "exact expiry releases epoch")
	end,
	["late completion receipt retains expired acceptance across epoch gaps"] = function()
		local ledger = fixture()
		local before = Ledger.canonical(ledger)
		assert(Ledger.retentionFloor(ledger, 10) == 2, "old acceptance expired but receipt live")
		assert(Ledger.retentionFloor(ledger, 18.999) == 2, "late receipt protects older epoch")
		assert(Ledger.retentionFloor(ledger, 19) == 7, "exact receipt expiry permits gap cutoff")
		assert(Ledger.retentionFloor(ledger, 20) == 8, "all expired uses issued epoch plus one")
		assert(Ledger.retentionFloor(ledger, 100) == 8, "fallback stable after expiry")
		assert(Ledger.canonical(ledger) == before, "pure helper does not mutate ledger")
	end,
	["any live outcome protects epoch regardless of table iteration"] = function()
		local ledger = fixture()
		ledger.epochs["2"].outcomes.early = {
			binding = "early",
			result = { ok = true, stateVersion = 1 },
			createdAt = 0,
			expiresAt = 10,
		}
		assert(Ledger.retentionFloor(ledger, 15) == 2, "one expired receipt cannot hide another live receipt")
		ledger.epochs["2"] = nil
		assert(Ledger.retentionFloor(ledger, 15) == 7, "removed epoch gap requires no contiguous numbering")
	end,
}
