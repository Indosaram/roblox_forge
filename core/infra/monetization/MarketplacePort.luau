--!strict
-- MarketplacePort: engine port for MarketplaceService (developer products, game passes,
-- subscriptions) with a Roblox adapter and a Lune fake. The adapter takes the services as
-- parameters so it never reads engine globals itself.

local MarketplacePort = {}

export type Receipt = { PlayerId: number, ProductId: number, PurchaseId: string }
export type Decision = "PurchaseGranted" | "NotProcessedYet"
export type Port = {
	promptProduct: (userId: number, productId: number) -> (),
	promptGamePass: (userId: number, passId: number) -> (),
	promptSubscription: (userId: number, subscriptionId: string) -> (),
	ownsGamePass: (userId: number, passId: number) -> boolean,
	subscriptionActive: (userId: number, subscriptionId: string) -> boolean,
	-- Installs the single ProcessReceipt handler.
	onReceipt: ((Receipt) -> Decision) -> (),
}

--- Roblox adapter. `service` is MarketplaceService, `players` is Players and
--- `decisions` is Enum.ProductPurchaseDecision.
function MarketplacePort.roblox(service: any, players: any, decisions: any): Port
	local function player(userId: number): any
		local found = players:GetPlayerByUserId(userId)
		assert(found ~= nil, "PLAYER_NOT_PRESENT")
		return found
	end
	return {
		promptProduct = function(userId, productId)
			service:PromptProductPurchase(player(userId), productId)
		end,
		promptGamePass = function(userId, passId)
			service:PromptGamePassPurchase(player(userId), passId)
		end,
		promptSubscription = function(userId, subscriptionId)
			service:PromptSubscriptionPurchase(player(userId), subscriptionId)
		end,
		ownsGamePass = function(userId, passId)
			return service:UserOwnsGamePassAsync(userId, passId) == true
		end,
		subscriptionActive = function(userId, subscriptionId)
			local status = service:GetUserSubscriptionStatusAsync(player(userId), subscriptionId)
			return type(status) == "table" and status.IsSubscribed == true
		end,
		onReceipt = function(handler)
			service.ProcessReceipt = function(info: any)
				local ok, decision = pcall(handler, info)
				return decisions[if ok and decision == "PurchaseGranted" then "PurchaseGranted" else "NotProcessedYet"]
			end
		end,
	}
end

export type Fake = {
	port: Port,
	-- Complete every prompt at once (redelivering each product receipt `redeliveries` times).
	autoPurchase: boolean,
	redeliveries: number,
	prompts: { string },
	decisions: { Decision },
	owned: { [string]: boolean },
	subscribed: { [string]: boolean },
}

--- Lune fake: a prompt completes synchronously like the engine would, delivering the
--- same PurchaseId `redeliveries` times to the installed ProcessReceipt handler.
function MarketplacePort.fake(): Fake
	local handler: ((Receipt) -> Decision)? = nil
	local purchases = 0
	local fake = {
		autoPurchase = true,
		redeliveries = 1,
		prompts = {} :: { string },
		decisions = {} :: { Decision },
		owned = {} :: { [string]: boolean },
		subscribed = {} :: { [string]: boolean },
	} :: Fake
	fake.port = {
		promptProduct = function(userId, productId)
			table.insert(fake.prompts, "product:" .. userId .. ":" .. productId)
			if fake.autoPurchase and handler then
				purchases += 1
				for _ = 1, fake.redeliveries do
					table.insert(
						fake.decisions,
						handler({ PlayerId = userId, ProductId = productId, PurchaseId = "fake-purchase-" .. purchases })
					)
				end
			end
		end,
		promptGamePass = function(userId, passId)
			table.insert(fake.prompts, "pass:" .. userId .. ":" .. passId)
			if fake.autoPurchase then
				fake.owned[userId .. ":" .. passId] = true
			end
		end,
		promptSubscription = function(userId, subscriptionId)
			table.insert(fake.prompts, "subscription:" .. userId .. ":" .. subscriptionId)
			if fake.autoPurchase then
				fake.subscribed[userId .. ":" .. subscriptionId] = true
			end
		end,
		ownsGamePass = function(userId, passId)
			return fake.owned[userId .. ":" .. passId] == true
		end,
		subscriptionActive = function(userId, subscriptionId)
			return fake.subscribed[userId .. ":" .. subscriptionId] == true
		end,
		onReceipt = function(callback)
			handler = callback
		end,
	}
	return fake
end

return MarketplacePort
