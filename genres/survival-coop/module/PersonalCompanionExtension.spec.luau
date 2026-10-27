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
	["C4 ring commands: out-of-range, non-rideable, stranger and unfiltered names are refused"] = function()
		local rules: any = {
			capacity = 8,
			feedItem = "herbivore-feed",
			feedCount = 3,
			trainingMillis = 0,
			maxSatiety = 100,
			feedSatiety = 30,
			hungerMillis = 60000,
			downMillis = 60000,
		}
		local Content: any = {
			items = { { id = "herbivore-feed", stackMax = 100, weightMilli = 1 } },
			progressionPolicy = { companion = rules },
			wildlifeDetails = {
				{ id = "gallimimus", mount = { enabled = true } },
				{ id = "compsognathus", mount = { enabled = false } },
			},
		}
		local bag =
			Inventory.new("bag", { contentVersion = 2, slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		local pets = Companion.new({}, 0)
		for _, pair in { { "ride", "gallimimus" }, { "tiny", "compsognathus" } } do
			pets = assert(Companion.capture(pets, pair[1], pair[2], rules))
			pets.pets[pair[1]].phase, pets.pets[pair[1]].saddle = "Stored", true
		end
		pets.pets.ride.phase, pets.deployed = "Deployed", "ride"
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
		local port: any = {
			profile = function()
				return profile
			end,
			install = function(nextProfile)
				profile = nextProfile
			end,
			personal = {
				commit = function(_: any, _token: any, expected: number, envelope: any): (any?, string?)
					return { data = { stateRevision = expected + 1, envelope = Data.clone(envelope) } }, nil
				end,
			},
		}
		local distance: number? = 40
		local filtered: string? = "Pebble"
		local extension = Extension.factory({
			content = Content,
			nowMillis = function()
				return 0
			end,
			personalTransfer = function()
				return port
			end,
			world = {
				petDistance = function(_actor: string, _pet: string): number?
					return distance
				end,
				filterPetName = function(_actor: string, _raw: string): string?
					return filtered
				end,
			},
		})
		local serial = 0
		local function command(args: { any }): any
			serial += 1
			return extension.command(
				"actor",
				"survival-coop:companion-action",
				args,
				{ sessionEpoch = 1, requestId = "c4-" .. serial },
				"client",
				function()
					return { ok = true }
				end
			)
		end
		local function companions(): any
			return profile.data.envelope.genres["survival-coop"].data.companions
		end
		assert(command({ "mount", "ride" }).reason == "TOO_FAR", "out of range mount refused")
		assert(command({ "stay", "ride" }).reason == "TOO_FAR", "out of range stay refused")
		distance = nil
		assert(command({ "mount", "ride" }).reason == "PET_ABSENT", "no pet body refused")
		distance = 4
		assert(command({ "mount", "tiny" }).reason == "NOT_RIDEABLE", "riding a non-mount refused")
		assert(command({ "mount", "stranger" }).reason == "NOT_OWNER", "not the owner's pet refused")
		assert(companions().ride == nil, "nothing refused reached state")
		assert(command({ "mount", "ride" }).ok and companions().ride == "ride", "owner in range rides")
		distance = nil
		assert(command({ "stay", "ride" }).reason == "INVALID_PHASE", "the ridden pet's body is the mount")
		distance = 4
		filtered = nil
		assert(command({ "rename:Rocky", "ride" }).reason == "NAME_REJECTED", "filter failure stores nothing")
		filtered = "#####"
		assert(command({ "rename:Rocky", "ride" }).ok, "filtered rename accepted")
		assert(companions().pets.ride.name == "#####", "the filtered text is stored, never the raw name")
	end,
}
