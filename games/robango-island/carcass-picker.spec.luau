--!strict
-- C3 (G12) carcass picker: after a kill the killer takes the content dropReservoirs outputs (meat,
-- hide, bone ...) from the body one at a time through carcass-take. Server-authoritative: the
-- wildlife state (dead, killer, killedAt) and the body distance come from server ports, never args.
local Carcass = require("../../genres/survival-coop/module/CarcassExtension")
local Contract = require("../../genres/survival-coop/module/Contract")
local Extensions = require("../../genres/survival-coop/module/Extensions")
local CraftingAdapter = require("../../genres/survival-coop/module/CraftingAdapter")
local Inventory = require("../../core/domain/inventory/Inventory")
local Catalog = require("../../core/domain/inventory/ItemCatalog")
local Tree = require("../../core/domain/progression/SkillTree")
local Content: any = require("./src/shared/SurvivalContent")
local Durable: any = require("./src/shared/GenreDurable")
local Policy: any = require("./src/shared/WildlifePolicy")

local SPECIES = "oviraptor"

local function harness(): any
	local h: any = { now = 1000, distance = 3, wild = nil :: any }
	local state =
		Inventory.new("bag", { contentVersion = 2, slots = 30, softWeightMilli = 60000, hardWeightMilli = 90000 })
	local slice: any =
		{ inventory = { bag = Inventory.save(state) }, progression = Tree.new(Content, Content.progressionPolicy.tree) }
	local token: any = { data = { envelope = { genres = { ["survival-coop"] = { data = slice } } } } }
	local port = {
		personal = {
			update = function(_self: any, profile: any, transform: any)
				token = { data = transform(profile.data) }
				return token, nil
			end,
		},
		profile = function()
			return token
		end,
		install = function() end,
	}
	h.extension = assert(
		Carcass.factory({
			content = Content,
			now = function()
				return h.now
			end,
			personalTransfer = function()
				return port
			end,
			wildlife = function(id: string)
				return if id == "ovi-1" then h.wild else nil
			end,
			world = {
				wildlifeAccess = function(_actor: string, id: string)
					if id ~= "ovi-1" or h.distance == nil then
						return nil
					end
					return { position = { x = 0, y = 0, z = 0 }, targetPosition = { x = h.distance, y = 0, z = 0 } }
				end,
			},
		}),
		"carcass factory builds for content with reservoirs"
	)
	h.slice = function()
		return token.data.envelope.genres["survival-coop"].data
	end
	h.held = function(catalogId: string): number
		local total = 0
		for _, item in h.slice().inventory.bag.items do
			total += if item.catalogId == catalogId then item.quantity else 0
		end
		return total
	end
	h.take = function(item: string, request: string?, actor: string?): any
		return h.extension.command(
			actor or "1",
			Carcass.ACTION,
			{ "ovi-1", item },
			{ actorId = actor or "1", sessionEpoch = 1, requestId = request or item },
			"client",
			function()
				return { ok = true }
			end
		)
	end
	h.kill = function(killer: string?)
		h.wild = { catalogId = SPECIES, healthMilli = 0, killer = killer or "1", killedAt = h.now }
	end
	return h
end

local function reservoirs(): { any }
	for _, species in Content.wildlifeDetails do
		if species.id == SPECIES then
			return species.dropReservoirs
		end
	end
	error("species " .. SPECIES)
end

return {
	["outputs mirror the species content dropReservoirs"] = function()
		local outputs = Carcass.outputs(Content, SPECIES)
		local source = reservoirs()
		assert(#outputs == #source and #outputs >= 2, "every reservoir offered: " .. #outputs)
		for index, row in source do
			assert(outputs[index].item == row.item and outputs[index].quantity == row.quantity, "row " .. index)
		end
		assert(#Carcass.outputs(Content, "not-a-species") == 0, "unknown species offers nothing")
	end,

	["the killer takes each offered output once and earns butchering"] = function()
		local h = harness()
		h.kill()
		local before = h.slice().progression.mastery.butchering
		local first = reservoirs()[1]
		local taken = h.take(first.item)
		assert(taken.ok and taken.data.quantity == first.quantity, "take: " .. tostring(taken.reason))
		assert(h.held(first.item) == first.quantity, "granted into the bag")
		local after = h.slice().progression.mastery.butchering
		assert(
			(after and after.xp or 0) > (before and before.xp or 0)
				or (after and after.level or 0) > (before and before.level or 0),
			"butchering awarded"
		)
		local again = h.take(first.item, "again")
		assert(
			not again.ok and again.reason == "ALREADY_TAKEN" and h.held(first.item) == first.quantity,
			"once per corpse"
		)
		local second = reservoirs()[2]
		assert(h.take(second.item).ok and h.held(second.item) == second.quantity, "another output still open")
	end,

	["NEGATIVE: an output the carcass does not offer is refused"] = function()
		local h = harness()
		h.kill()
		local offered: { [string]: boolean } = {}
		for _, row in reservoirs() do
			offered[row.item] = true
		end
		assert(not offered["wood"], "fixture: wood is not an oviraptor output")
		local forged = h.take("wood")
		assert(not forged.ok and forged.reason == "NOT_OFFERED", "forged output: " .. tostring(forged.reason))
		assert(h.held("wood") == 0 and h.slice().carcass == nil, "nothing granted, nothing recorded")
	end,

	["NEGATIVE: a living, foreign, far or expired body is refused"] = function()
		local h = harness()
		local item = reservoirs()[1].item
		assert(h.take(item).reason == "UNKNOWN_TARGET", "no body")
		h.wild = { catalogId = SPECIES, healthMilli = 5000, killer = nil, killedAt = nil }
		assert(h.take(item).reason == "NOT_DEAD", "alive target refused")
		h.kill("2")
		assert(h.take(item).reason == "NOT_YOURS", "another player's kill refused")
		h.kill("1")
		h.distance = Carcass.REACH_STUDS + 1
		assert(h.take(item).reason == "OUT_OF_RANGE", "out of reach refused")
		h.distance = nil
		assert(h.take(item).reason == "OUT_OF_RANGE", "unreachable body refused")
		h.distance = 2
		h.now += Carcass.LIFETIME_SECONDS
		assert(h.take(item).reason == "CORPSE_EXPIRED", "expired corpse refused")
		assert(h.held(item) == 0, "no refusal granted anything")
	end,

	["a respawned creature is a new corpse; records stay bounded"] = function()
		local records: any = nil
		local outputs = { { item = "meat", quantity = 1 } }
		local wild = { catalogId = SPECIES, healthMilli = 0, killer = "1", killedAt = 10 }
		records = assert(Carcass.take(records, "1", "w", wild, outputs, "meat", 1, 10))
		local _, _, again = Carcass.take(records, "1", "w", wild, outputs, "meat", 1, 11)
		assert(again == "ALREADY_TAKEN", "same corpse")
		local reborn = { catalogId = SPECIES, healthMilli = 0, killer = "1", killedAt = 50 }
		local fresh, quantity = Carcass.take(records, "1", "w", reborn, outputs, "meat", 1, 50)
		assert(fresh and quantity == 1, "a later kill of the same id is a fresh corpse")
		for index = 1, Carcass.MAX_RECORDS + 5 do
			local other = { catalogId = SPECIES, healthMilli = 0, killer = "1", killedAt = 100 + index }
			fresh = assert(Carcass.take(fresh, "1", "w" .. index, other, outputs, "meat", 1, 100 + index))
		end
		local count = 0
		for _ in (fresh :: any).corpses do
			count += 1
		end
		assert(count == Carcass.MAX_RECORDS and Carcass.valid(fresh), "bounded and valid: " .. count)
	end,

	["save validation accepts carcass records and NEGATIVE rejects a malformed one"] = function()
		local good = { saveVersion = 3, carcass = { version = 1, corpses = {} } }
		for _, problem in CraftingAdapter.validateSave(good :: any) do
			assert(not string.find(problem, "carcass", 1, true), "valid carcass rejected: " .. problem)
		end
		local bad = { saveVersion = 3, carcass = { version = 1, corpses = { w = { taken = 3 } } } }
		local flagged = false
		for _, problem in CraftingAdapter.validateSave(bad :: any) do
			flagged = flagged or string.find(problem, "carcass", 1, true) ~= nil
		end
		assert(flagged, "malformed carcass records must fail save validation")
	end,

	["carcass-take is a durable client action; the factory is opt-in per pack"] = function()
		local declared = false
		for _, action in Contract.actions do
			declared = declared or (action.id == "carcass-take" and action.origin == "client")
		end
		assert(declared, "contract declares carcass-take")
		assert(table.find(Durable.actions, Carcass.ACTION), "robango durable policy publishes carcass-take")
		assert(not table.find(Extensions.factories, Carcass.factory), "not in the genre default registry")
		assert(
			Carcass.factory({ content = { wildlifeDetails = {} }, wildlife = function() end }) == nil,
			"no reservoirs, no picker"
		)
	end,

	["robango kills drop no reservoir outputs automatically"] = function()
		for _, species in Content.wildlifeDetails do
			local rule = Policy.catalog.species[species.id]
			assert(rule and #rule.drops == 0, species.id .. " keeps an automatic drop")
		end
		-- Catalog ids still resolve (meat from the legacy hunter rule is not a content species).
		assert(Catalog.new(Content.items)["meat"], "meat is a catalog item")
	end,
}
