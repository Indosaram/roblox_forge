--!strict
-- Specs for Wallet: balances, credit/debit, and input validation.

local Wallet = require("./Wallet")

local function expectError(fn: () -> (), message: string): ()
	local ok = pcall(fn)
	assert(not ok, "expected error: " .. message)
end

return {
	["new wallet defaults unknown currency to zero"] = function()
		local wallet = Wallet.new()
		assert(wallet:balance("coins") == 0, "unknown currency should be 0")
	end,

	["new wallet accepts initial balances"] = function()
		local wallet = Wallet.new({ coins = 100, gems = 5 })
		assert(wallet:balance("coins") == 100, "initial coins")
		assert(wallet:balance("gems") == 5, "initial gems")
	end,

	["new wallet accepts a zero initial balance"] = function()
		local wallet = Wallet.new({ coins = 0 })
		assert(wallet:balance("coins") == 0, "zero initial")
		assert(wallet:canAfford("coins", 1) == false, "cannot afford from zero")
	end,

	["credit increases balance"] = function()
		local wallet = Wallet.new({ coins = 10 })
		wallet:credit("coins", 5)
		assert(wallet:balance("coins") == 15, "credited balance")
	end,

	["credit creates an unknown currency"] = function()
		local wallet = Wallet.new()
		wallet:credit("gems", 3)
		assert(wallet:balance("gems") == 3, "credit unknown currency")
	end,

	["debit reduces balance and returns true"] = function()
		local wallet = Wallet.new({ coins = 10 })
		assert(wallet:debit("coins", 4) == true, "debit success")
		assert(wallet:balance("coins") == 6, "debit balance")
	end,

	["debit with insufficient funds returns false and leaves balance unchanged"] = function()
		local wallet = Wallet.new({ coins = 3 })
		assert(wallet:debit("coins", 5) == false, "debit should fail")
		assert(wallet:balance("coins") == 3, "balance unchanged")
	end,

	["debit on an empty wallet never goes negative"] = function()
		local wallet = Wallet.new()
		assert(wallet:debit("coins", 1) == false, "cannot debit empty wallet")
		assert(wallet:balance("coins") == 0, "balance stays zero")
	end,

	["canAfford respects balance"] = function()
		local wallet = Wallet.new({ coins = 10 })
		assert(wallet:canAfford("coins", 10) == true, "can afford exact")
		assert(wallet:canAfford("coins", 11) == false, "cannot afford more")
		assert(wallet:canAfford("gems", 1) == false, "unknown currency cannot afford")
	end,

	["zero amount is rejected"] = function()
		local wallet = Wallet.new({ coins = 10 })
		expectError(function()
			wallet:credit("coins", 0)
		end, "credit zero")
		expectError(function()
			wallet:debit("coins", 0)
		end, "debit zero")
		assert(wallet:canAfford("coins", 0) == false, "canAfford zero")
		assert(wallet:balance("coins") == 10, "balance unchanged")
	end,

	["negative amount is rejected"] = function()
		local wallet = Wallet.new({ coins = 10 })
		expectError(function()
			wallet:credit("coins", -1)
		end, "credit negative")
		expectError(function()
			wallet:debit("coins", -1)
		end, "debit negative")
		assert(wallet:canAfford("coins", -1) == false, "canAfford negative")
		assert(wallet:balance("coins") == 10, "balance unchanged")
	end,

	["NaN amount is rejected"] = function()
		local wallet = Wallet.new({ coins = 10 })
		expectError(function()
			wallet:credit("coins", 0 / 0)
		end, "credit NaN")
		expectError(function()
			wallet:debit("coins", 0 / 0)
		end, "debit NaN")
		assert(wallet:canAfford("coins", 0 / 0) == false, "canAfford NaN")
		assert(wallet:balance("coins") == 10, "balance unchanged")
	end,

	["math.huge amount is rejected"] = function()
		local wallet = Wallet.new({ coins = 10 })
		expectError(function()
			wallet:credit("coins", math.huge)
		end, "credit infinite")
		expectError(function()
			wallet:debit("coins", math.huge)
		end, "debit infinite")
		assert(wallet:canAfford("coins", math.huge) == false, "canAfford infinite")
		assert(wallet:balance("coins") == 10, "balance unchanged")
	end,

	["1.5 amount is rejected"] = function()
		local wallet = Wallet.new({ coins = 10 })
		expectError(function()
			wallet:credit("coins", 1.5)
		end, "credit non-integer")
		expectError(function()
			wallet:debit("coins", 1.5)
		end, "debit non-integer")
		assert(wallet:canAfford("coins", 1.5) == false, "canAfford non-integer")
		assert(wallet:balance("coins") == 10, "balance unchanged")
	end,

	["empty currency is rejected"] = function()
		local wallet = Wallet.new()
		expectError(function()
			wallet:balance("")
		end, "balance")
		expectError(function()
			wallet:credit("", 1)
		end, "credit")
		expectError(function()
			wallet:debit("", 1)
		end, "debit")
		expectError(function()
			wallet:canAfford("", 1)
		end, "canAfford")
	end,

	["new wallet rejects invalid initial amounts"] = function()
		expectError(function()
			Wallet.new({ coins = -1 })
		end, "negative initial")
		expectError(function()
			Wallet.new({ coins = 1.5 })
		end, "fractional initial")
		expectError(function()
			Wallet.new({ [""] = 1 })
		end, "empty initial currency")
	end,

	["credit that would overflow the balance to a non-finite value is rejected"] = function()
		local wallet = Wallet.new({ coins = 2 ^ 53 - 1 })
		expectError(function()
			wallet:credit("coins", 2 ^ 53 - 1)
		end, "credit overflow past max safe balance")
		assert(wallet:balance("coins") == 2 ^ 53 - 1, "balance unchanged after a rejected overflow")
	end,

	["new wallet rejects an initial balance above the max safe integer"] = function()
		expectError(function()
			Wallet.new({ coins = 2 ^ 53 })
		end, "initial balance above max safe integer")
	end,
}
