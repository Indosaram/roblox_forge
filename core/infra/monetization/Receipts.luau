--!strict
-- Receipts: idempotent developer-product receipt processing with safe retries.

local Receipts = {}

export type Receipt = {
	PlayerId: number,
	ProductId: number,
	PurchaseId: string,
}

export type Decision = "PurchaseGranted" | "NotProcessedYet"

export type Options = {
	grant: (userId: number, productKey: string) -> boolean,
	hasProcessed: (purchaseId: string) -> boolean,
	markProcessed: (purchaseId: string) -> (),
	productKeyFor: (productId: number) -> string?,
	-- Durably persists the grant (e.g. store:save the profile). PurchaseGranted
	-- is only ever returned once this returns true, so a receipt is never
	-- acknowledged to Roblox before the grant survives a crash or DataStore
	-- failure. Called again on retry until it succeeds; markProcessed already
	-- makes the grant itself idempotent, so a retried commit never re-grants.
	commit: (userId: number) -> boolean,
}

export type Processor = {
	process: (Processor, Receipt) -> Decision,
}

-- Returns a processor whose :process returns the plain strings the game maps to
-- Enum.ProductPurchaseDecision.
function Receipts.new(opts: Options): Processor
	local function process(_self: Processor, receipt: Receipt): Decision
		if type(receipt) ~= "table" or type(receipt.PurchaseId) ~= "string" then
			return "NotProcessedYet"
		end
		-- Idempotency: an already-granted purchase must not grant again, but its
		-- save is retried until it durably persists.
		if opts.hasProcessed(receipt.PurchaseId) then
			local commitOk, committed = pcall(opts.commit, receipt.PlayerId)
			if not commitOk or committed ~= true then
				return "NotProcessedYet"
			end
			return "PurchaseGranted"
		end
		local productKey = opts.productKeyFor(receipt.ProductId)
		if productKey == nil then
			return "NotProcessedYet"
		end
		-- A failing or erroring grant leaves the purchase unmarked so it can retry.
		local ok, granted = pcall(opts.grant, receipt.PlayerId, productKey)
		if not ok or granted ~= true then
			return "NotProcessedYet"
		end
		opts.markProcessed(receipt.PurchaseId)
		-- Only acknowledge the purchase once the grant is durably saved. If the
		-- save fails, the next redelivery retries the commit above without
		-- granting a second time.
		local commitOk, committed = pcall(opts.commit, receipt.PlayerId)
		if not commitOk or committed ~= true then
			return "NotProcessedYet"
		end
		return "PurchaseGranted"
	end
	return { process = process }
end

return Receipts
