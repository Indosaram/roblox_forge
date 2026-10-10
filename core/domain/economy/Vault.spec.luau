--!strict
-- Specs for Vault: deposits, counts, and raid movement rules.

local Vault = require("./Vault")

return {
	["raid on an empty vault moves nothing"] = function()
		local attacker = Vault.new()
		local defender = Vault.new()
		assert(Vault.raid(attacker, defender, 5) == 0, "empty raid moves zero")
		assert(Vault.count(attacker) == 0, "attacker unchanged")
		assert(Vault.count(defender) == 0, "defender unchanged")
	end,

	["raid never moves non-raidable eggs"] = function()
		local attacker = Vault.new()
		local defender = Vault.new()
		Vault.deposit(defender, "vaulted", false)
		assert(Vault.raid(attacker, defender, 5) == 0, "vaulted egg is not raidable")
		assert(Vault.count(defender) == 1, "vaulted egg stays")
		assert(Vault.count(attacker) == 0, "attacker gains nothing")
	end,

	["raid respects maxTake"] = function()
		local attacker = Vault.new()
		local defender = Vault.new()
		Vault.deposit(defender, "a", true)
		Vault.deposit(defender, "b", true)
		Vault.deposit(defender, "c", true)
		assert(Vault.raid(attacker, defender, 2) == 2, "moves up to maxTake")
		assert(Vault.count(attacker) == 2, "attacker gained two")
		assert(Vault.count(defender) == 1, "defender kept one")
		assert(Vault.count(defender, true) == 1, "defender raidable count")
	end,

	["maxTake zero moves nothing"] = function()
		local attacker = Vault.new()
		local defender = Vault.new()
		Vault.deposit(defender, "a", true)
		assert(Vault.raid(attacker, defender, 0) == 0, "zero maxTake")
		assert(Vault.count(defender) == 1, "defender unchanged")
	end,

	["raiding your own vault is a no-op reporting zero moved"] = function()
		local v = Vault.new()
		Vault.deposit(v, "a", true)
		Vault.deposit(v, "b", true)
		Vault.deposit(v, "c", false)
		assert(Vault.raid(v, v, 5) == 0, "self-raid moves zero")
		assert(Vault.count(v) == 3, "self-raid leaves the vault's contents untouched, got " .. tostring(Vault.count(v)))
	end,

	["fractional maxTake is floored, not rounded up"] = function()
		local attacker = Vault.new()
		local defender = Vault.new()
		Vault.deposit(defender, "a", true)
		Vault.deposit(defender, "b", true)
		Vault.deposit(defender, "c", true)
		local moved = Vault.raid(attacker, defender, 1.5)
		assert(moved == 1, "1.5 maxTake should floor to 1, got " .. tostring(moved))
	end,
}
