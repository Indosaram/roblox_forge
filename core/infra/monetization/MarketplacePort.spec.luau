--!strict
local MarketplacePort = require("./MarketplacePort")
local PolicyPort = require("./PolicyPort")

return {
	["fake redelivers one purchase id to the receipt handler"] = function()
		local fake = MarketplacePort.fake()
		fake.redeliveries = 3
		local seen: { string } = {}
		fake.port.onReceipt(function(receipt)
			table.insert(seen, receipt.PurchaseId)
			return "PurchaseGranted"
		end)
		fake.port.promptProduct(7, 11)
		assert(#seen == 3 and seen[1] == seen[3], "same purchase id redelivered")
		assert(#fake.decisions == 3 and fake.prompts[1] == "product:7:11", "recorded")
	end,
	["roblox adapter maps services and decisions"] = function()
		local calls: { string } = {}
		local service: any = {
			PromptProductPurchase = function(_self: any, player: any, id: number)
				table.insert(calls, "product:" .. player.UserId .. ":" .. id)
			end,
			PromptGamePassPurchase = function(_self: any, player: any, id: number)
				table.insert(calls, "pass:" .. player.UserId .. ":" .. id)
			end,
			PromptSubscriptionPurchase = function(_self: any, player: any, id: string)
				table.insert(calls, "sub:" .. player.UserId .. ":" .. id)
			end,
			UserOwnsGamePassAsync = function(_self: any, userId: number, id: number)
				return userId == 5 and id == 9
			end,
			GetUserSubscriptionStatusAsync = function(_self: any, _player: any, _id: string)
				return { IsSubscribed = true }
			end,
		}
		local players: any = {
			GetPlayerByUserId = function(_self: any, userId: number)
				return if userId == 5 then { UserId = 5 } else nil
			end,
		}
		local decisions = { PurchaseGranted = "G", NotProcessedYet = "N" }
		local port = MarketplacePort.roblox(service, players, decisions)
		port.promptProduct(5, 1)
		port.promptGamePass(5, 2)
		port.promptSubscription(5, "sub")
		assert(table.concat(calls, ",") == "product:5:1,pass:5:2,sub:5:sub", table.concat(calls, ","))
		assert(port.ownsGamePass(5, 9) and not port.ownsGamePass(5, 8), "pass ownership")
		assert(port.subscriptionActive(5, "sub"), "subscription status")
		assert(not pcall(port.promptProduct, 6, 1), "absent player refused")
		port.onReceipt(function(receipt)
			return if receipt.PurchaseId == "ok" then "PurchaseGranted" else error("boom")
		end)
		assert(service.ProcessReceipt({ PurchaseId = "ok" }) == "G", "granted mapped")
		assert(service.ProcessReceipt({ PurchaseId = "bad" }) == "N", "handler error is retryable")
	end,
	["policy fake and adapter report eligibility"] = function()
		local fake = PolicyPort.fake({ ["1"] = true }, { ["3"] = true })
		assert(fake.getPolicyInfo(1).IsEligibleToPurchaseSubscription == true, "eligible")
		assert(fake.getPolicyInfo(2).IsEligibleToPurchaseSubscription == false, "ineligible")
		assert(not pcall(fake.getPolicyInfo, 3), "lookup failure errors")
		local service: any = {
			GetPolicyInfoForPlayerAsync = function(_self: any, player: any)
				return { IsEligibleToPurchaseSubscription = player.UserId == 1 }
			end,
		}
		local players: any = {
			GetPlayerByUserId = function(_self: any, userId: number)
				return if userId == 1 then { UserId = 1 } else nil
			end,
		}
		local adapter = PolicyPort.roblox(service, players)
		assert(adapter.getPolicyInfo(1).IsEligibleToPurchaseSubscription, "adapter eligible")
		assert(not pcall(adapter.getPolicyInfo, 2), "absent player errors")
	end,
}
