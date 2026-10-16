--!strict
-- Specs for Receipts: idempotency, unknown products, and grant-failure retries.

local Receipts = require("./Receipts")

local function newHarness(
	productKeys: { [number]: string },
	grantImpl: (number, string) -> boolean,
	commitImpl: ((number) -> boolean)?
)
	local processed: { [string]: boolean } = {}
	local calls = { grant = 0, commit = 0 }
	local processor = Receipts.new({
		grant = function(userId: number, productKey: string): boolean
			calls.grant += 1
			return grantImpl(userId, productKey)
		end,
		hasProcessed = function(purchaseId: string): boolean
			return processed[purchaseId] == true
		end,
		markProcessed = function(purchaseId: string): ()
			processed[purchaseId] = true
		end,
		productKeyFor = function(productId: number): string?
			return productKeys[productId]
		end,
		commit = function(userId: number): boolean
			calls.commit += 1
			if commitImpl == nil then
				return true
			end
			return commitImpl(userId)
		end,
	})
	return { processor = processor, calls = calls, processed = processed }
end

return {
	["duplicate PurchaseId grants once"] = function()
		local harness = newHarness({ [1] = "coins" }, function()
			return true
		end)
		local receipt = { PlayerId = 7, ProductId = 1, PurchaseId = "p-1" }
		assert(harness.processor:process(receipt) == "PurchaseGranted", "first call granted")
		assert(harness.processor:process(receipt) == "PurchaseGranted", "second call granted")
		assert(harness.calls.grant == 1, "grant must run once, ran " .. tostring(harness.calls.grant))
	end,

	["unknown product returns NotProcessedYet"] = function()
		local harness = newHarness({}, function()
			return true
		end)
		local decision = harness.processor:process({ PlayerId = 1, ProductId = 999, PurchaseId = "p-2" })
		assert(decision == "NotProcessedYet", "unknown product: " .. tostring(decision))
		assert(harness.calls.grant == 0, "grant must not run for an unknown product")
	end,

	["grant error returns NotProcessedYet and retry later succeeds"] = function()
		local shouldFail = true
		local harness = newHarness({ [1] = "coins" }, function()
			if shouldFail then
				error("grant exploded")
			end
			return true
		end)
		local receipt = { PlayerId = 1, ProductId = 1, PurchaseId = "p-3" }
		assert(harness.processor:process(receipt) == "NotProcessedYet", "error yields NotProcessedYet")
		assert(harness.processed["p-3"] ~= true, "failed grant must not be marked")
		shouldFail = false
		assert(harness.processor:process(receipt) == "PurchaseGranted", "retry succeeds")
		assert(harness.processed["p-3"] == true, "successful retry is marked")
		assert(harness.calls.grant == 2, "grant attempted twice")
	end,

	["a failed commit (save) returns NotProcessedYet instead of granting"] = function()
		local harness = newHarness({ [1] = "coins" }, function()
			return true
		end, function()
			return false
		end)
		local receipt = { PlayerId = 1, ProductId = 1, PurchaseId = "p-4" }
		local decision = harness.processor:process(receipt)
		assert(decision == "NotProcessedYet", "a failed save must not grant, got " .. tostring(decision))
		assert(harness.calls.commit == 1, "commit must be attempted")
	end,

	["a retry after a failed commit grants without calling grant again"] = function()
		local commitShouldFail = true
		local harness = newHarness({ [1] = "coins" }, function()
			return true
		end, function()
			return not commitShouldFail
		end)
		local receipt = { PlayerId = 1, ProductId = 1, PurchaseId = "p-5" }
		assert(harness.processor:process(receipt) == "NotProcessedYet", "first attempt fails to save")
		commitShouldFail = false
		assert(harness.processor:process(receipt) == "PurchaseGranted", "retry saves and grants")
		assert(harness.calls.grant == 1, "grant runs only once since hasProcessed marks it idempotent")
		assert(harness.calls.commit == 2, "commit is retried until it saves")
	end,

	-- QA-BM-03: a redelivery storm (Roblox retries ProcessReceipt until it gets
	-- PurchaseGranted, and may redeliver after) leaves exactly one ledger grant
	-- per PurchaseId, even with failing grants and saves interleaved.
	["QA-BM-03 redelivery storm yields zero duplicate grants in the grant ledger"] = function()
		local ledger: { [string]: number } = {}
		local attempt = 0
		local harness = newHarness({ [1] = "respec", [2] = "reefOutfit" }, function(userId: number, productKey: string)
			attempt += 1
			-- Every third grant attempt errors before writing anything.
			if attempt % 3 == 0 then
				error("transient grant failure")
			end
			local entry = tostring(userId) .. ":" .. productKey
			ledger[entry] = (ledger[entry] or 0) + 1
			return true
		end, function()
			-- Every other save fails, forcing redelivery after the grant.
			attempt += 1
			return attempt % 2 == 0
		end)
		local receipts = {
			{ PlayerId = 1, ProductId = 1, PurchaseId = "bm3-a" },
			{ PlayerId = 1, ProductId = 2, PurchaseId = "bm3-b" },
			{ PlayerId = 2, ProductId = 1, PurchaseId = "bm3-c" },
		}
		local granted: { [string]: boolean } = {}
		for _ = 1, 20 do
			for _, receipt in receipts do
				if harness.processor:process(receipt) == "PurchaseGranted" then
					granted[receipt.PurchaseId] = true
				end
			end
		end
		for _, receipt in receipts do
			assert(granted[receipt.PurchaseId], "every receipt is eventually granted: " .. receipt.PurchaseId)
		end
		local total = 0
		for entry, count in ledger do
			assert(count == 1, "duplicate grant for " .. entry .. ": " .. tostring(count))
			total += count
		end
		assert(total == #receipts, "one ledger grant per purchase, got " .. tostring(total))
	end,
}
