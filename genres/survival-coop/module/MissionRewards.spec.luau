--!strict
local Rewards = require("./MissionRewards")
local Personal = require("../../../core/infra/data/PersonalAggregate")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Inventory = require("../../../core/domain/inventory/Inventory")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Content: any = luau.load(fs.readFile("games/robango-island/src/shared/SurvivalContent.luau"))()
local function harness()
	local backend = Memory.new()
	local store = Personal.new(backend, {
		namespace = "p",
		inventoryPath = { "bag" },
		validateEnvelope = function()
			return true
		end,
		store = {
			sessionId = "s",
			leaseSeconds = 30,
			now = function()
				return 10
			end,
			budget = {
				encode = function(value)
					return require("@lune/serde").encode("json", value)
				end,
			},
		},
	})
	local token = assert(store:load("owner", function()
		return {
			bag = Inventory.save(
				Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
			),
			genres = {
				["survival-coop"] = {
					data = {
						balance = 0,
						progression = { level = 1, xp = 0, sp = 3, paid = {}, mastery = {}, receipts = {}, version = 0 },
					},
				},
			},
		}
	end))
	local document: any = {}
	local env = {
		content = Content,
		personal = function()
			return {
				personal = store,
				profile = function()
					return token
				end,
				install = function(value)
					token = value
				end,
			}
		end,
		store = {
			snapshot = function()
				return document
			end,
			transaction = function(_actor, transform)
				return transform(document)
			end,
		},
	}
	return document,
		env,
		function()
			return token.data.envelope.genres["survival-coop"].data
		end,
		function(catalogId: string): number
			local total = 0
			for _, item in token.data.envelope.bag.items do
				if item.catalogId == catalogId then
					total += item.quantity
				end
			end
			return total
		end
end

-- Mirrors ArchipelagoExtension.change: rewards enqueue, then the definition is
-- marked cleared in the development ledger.
local function complete(document: any, expedition: string, mission: any)
	document.archipelago = { id = expedition, revision = "v2", status = "complete", completed = {} }
	for _, objective in mission.objectives do
		document.archipelago.completed[objective.id] = true
	end
	Rewards.enqueue(document, Content)
	document.development = document.development or { points = 0, definitions = {} }
	document.development.definitions[mission.id] = true
end

local function multiObjective(): any
	for _, mission in Content.missions do
		if #mission.objectives >= 2 then
			return mission
		end
	end
	error("no multi-objective mission")
end

return {
	["results ledger lists the items its missions paid, merged per item"] = function()
		local document: any = {
			archipelago = { id = "trip-9", revision = "v2", status = "complete", completed = {}, templateId = "rw.a1" },
		}
		local content = {
			missions = {
				{ id = "m.a", objectives = { { id = "o.a" } } },
				{ id = "m.b", objectives = { { id = "o.b" } } },
			},
		}
		local Journal = require("../../../core/domain/command/Journal")
		document.missionRewards = {}
		for _, pair in { { id = "m.a", quantity = 2 }, { id = "m.b", quantity = 3 } } do
			document.missionRewards["mission:" .. Journal.fnv1a64("trip-9:v2:" .. pair.id)] = {
				rewards = { xp = 5, coins = 7, items = { { item = "plank", quantity = pair.quantity } } },
			}
		end
		Rewards.ledger(document, content)
		local row = document.resultsLedger["trip-9"]
		assert(row.coins == 14 and row.xp == 10, "totals")
		assert(#row.items == 1 and row.items[1].item == "plank" and row.items[1].quantity == 5, "items merged")
	end,
	["mission pays once per completion, not once per objective"] = function()
		local document, env, wallet = harness()
		local mission = multiObjective()
		complete(document, "trip-1", mission)
		Rewards.enqueue(document, Content)
		assert(Rewards.settle("owner", env).ok, "settle")
		local count = 0
		for _ in document.missionRewards do
			count += 1
		end
		assert(count == 1, "one outbox entry for " .. #mission.objectives .. " objectives: " .. count)
		assert(wallet().balance == mission.rewards.coins, "full coins once: " .. wallet().balance)
	end,
	["partial mission completion pays nothing"] = function()
		local document, env, wallet = harness()
		local mission = multiObjective()
		document.archipelago =
			{ id = "trip-1", revision = "v2", status = "active", completed = { [mission.objectives[1].id] = true } }
		Rewards.enqueue(document, Content)
		assert(Rewards.settle("owner", env).ok, "settle")
		assert(wallet().balance == 0, "no payout before every objective completes")
	end,
	["repeat clear in a new expedition pays the 20 percent repeat share"] = function()
		local document, env, wallet = harness()
		local mission = multiObjective()
		complete(document, "trip-1", mission)
		assert(Rewards.settle("owner", env).ok, "first settle")
		local first = wallet().balance
		local firstReputation = document.reputation[mission.rewards.reputation[1].id]
		complete(document, "trip-2", mission)
		assert(Rewards.settle("owner", env).ok, "repeat settle")
		local share = (mission.rewards.coins * Rewards.REPEAT_PERMILLE) // 1000
		assert(share > 0 and share < mission.rewards.coins, "repeat share is reduced")
		assert(wallet().balance == first + share, "repeat pays 20%: " .. wallet().balance)
		local repShare = (mission.rewards.reputation[1].value * Rewards.REPEAT_PERMILLE) // 1000
		assert(document.reputation[mission.rewards.reputation[1].id] == firstReputation + repShare, "repeat reputation")
	end,
	["replaying the same expedition receipt never pays twice"] = function()
		local document, env, wallet = harness()
		local mission = multiObjective()
		complete(document, "trip-1", mission)
		assert(Rewards.settle("owner", env).ok, "settle")
		local balance, xp, level = wallet().balance, wallet().progression.xp, wallet().progression.level
		complete(document, "trip-1", mission)
		for id, entry in document.missionRewards do
			entry.settled = false
			document.missionRewards[id] = entry
		end
		assert(Rewards.settle("owner", env).ok, "replay settle")
		assert(
			wallet().balance == balance and wallet().progression.xp == xp and wallet().progression.level == level,
			"personal receipt blocks double pay"
		)
	end,
	["personal reward receipt survives lost outbox acknowledgement and expiry"] = function()
		local backend = Memory.new()
		local store = Personal.new(backend, {
			namespace = "p",
			inventoryPath = { "bag" },
			validateEnvelope = function()
				return true
			end,
			store = {
				sessionId = "s",
				leaseSeconds = 30,
				now = function()
					return 10
				end,
				budget = {
					encode = function(value)
						return require("@lune/serde").encode("json", value)
					end,
				},
			},
		})
		local token = assert(store:load("owner", function()
			return {
				genres = {
					["survival-coop"] = {
						data = {
							balance = 0,
							progression = {
								level = 1,
								xp = 0,
								sp = 3,
								paid = {},
								mastery = {},
								receipts = {},
								version = 0,
							},
						},
					},
				},
			}
		end))
		local mission = Content.missions[1]
		local document: any = {
			archipelago = {
				id = "trip",
				revision = "v2",
				status = "expired",
				completed = { [mission.objectives[1].id] = true },
			},
		}
		Rewards.enqueue(document, Content)
		local acknowledge = false
		local env = {
			content = Content,
			personal = function()
				return {
					personal = store,
					profile = function()
						return token
					end,
					install = function(value)
						token = value
					end,
				}
			end,
			store = {
				snapshot = function()
					return document
				end,
				transaction = function(_actor, transform)
					if not acknowledge then
						return { ok = false, reason = "ack_failed" }
					end
					return transform(document)
				end,
			},
		}
		assert(Rewards.settle("owner", env).reason == "ack_failed", "acknowledgement fails after personal commit")
		local awarded = token.data.envelope.genres["survival-coop"].data
		assert(awarded.balance == mission.rewards.coins, "coins committed before acknowledgement")
		local xp, level = awarded.progression.xp, awarded.progression.level
		acknowledge = true
		assert(Rewards.settle("owner", env).ok, "retry acknowledges existing receipt")
		assert(Rewards.settle("owner", env).ok, "settled replay")
		local after = token.data.envelope.genres["survival-coop"].data
		assert(
			after.balance == awarded.balance and after.progression.xp == xp and after.progression.level == level,
			"coins and XP apply once"
		)
		assert(
			document.reputation[mission.rewards.reputation[1].id] == mission.rewards.reputation[1].value,
			"reputation once"
		)
	end,
	["guide rewards pay declared xp and coins once; a repeat pays nothing"] = function()
		local document, env, wallet = harness()
		local guide = Content.guides[1]
		assert(guide.rewards.xp > 0 and guide.rewards.coins > 0, "g01 declares xp and coins")
		Rewards.enqueueGuide(document, guide)
		assert(Rewards.settle("owner", env).ok, "settle")
		local paid = wallet()
		assert(paid.balance == guide.rewards.coins, "coins once: " .. paid.balance)
		local xp, level = paid.progression.xp, paid.progression.level
		assert(level > 1 or xp == guide.rewards.xp, "xp applied")
		Rewards.enqueueGuide(document, guide)
		document.missionRewards[Rewards.guideId(guide.id)].settled = false
		assert(Rewards.settle("owner", env).ok, "repeat settle")
		local after = wallet()
		assert(
			after.balance == paid.balance and after.progression.xp == xp and after.progression.level == level,
			"repeat pays nothing"
		)
	end,
	["guide item rewards land in the bag once under guide:<id>; a second settlement is refused"] = function()
		local document, env, wallet, held = harness()
		local guide = Content.guides[1]
		local stack = guide.rewards.items[1]
		assert(stack and stack.quantity > 0, "g01 declares an item reward")
		Rewards.enqueueGuide(document, guide)
		local entry = document.missionRewards[Rewards.guideId(guide.id)]
		assert(entry and entry.rewards.items[1].item == stack.item, "outbox keyed guide:<id> carries the items")
		assert(Rewards.settle("owner", env).ok, "settle")
		assert(held(stack.item) == stack.quantity, "items paid once: " .. held(stack.item))
		local balance = wallet().balance
		-- Second enqueue keeps the one entry; a forced re-settlement hits the receipt.
		Rewards.enqueueGuide(document, guide)
		document.missionRewards[Rewards.guideId(guide.id)].settled = false
		assert(Rewards.settle("owner", env).ok, "repeat settle")
		assert(held(stack.item) == stack.quantity, "second settlement refused: " .. held(stack.item))
		assert(wallet().balance == balance, "no second coins")
	end,
	["every authored guide item reward is a catalog item"] = function()
		local ids = {}
		for _, item in Content.items do
			ids[item.id] = true
		end
		for _, guide in Content.guides do
			for _, stack in guide.rewards.items or {} do
				assert(ids[stack.item] and stack.quantity > 0, guide.id .. " pays unknown item " .. stack.item)
			end
		end
	end,
	["repeat clears add the level-scaled bonus only between the policy levels"] = function()
		local policy = { repeatXPPerLevel = 9, repeatXPMinLevel = 6, repeatXPMaxLevel = 30 }
		local content = { missionPolicy = policy }
		assert(Rewards.repeatBonus(content, 5) == 0 and Rewards.repeatBonus(content, 31) == 0, "outside")
		assert(Rewards.repeatBonus(content, 6) == 54 and Rewards.repeatBonus(content, 30) == 270, "inside")
		-- Robango restores the spec curve (owner decision 2026-10-23): no repeat-clear level bonus.
		assert(Rewards.repeatBonus(Content, 30) == 0, "robango pays no repeat bonus")
	end,
}
