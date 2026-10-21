--!strict
local Inventory = require("../inventory/Inventory")
local ItemCatalog = require("../inventory/ItemCatalog")
local Settlement = require("../settlement/Settlement")
local Content = require("./Content")
local Wildlife = require("../../../genres/survival-coop/module/Wildlife")
local Mounts = require("../../../genres/survival-coop/module/Mounts")

local function inventory(slots: number, version: number?, kind: string?): Inventory.State
	return Inventory.new(
		"bag",
		{ slots = slots, contentVersion = version, kind = kind, softWeightMilli = 60000, hardWeightMilli = 90000 }
	)
end
local function settlement(members: number, version: number?): Settlement.State
	return Settlement.new(
		{ tribeId = "camp", width = 16, depth = 12, cellStuds = 4, maxMembers = members, contentVersion = version },
		"owner"
	)
end
local function content(version: number): Content.Document
	local result, errors = Content.canonicalize({
		survival_content = version,
		rules = Content.RULES,
		limits = Content.DEFAULT_LIMITS,
		items = { { id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 } },
		wildlife = {
			{
				id = "deer",
				behavior = "grazer",
				mount = if version == 2
					then { enabled = true, cargoSlots = 8, walkSpeed = 5, runSpeed = 25, stamina = 100 }
					else nil,
			},
			{
				id = "dodo",
				behavior = "grazer",
				mount = if version == 2
					then { enabled = false, cargoSlots = 0, walkSpeed = 3, runSpeed = 8, stamina = 100 }
					else nil,
			},
		},
	})
	assert(result, table.concat(errors, "; "))
	return result
end
local function wildlife(health: number, version: number): Wildlife.Catalog
	return Wildlife.catalog(content(version), {
		species = {
			deer = { healthMilli = health, damageMilli = 0, drops = {} },
			dodo = { healthMilli = 1, damageMilli = 0, drops = {} },
		},
		weapons = {},
	})
end
return {
	["Inventory capacity opt-in boundaries and persisted policy"] = function()
		assert(inventory(20).limits.slots == 20, "default v1 boundary")
		assert(not pcall(inventory, 21), "default rejects 21")
		assert(not pcall(inventory, 21, 1), "explicit v1 rejects 21")
		local bag = inventory(30, 2)
		assert(bag.limits.slots == 30 and not pcall(inventory, 31, 2), "v2 bag boundary")
		assert(inventory(45, 2, "home").limits.slots == 45 and not pcall(inventory, 46, 2, "home"), "v2 home boundary")
		assert(not pcall(inventory, 21, 1, "home"), "v1 home boundary")
		local catalog = ItemCatalog.new({})
		assert(Inventory.fromSave(Inventory.save(bag), catalog).limits.contentVersion == 2, "persist opt-in")
		local forged = Inventory.save(bag)
		forged.limits.contentVersion = nil
		assert(not pcall(Inventory.fromSave, forged, catalog), "missing policy refused")
		assert(not pcall(inventory, 30, 3), "future version refused")
	end,
	["Settlement capacity opt-in boundaries and persisted policy"] = function()
		assert(settlement(4).config.maxMembers == 4 and not pcall(settlement, 5), "default clan boundary")
		assert(not pcall(settlement, 5, 1), "v1 rejects 5")
		local camp = settlement(50, 2)
		assert(camp.config.maxMembers == 50 and not pcall(settlement, 51, 2), "v2 clan boundary")
		assert(Settlement.fromSave(Settlement.save(camp), camp.config, {}).config.maxMembers == 50, "restore v2 clan")
		assert(not pcall(settlement, 50, 3), "future clan version refused")
	end,
	["Wildlife health capacity opt-in boundaries"] = function()
		assert(wildlife(1000000, 1).species.deer.healthMilli == 1000000, "v1 health boundary")
		assert(not pcall(wildlife, 1000001, 1), "v1 rejects over-cap health")
		assert(wildlife(2600000, 2).species.deer.healthMilli == 2600000, "tyrannosaurus accepted")
		assert(wildlife(3000000, 2).species.deer.healthMilli == 3000000, "v2 health boundary")
		assert(not pcall(wildlife, 3000001, 2), "v2 rejects over-cap health")
	end,
	["Mounts v2 explicit policy survives runtime projection"] = function()
		local doc = content(2)
		local projected = assert(Content.canonicalize(Content.projectV1(doc)))
		local rules: Mounts.Rules = {
			pvpSpeedCapStuds = 24,
			species = {
				deer = { rideable = true, rideSpeedStuds = 25, carryMilli = 0 },
				dodo = { rideable = false, rideSpeedStuds = 0, carryMilli = 0 },
			},
		}
		local catalog = Mounts.catalog(projected, rules)
		assert(Mounts.isRideable(catalog, "deer") and not Mounts.isRideable(catalog, "dodo"), "authored rideability")
		assert(not pcall(Mounts.catalog, content(1), rules), "v1 legacy archetype rule")
		rules.species.dodo = { rideable = true, rideSpeedStuds = 8, carryMilli = 0 }
		assert(not pcall(Mounts.catalog, projected, rules), "non-mount cannot be enabled")
		rules.species.dodo = { rideable = false, rideSpeedStuds = 0, carryMilli = 0 }
		rules.species.deer.rideSpeedStuds = 26
		assert(not pcall(Mounts.catalog, projected, rules), "mount speed cannot differ")
	end,
}
