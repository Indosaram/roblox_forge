--!strict
local Transfer = require("./HomeTransfer")
local Home = require("../../../core/domain/home/HomeState")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Personal = require("../../../core/infra/data/PersonalAggregate")
local Fenced = require("../../../core/infra/data/FencedStore")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Spoilage = require("../../../core/domain/survival/Spoilage")
local serde = require("@lune/serde")
local HOUR = 3600 * 1000
local BERRY: any =
	{ id = "berry", name = "Berry", stackMax = 50, weightMilli = 1, tags = {}, foodEffects = { hungerMilli = 1 } }
local SPOILED: any = { id = "spoiled-food", name = "Spoiled", stackMax = 50, weightMilli = 1, tags = {} }
return {
	["food keeps its age across a refrigerated home and ages at a quarter rate there"] = function()
		local backend = Memory.new()
		local options = {
			sessionId = "test",
			leaseSeconds = 30,
			now = function()
				return 10
			end,
			budget = {
				encode = function(value)
					return serde.encode("json", value)
				end,
			},
		}
		local policy = assert(Spoilage.policy({
			items = { BERRY, SPOILED },
			operations = {
				{
					id = "food-spoilage",
					seconds = 172800,
					outputs = { { item = "spoiled-food", quantity = 1 } },
					effects = { { id = "refrigeration-age-rate", value = 0.25 } },
				},
			},
		}))
		local catalog = Catalog.new({ BERRY, SPOILED } :: any)
		local bag = Inventory.new(
			"bag",
			{ kind = "bag", contentVersion = 2, slots = 30, softWeightMilli = 100, hardWeightMilli = 100 }
		)
		bag = assert(Inventory.add(bag, catalog, {
			itemId = "berry-1",
			catalogId = "berry",
			quantity = 2,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = { freshAt = 0, freshAge = 0 },
		}, bag.version))
		local personal = Personal.new(backend, {
			namespace = "p",
			store = options,
			inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" },
			validateEnvelope = function()
				return true
			end,
		})
		local token = assert(personal:load("owner", function()
			return { genres = { ["survival-coop"] = { data = { inventory = { bag = Inventory.save(bag) } } } } }
		end))
		local home = Home.new("owner", { baseSlots = 5, dock = {} }, 1)
		home.structures.fridge = { kind = "refrigerator", position = { x = 0, y = 0, z = 0 }, owner = "owner" }
		local store = Fenced.new(backend, options)
		local held = assert(store:acquire("home:owner", function()
			return { home = home }
		end))
		local clock = 0
		local api = Transfer.new({
			catalog = catalog,
			now = options.now,
			spoilage = policy,
			nowMillis = function()
				return clock
			end,
			personal = function()
				return {
					personal = personal,
					profile = function()
						return token
					end,
					install = function(value)
						token = value
					end,
				}
			end,
			open = function()
				held = assert(store:refresh(held))
				return held
			end,
			update = function(_actor, transform)
				local value, err = store:update(held, transform)
				if value then
					held = value
				end
				return value, err
			end,
		})
		local function command(deposit, quantity, requestId)
			return api.command(
				"owner",
				deposit,
				"berry-1",
				quantity,
				{ sessionEpoch = 1, requestId = requestId },
				function()
					return { ok = true }
				end
			)
		end
		assert(Transfer.refrigerated(home), "a placed refrigerator makes home storage cold")
		clock = 40 * HOUR
		assert(command(true, 2, "deposit").ok, "deposit")
		local stored = held.data.home.storage.items["berry-1"]
		assert(stored.attributes.freshAt == 40 * HOUR and stored.attributes.freshAge == 40 * HOUR, "bag age kept")
		-- 30 h in the refrigerator is 7.5 equivalent hours: still fresh (47.5 h < 48 h).
		clock = 70 * HOUR
		assert(command(false, 2, "withdraw").ok, "withdraw")
		local back = token.data.envelope.genres["survival-coop"].data.inventory.bag.items["berry-1"]
		assert(back.catalogId == "berry", "refrigerated berry is still fresh")
		assert(back.attributes.freshAge == 47 * HOUR + 30 * 60 * 1000, "quarter-rate home age carried out")
		-- Without the refrigerator the same 30 h would have spoiled it at full rate.
		assert(Spoilage.age(stored, policy, 70 * HOUR, false) == 70 * HOUR, "uncooled age")
	end,
	["full home refuses without debit and expired tier overflow remains withdraw only"] = function()
		local backend = Memory.new()
		local options = {
			sessionId = "test",
			leaseSeconds = 30,
			now = function()
				return 10
			end,
			budget = {
				encode = function(value)
					return serde.encode("json", value)
				end,
			},
		}
		local catalog = Catalog.new({ { id = "stone", stackMax = 1, weightMilli = 1 } })
		local function item(id: string): Inventory.Item
			return {
				itemId = id,
				catalogId = "stone",
				quantity = 1,
				qualityMilli = 1000,
				durabilityMilli = 0,
				attributes = {},
			}
		end
		local bag = Inventory.new(
			"bag",
			{ kind = "bag", contentVersion = 2, slots = 30, softWeightMilli = 100, hardWeightMilli = 100 }
		)
		bag = assert(Inventory.add(bag, catalog, item("owned"), bag.version))
		local personal = Personal.new(backend, {
			namespace = "p",
			store = options,
			inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" },
			validateEnvelope = function()
				return true
			end,
		})
		local token = assert(personal:load("owner", function()
			return { genres = { ["survival-coop"] = { data = { inventory = { bag = Inventory.save(bag) } } } } }
		end))
		local home = Home.new("owner", { baseSlots = 1, dock = {} }, 1)
		local stored = assert(Inventory.add(Inventory.fromSave(home.storage, catalog), catalog, item("stored"), 0))
		home.storage = Inventory.save(stored)
		local store = Fenced.new(backend, options)
		local held = assert(store:acquire("home:owner", function()
			return { home = home }
		end))
		local api = Transfer.new({
			catalog = catalog,
			now = options.now,
			personal = function()
				return {
					personal = personal,
					profile = function()
						return token
					end,
					install = function(value)
						token = value
					end,
				}
			end,
			open = function()
				held = assert(store:refresh(held))
				return held
			end,
			update = function(_actor, transform)
				local value, err = store:update(held, transform)
				if value then
					held = value
				end
				return value, err
			end,
		})
		local function command(deposit, id, requestId)
			return api.command("owner", deposit, id, 1, { sessionEpoch = 1, requestId = requestId }, function()
				return { ok = true }
			end)
		end
		assert(command(true, "owned", "full").reason == "FULL_SLOTS", "full home refuses")
		assert(
			token.data.envelope.genres["survival-coop"].data.inventory.bag.items.owned
				and held.data.home.storage.items.stored,
			"full home keeps both inventories"
		)
		held = assert(store:update(held, function(data)
			data.home.storageSlots = 0
			return data
		end))
		assert(command(true, "owned", "expired").reason == "HOME_OVERFLOW_WITHDRAW_ONLY", "overflow blocks deposit")
		assert(command(false, "stored", "withdraw").ok, "overflow permits withdrawal")
		assert(command(false, "stored", "withdraw").ok, "withdraw replay succeeds")
		assert(
			held.data.home.storage.items.stored == nil
				and token.data.envelope.genres["survival-coop"].data.inventory.bag.items.stored,
			"withdraw conserves exact identity"
		)
		assert(command(true, "owned", "withdraw").reason == "REQUEST_CONFLICT", "changed replay binding refused")
	end,
}
