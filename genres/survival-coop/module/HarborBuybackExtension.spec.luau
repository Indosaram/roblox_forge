--!strict
-- HarborBuybackExtension over a real PersonalAggregate and the robango content harborPolicy:
-- fixed price, shared daily cap, atomic bag + Coins update, refusals leave state intact.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Memory = require("../../../core/infra/data/MemoryBackend")
local PersonalAggregate = require("../../../core/infra/data/PersonalAggregate")
local Content = require("../../../core/domain/survival/Content")
local Harbor = require("./HarborBuybackExtension")

local DAY = 86400
local PATH = { "genres", "survival-coop", "data", "inventory", "bag" }
local canonical, errors = Content.canonicalize(serde.decode("yaml", fs.readFile("games/robango-island/content.yml")))
local content = assert(canonical, table.concat(errors, "; "))
local budget = {
	encode = function(value: any): string
		return serde.encode("json", value)
	end,
}

local function stack(itemId: string, catalogId: string, quantity: number, attributes: any?): any
	return {
		itemId = itemId,
		catalogId = catalogId,
		quantity = quantity,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = attributes or {},
	}
end

local function world(items: { any }, layout: string?, sold: number?, balance: number?)
	-- 30 s before a UTC midnight, so a day rollover stays inside the personal lease.
	local clock = { now = 31 * DAY - 30 }
	local now = function()
		return clock.now
	end
	local personal = PersonalAggregate.new(Memory.new(), {
		namespace = "personal",
		inventoryPath = PATH,
		validateEnvelope = function(value)
			return type(value) == "table" and value.version == 1
		end,
		store = { sessionId = "players", leaseSeconds = 120, now = now, budget = budget },
	})
	local map = {}
	for _, item in items do
		map[item.itemId] = item
	end
	local token = assert(personal:load("1", function()
		return {
			version = 1,
			genres = {
				["survival-coop"] = {
					version = 1,
					data = {
						balance = balance or 5,
						harborBuyback = if sold then { day = 30, sold = sold } else nil,
						inventory = {
							bag = {
								id = "bag",
								version = 0,
								saveVersion = 1,
								limits = { slots = 8, softWeightMilli = 90000, hardWeightMilli = 90000 },
								items = map,
								reservations = {},
							},
						},
					},
				},
			},
		}
	end))
	local self: any = { clock = clock }
	local extension = assert(Harbor.factory({
		content = content,
		now = now,
		world = { layout = { id = layout or "rw.harbor" } },
		personalTransfer = function(actor: string): any
			if actor ~= "1" then
				return nil
			end
			return {
				personal = personal,
				profile = function()
					return token
				end,
				install = function(next)
					token = next
				end,
			}
		end,
	}))
	function self.sell(catalogId: string, quantity: number): any
		return extension.command(
			"1",
			Harbor.SELL,
			{ catalogId, quantity },
			{ actorId = "1", requestId = "r", sessionEpoch = 0 },
			"client",
			function()
				return { ok = true }
			end
		)
	end
	function self.repair(itemId: string): any
		return extension.command(
			"1",
			Harbor.REPAIR,
			{ itemId },
			{ actorId = "1", requestId = itemId, sessionEpoch = 0 },
			"client",
			function()
				return { ok = true }
			end
		)
	end
	function self.data(): any
		return token.data.envelope.genres["survival-coop"].data
	end
	function self.held(catalogId: string): number
		local total = 0
		for _, item in self.data().inventory.bag.items do
			if item.catalogId == catalogId then
				total += item.quantity
			end
		end
		return total
	end
	self.extension = extension
	return self
end

return {
	["content declares the spec buyback prices and the 200 unit daily cap"] = function()
		local policy = assert(Harbor.policy(content))
		assert(policy.prices.wood == 1 and policy.prices.stone == 1 and policy.prices.fiber == 1, "raw at 1")
		assert(policy.prices.meat == 2 and policy.dailyUnits == 200 and policy.daySeconds == DAY, "meat 2, cap")
		local count = 0
		for _ in policy.prices do
			count += 1
		end
		assert(count == 4, "exactly the four spec raw ids")
	end,
	["selling raw units credits fixed Coins and takes the units atomically"] = function()
		local w = world({ stack("w1", "wood", 30), stack("w2", "wood", 20), stack("m", "meat", 5) })
		local sold = w.sell("wood", 40)
		assert(sold.ok and sold.data.coins == 40 and sold.data.remaining == 160, tostring(sold.reason))
		assert(w.held("wood") == 10 and w.data().balance == 45, "40 wood -> 40 coins")
		local meat = w.sell("meat", 5)
		assert(meat.ok and meat.data.coins == 10 and w.data().balance == 55 and w.held("meat") == 0, "meat at 2")
		assert(w.extension.snapshot("1").remaining == 155, "snapshot shows the shared remaining cap")
	end,
	["refusals leave bag, Coins and the daily count unchanged"] = function()
		-- 190 of today's 200 shared units are already sold.
		local w = world(
			{ stack("w", "wood", 50), stack("x", "wood", 10), stack("p", "fiber", 3, { robuxPurchased = true }) },
			nil,
			190
		)
		local before = serde.encode("json", w.data())
		local cases: { { any } } = {
			{ "wood", 11, "DAILY_CAP" },
			{ "fiber", 1, "INSUFFICIENT_ITEMS" },
			{ "stone", 1, "INSUFFICIENT_ITEMS" },
			{ "berry", 1, "NOT_BOUGHT" },
			{ "wood", 0, "INVALID_QUANTITY" },
		}
		for _, case in cases do
			local result = w.sell(case[1], case[2])
			assert(not result.ok and result.reason == case[3], case[1] .. ": " .. tostring(result.reason))
			assert(serde.encode("json", w.data()) == before, "refusal changed state: " .. case[3])
		end
		assert(w.sell("wood", 10).ok and w.data().balance == 15, "sale up to the cap accepted")
		local capped = w.sell("wood", 1)
		assert(not capped.ok and capped.reason == "DAILY_CAP" and w.held("wood") == 50, "cap holds for the day")
		w.clock.now += 60
		assert(w.sell("wood", 1).ok and w.data().balance == 16, "next UTC day sells again")
	end,
	["item-repair charges Job.repairCost Coins and refusals change nothing"] = function()
		local worn = stack("axe", "axe-t2", 1)
		worn.durabilityMilli = 40000
		local w = world({ worn, stack("w", "wood", 5) }, "rw.home", nil, 25)
		assert((Harbor.factory({ content = content }) :: any).handles(Harbor.REPAIR), "repair op enables item-repair")
		local before = serde.encode("json", w.data())
		for itemId, reason in { w = "NOT_REPAIRABLE", ghost = "UNKNOWN_ITEM" } :: { [string]: string } do
			local refused = w.repair(itemId)
			assert(not refused.ok and refused.reason == reason, itemId .. ": " .. tostring(refused.reason))
		end
		assert(serde.encode("json", w.data()) == before, "refusals leave state intact")
		local repaired = w.repair("axe")
		assert(repaired.ok and w.data().balance == 5, "tier 2 repair costs 20 Coins away from the harbor")
		assert(repaired.reason == nil, "an accepted repair carries no refusal reason: " .. tostring(repaired.reason))
		local fixed = w.data().inventory.bag.items.axe
		assert(fixed.durabilityMilli == fixed.maxDurabilityMilli and fixed.maxDurabilityMilli < 100000, "refilled")
		fixed.durabilityMilli = 1
		local poor = world({ fixed }, nil, nil, 19).repair("axe")
		assert(not poor.ok and poor.reason == "INSUFFICIENT_FUNDS", "cannot afford: " .. tostring(poor.reason))
	end,
	["item-repair refuses items without an eligible tag, with a localized reason"] = function()
		local Locale = require("./SurvivalHUDLocale")
		-- capture-bola is a durable tool without a repair tag (repair-equipment.eligibleTags).
		local worn = stack("bola", "capture-bola", 1)
		worn.durabilityMilli = 1000
		local w = world({ worn }, "rw.home", nil, 100)
		local before = serde.encode("json", w.data())
		local refused = w.repair("bola")
		assert(not refused.ok and refused.reason == "INELIGIBLE_REPAIR", "ineligible: " .. tostring(refused.reason))
		assert(serde.encode("json", w.data()) == before, "refusal leaves bag and Coins intact")
		for _, locale in { "en-us", "ko-kr" } do
			local text = Locale.refusal(locale, refused.reason)
			assert(text ~= Locale.refusal(locale, "unknown") and text ~= refused.reason, locale .. " localized")
		end
		local club = stack("club", "starter-club", 1)
		club.durabilityMilli = 1000
		assert(world({ club }, "rw.home", nil, 100).repair("club").ok, "starter club carries weapon-tool")
	end,
	["only the harbor buys"] = function()
		local w = world({ stack("w", "wood", 5) }, "rw.home")
		local result = w.sell("wood", 1)
		assert(not result.ok and result.reason == "NOT_AT_HARBOR" and w.held("wood") == 5, "home refuses")
	end,
}
