--!strict
local Rewards = require("./MissionRewards")
local Personal = require("../../../core/infra/data/PersonalAggregate")
local Memory = require("../../../core/infra/data/MemoryBackend")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Content: any = luau.load(fs.readFile("games/robango-island/src/shared/SurvivalContent.luau"))()
return {
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
