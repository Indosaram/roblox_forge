--!strict
local Extension = require("./PersonalCompanionExtension")
local Companion = require("./CombatCompanion")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Job = require("../../../core/domain/crafting/Job")
local Data = require("../../../core/domain/genre/SerializedData")

return {
	["companion feed and receipt commit together and retry never charges twice"] = function()
		local Content: any = {
			items = { { id = "herbivore-feed", stackMax = 100, weightMilli = 1 } },
			progressionPolicy = {
				companion = {
					capacity = 8,
					feedItem = "herbivore-feed",
					feedCount = 3,
					trainingMillis = 300000,
					maxSatiety = 100,
					feedSatiety = 30,
					hungerMillis = 60000,
					downMillis = 60000,
				},
			},
		}
		local catalog = Job.catalog(Content)
		local bag =
			Inventory.new("bag", { contentVersion = 2, slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		bag = assert(Inventory.add(bag, catalog, {
			itemId = "feed",
			catalogId = "herbivore-feed",
			quantity = 3,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = {},
		}, bag.version))
		local rules = Content.progressionPolicy.companion
		local pets = assert(Companion.capture(Companion.new({}, 0), "pet", "protoceratops", rules))
		local profile: any = {
			data = {
				stateRevision = 0,
				envelope = {
					genres = {
						["survival-coop"] = { data = { inventory = { bag = Inventory.save(bag) }, companions = pets } },
					},
				},
			},
		}
		local fail = true
		local port: any = {
			profile = function()
				return profile
			end,
			install = function(nextProfile)
				profile = nextProfile
			end,
			personal = {
				commit = function(_: any, token: any, expected: number, envelope: any): (any?, string?)
					assert(token == profile and expected == profile.data.stateRevision, "CAS identity")
					if fail then
						return nil, "INJECTED_SAVE_FAILURE"
					end
					return { data = { stateRevision = expected + 1, envelope = Data.clone(envelope) } }, nil
				end,
			},
		}
		local extension = Extension.factory({
			content = Content,
			nowMillis = function()
				return 0
			end,
			personalTransfer = function()
				return port
			end,
		})
		local context = { sessionEpoch = 1, requestId = "feed-once" }
		local function command()
			return extension.command(
				"actor",
				"survival-coop:companion-action",
				{ "feed", "pet" },
				context,
				"client",
				function()
					return { ok = true }
				end
			)
		end
		assert(not command().ok, "failed save refuses action")
		assert(
			profile.data.envelope.genres["survival-coop"].data.inventory.bag.items.feed.quantity == 3,
			"failure keeps bag"
		)
		fail = false
		assert(command().ok, "first accepted command")
		assert(command().ok, "retry is idempotent")
		local saved = profile.data.envelope.genres["survival-coop"].data
		assert(saved.inventory.bag.items.feed.quantity == 2, "one committed debit")
		assert(saved.companions.receipts["1:feed-once"] == "feed:pet", "receipt shares debit")
	end,
}
