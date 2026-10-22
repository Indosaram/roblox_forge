--!strict
local Rewards = require("./MissionRewards")
local Personal = require("../../../core/infra/data/PersonalAggregate")
local Memory = require("../../../core/infra/data/MemoryBackend")
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
	return document, env, function()
		return token.data.envelope.genres["survival-coop"].data
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
}
