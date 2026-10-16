--!strict
-- Specs for Contracts: fixed first day, seeded daily board, clocked swap,
-- five trust tiers and fixed sponsor bundles.

local Content = require("../../../core/domain/survival/Content")
local Contracts = require("./Contracts")

local DAY = 86400000
local HOUR = 3600000

local function raw(): any
	local daily = {}
	for index = 1, 6 do
		table.insert(daily, {
			id = "daily-" .. index,
			faction = if index % 2 == 0 then "surveyors" else "artisans",
			pool = "daily",
			deliver = { { item = "wood", quantity = index } },
			reward = { { item = "fiber", quantity = 1 } },
			trust = 10,
		})
	end
	local entries = {
		{
			id = "first-wood",
			faction = "artisans",
			pool = "first-day",
			deliver = { { item = "wood", quantity = 2 } },
			reward = { { item = "fiber", quantity = 2 } },
			trust = 30,
		},
		{
			id = "first-axe",
			faction = "artisans",
			pool = "first-day",
			deliver = { { item = "axe", quantity = 1 } },
			reward = { { item = "wood", quantity = 1 } },
			trust = 30,
		},
		{
			id = "first-fiber",
			faction = "surveyors",
			pool = "first-day",
			deliver = { { item = "fiber", quantity = 3 } },
			reward = { { item = "wood", quantity = 1 } },
			trust = 30,
		},
	}
	for _, entry in daily do
		table.insert(entries, entry)
	end
	return {
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		tags = { "tool" },
		items = {
			{ id = "wood", name = "Wood", stackMax = 50, weightMilli = 1200 },
			{ id = "fiber", name = "Fiber", stackMax = 50, weightMilli = 200 },
			{ id = "axe", name = "Stone Axe", stackMax = 1, weightMilli = 2500, tags = { "tool" } },
		},
		contracts = {
			factions = {
				{
					id = "artisans",
					name = "Artisan Guilds",
					trustThresholds = { 0, 50, 150, 300, 600 },
					bundles = {
						{ tier = 2, items = { { item = "wood", quantity = 5 }, { item = "fiber", quantity = 5 } } },
					},
				},
				{
					id = "surveyors",
					name = "Route Surveyors",
					trustThresholds = { 0, 40, 120, 260, 500 },
					bundles = {},
				},
			},
			entries = entries,
			-- Authored order deliberately differs from id order.
			firstDay = { "first-wood", "first-axe", "first-fiber" },
			swapCooldownMillis = HOUR,
		},
	}
end

local function catalog(): Contracts.Catalog
	local document, errors = Content.canonicalize(raw())
	assert(document ~= nil, table.concat(errors, "\n"))
	return document.contracts :: Contracts.Catalog
end

local function finishFirstDay(state: Contracts.State, cat: Contracts.Catalog, now: number)
	local held = { wood = 99, fiber = 99, axe = 1 }
	for _, id in cat.firstDay do
		assert(Contracts.accept(state, cat, id, now), "accept " .. id)
		assert(Contracts.deliver(state, cat, id, held, now), "deliver " .. id)
	end
end

return {
	["first day offers the three fixed contracts in authored order"] = function()
		local cat = catalog()
		local state = Contracts.new("player-1")
		local offers = Contracts.offers(state, cat, 5 * DAY)
		assert(#offers == 3, "three first-day contracts")
		assert(offers[1] == "first-wood" and offers[2] == "first-axe" and offers[3] == "first-fiber", "fixed order")
		local other = Contracts.offers(Contracts.new("player-2"), cat, 9 * DAY)
		for index = 1, 3 do
			assert(other[index] == offers[index], "first day is identical for every player and day")
		end
	end,

	["first day contracts are taught in order and open the board"] = function()
		local cat = catalog()
		local state = Contracts.new("player-1")
		local ok, reason = Contracts.accept(state, cat, "first-axe", 0)
		assert(not ok and reason == "OUT_OF_ORDER", "second contract refused before the first")
		local accepted, acceptReason = Contracts.accept(state, cat, "daily-1", 0)
		assert(not accepted and acceptReason == "NOT_OFFERED", "daily contract hidden on the first day")
		assert(Contracts.accept(state, cat, "first-wood", 0), "first contract accepted")
		local short, shortReason = Contracts.deliver(state, cat, "first-wood", { wood = 1 }, 0)
		assert(short == nil and shortReason == "INSUFFICIENT_ITEMS", "partial delivery refused")
		local delivery = assert(Contracts.deliver(state, cat, "first-wood", { wood = 2 }, 0))
		assert(delivery.consume[1].item == "wood" and delivery.consume[1].quantity == 2, "exact consume list")
		assert(delivery.reward[1].item == "fiber" and delivery.reward[1].quantity == 2, "exact reward list")
		assert(not delivery.boardOpened and state.phase == "first-day", "board still closed")
		local again, againReason = Contracts.deliver(state, cat, "first-wood", { wood = 2 }, 0)
		assert(again == nil and againReason == "NOT_ACCEPTED", "a contract cannot be delivered twice")
		assert(Contracts.accept(state, cat, "first-axe", 0), "first-axe accepted")
		assert(Contracts.deliver(state, cat, "first-axe", { axe = 1 }, 0), "first-axe delivered")
		assert(Contracts.accept(state, cat, "first-fiber", 0))
		local last = assert(Contracts.deliver(state, cat, "first-fiber", { fiber = 3 }, 0))
		assert(last.boardOpened and (state.phase :: string) == "board", "third delivery opens the board")
		assert(#Contracts.offers(state, cat, 0) == 3, "board shows three daily contracts")
	end,

	["daily board is deterministic per player and day and differs across seeds"] = function()
		local cat = catalog()
		local a = Contracts.roll(cat, "player-1", 20000)
		local b = Contracts.roll(cat, "player-1", 20000)
		assert(#a == 3, "three daily contracts")
		local seen: { [string]: boolean } = {}
		for index = 1, 3 do
			assert(a[index] == b[index], "same player and day replays the same board")
			assert(string.match(a[index], "^daily%-") ~= nil, "only daily-pool contracts")
			assert(not seen[a[index]], "no duplicate contract on one board")
			seen[a[index]] = true
		end
		local differs = false
		for day = 20001, 20030 do
			local other = Contracts.roll(cat, "player-1", day)
			for index = 1, 3 do
				differs = differs or other[index] ~= a[index]
			end
		end
		assert(differs, "the board changes across days")
		assert(Contracts.seed("player-1", 20000) ~= Contracts.seed("player-2", 20000), "player id feeds the seed")
		assert(Contracts.seed("player-1", 20000) ~= Contracts.seed("player-1", 20001), "day key feeds the seed")
		assert(Contracts.dayKey(cat, 3 * DAY - 1) == 2 and Contracts.dayKey(cat, 3 * DAY) == 3, "day boundary")
	end,

	["board refreshes on the next day and survives a same-day rejoin"] = function()
		local cat = catalog()
		local state = Contracts.new("player-7")
		finishFirstDay(state, cat, 10 * DAY)
		local today = Contracts.offers(state, cat, 10 * DAY + HOUR)
		local restored = Contracts.fromSave(Contracts.toSave(state))
		local after = Contracts.offers(restored, cat, 10 * DAY + 2 * HOUR)
		for index = 1, 3 do
			assert(after[index] == today[index], "same-day rejoin keeps the board")
		end
		local tomorrow = Contracts.offers(restored, cat, 11 * DAY)
		local expected = Contracts.roll(cat, "player-7", 11)
		for index = 1, 3 do
			assert(tomorrow[index] == expected[index], "next day rolls the seeded board")
		end
	end,

	["swap obeys the clock cooldown and never repeats a shown contract"] = function()
		local cat = catalog()
		local state = Contracts.new("player-3")
		local now = 4 * DAY
		finishFirstDay(state, cat, now)
		local locked, lockedReason = Contracts.swap(Contracts.new("fresh"), cat, 1, now)
		assert(locked == nil and lockedReason == "BOARD_LOCKED", "no swap during the first day")
		local before = Contracts.offers(state, cat, now)
		local replacement = assert(Contracts.swap(state, cat, 1, now))
		for _, id in before do
			assert(replacement ~= id, "swap draws an unseen contract")
		end
		local early, earlyReason = Contracts.swap(state, cat, 2, now + HOUR - 1)
		assert(early == nil and earlyReason == "SWAP_COOLDOWN", "cooldown refuses one millisecond early")
		assert(Contracts.swap(state, cat, 2, now + HOUR), "cooldown elapses on the injected clock")
		local id = Contracts.offers(state, cat, now + HOUR)[3]
		assert(Contracts.accept(state, cat, id, now + HOUR))
		local taken, takenReason = Contracts.swap(state, cat, 3, now + 2 * HOUR)
		assert(taken == nil and takenReason == "SLOT_ACCEPTED", "accepted slot cannot be swapped")
		local replay = Contracts.new("player-3")
		finishFirstDay(replay, cat, now)
		assert(Contracts.swap(replay, cat, 1, now) == replacement, "swap replays from the seed")
	end,

	["trust walks five tiers and sponsor bundles are fixed and claimed once"] = function()
		local cat = catalog()
		assert(Contracts.tier(cat, "artisans", 0) == 1, "tier 1 at zero")
		assert(Contracts.tier(cat, "artisans", 49) == 1, "just below a threshold stays")
		assert(Contracts.tier(cat, "artisans", 50) == 2, "threshold reaches the tier")
		assert(Contracts.tier(cat, "artisans", 10 ^ 6) == 5, "five tiers maximum")
		local state = Contracts.new("player-9")
		local early, earlyReason = Contracts.claimBundle(state, cat, "artisans", 2)
		assert(early == nil and earlyReason == "TIER_LOCKED", "bundle locked below its tier")
		finishFirstDay(state, cat, 0)
		assert(state.trust.artisans == 60, "two artisan first-day contracts")
		local bundle = assert(Contracts.claimBundle(state, cat, "artisans", 2))
		assert(#bundle == 2 and bundle[1].item == "fiber" and bundle[1].quantity == 5, "fixed composition")
		assert(bundle[2].item == "wood" and bundle[2].quantity == 5, "fixed composition, item order")
		local twice, twiceReason = Contracts.claimBundle(state, cat, "artisans", 2)
		assert(twice == nil and twiceReason == "ALREADY_CLAIMED", "claimed once")
		local other = Contracts.new("player-10")
		finishFirstDay(other, cat, 0)
		local same = assert(Contracts.claimBundle(other, cat, "artisans", 2))
		assert(same[1].quantity == bundle[1].quantity and same[2].quantity == bundle[2].quantity, "no chance")
	end,

	["content rejects malformed contract sections"] = function()
		local cases: { [string]: (any) -> () } = {
			["trustThresholds: expected exactly 5 tiers"] = function(doc)
				doc.contracts.factions[1].trustThresholds = { 0, 10, 20, 30 }
			end,
			["trustThresholds[3]: expected 0 then strictly ascending"] = function(doc)
				doc.contracts.factions[1].trustThresholds = { 0, 10, 10, 30, 40 }
			end,
			["firstDay: expected exactly 3"] = function(doc)
				doc.contracts.firstDay = { "first-wood", "first-axe" }
			end,
			["firstDay[2]: expected a first-day contract id"] = function(doc)
				doc.contracts.firstDay = { "first-wood", "daily-1", "first-fiber" }
			end,
			["bundles[1]: unknown field chance"] = function(doc)
				doc.contracts.factions[1].bundles[1].chance = 50
			end,
			["faction: unknown faction ghosts"] = function(doc)
				doc.contracts.entries[1].faction = "ghosts"
			end,
			["daily pool has 2, needs 3"] = function(doc)
				for index = #doc.contracts.entries, 6, -1 do
					table.remove(doc.contracts.entries, index)
				end
			end,
		}
		for expected, mutate in cases do
			local doc = raw()
			mutate(doc)
			local errors = Content.validate(doc)
			local found = false
			for _, err in errors do
				found = found or string.find(err, expected, 1, true) ~= nil
			end
			assert(found, expected .. " not reported; got: " .. table.concat(errors, " | "))
		end
		assert(#Content.validate(raw()) == 0, "the valid fixture passes")
	end,
}
