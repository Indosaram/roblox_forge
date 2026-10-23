--!strict
-- Execute the same behavioral specs against in-memory mutants. Production files
-- are never rewritten, and a killed mutant requires an assertion failure.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Ledger = require("../command/Ledger")
return {
	["conservation and rejection specs kill price fee debit escrow and identity mutations"] = function()
		local source = fs.readFile("core/domain/market/CrossServer.luau")
		local tests = fs.readFile("core/domain/market/CrossServer.spec.luau")
		local mutations = {
			{ "old.coins -= listing.price", "old.coins -= 0" },
			{ "math.floor(price * M.FEE_PERCENT / 100)", "0" },
			{ "item.quantity -= listing.quantity", "item.quantity -= 0" },
			{ "old.price == price", "true" },
			{ "old.seller ~= actor", "true" },
			{ "count >= 20", "count >= 200" },
			{ "or item.robuxPurchased", "or false" },
		}
		for _, mutation in mutations do
			local start, finish = string.find(source, mutation[1], 1, true)
			assert(start and finish, "mutation anchor missing")
			local mutated = string.sub(source, 1, start - 1) .. mutation[2] .. string.sub(source, finish + 1)
			local module =
				luau.load(mutated, { environment = {
					require = function()
						return Ledger
					end,
				} })()
			local suite =
				luau.load(tests, { environment = {
					require = function()
						return module
					end,
				} })()
			local killed = false
			for _, test in suite do
				local ok = pcall(test)
				if not ok then
					killed = true
					break
				end
			end
			assert(killed, "surviving mutation: " .. mutation[1])
		end
	end,
}
