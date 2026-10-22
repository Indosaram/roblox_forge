--!strict
local Character = require("../../genres/survival-coop/module/CharacterExtension")
local Ports = require("../../genres/survival-coop/module/ProgressionPorts")
local LateExtension = require("../../genres/survival-coop/module/LateEquipmentExtension")
local Extensions = require("../../genres/survival-coop/module/Extensions")
local Contract = require("../../genres/survival-coop/module/Contract")
local Inventory = require("../../core/domain/inventory/Inventory")
local Catalog = require("../../core/domain/inventory/ItemCatalog")
local Tree = require("../../core/domain/progression/SkillTree")
local Content: any = require("./src/shared/SurvivalContent")
local Durable: any = require("./src/shared/GenreDurable")

local function item(id: string, catalogId: string, quantity: number?): any
	-- Stackable materials carry no durability; gear starts at full durability.
	return {
		itemId = id,
		catalogId = catalogId,
		quantity = quantity or 1,
		qualityMilli = 1000,
		durabilityMilli = if quantity then 0 elseif catalogId == "wood" then 0 else 100000,
		attributes = {},
	}
end

local function harness(level: number, items: { any }): any
	local policy = Content.progressionPolicy.tree
	local catalog = Catalog.new(Content.items)
	local state =
		Inventory.new("bag", { contentVersion = 2, slots = 30, softWeightMilli = 60000, hardWeightMilli = 90000 })
	for _, entry in items do
		state = assert(Inventory.add(state, catalog, entry, state.version))
	end
	local bag = Inventory.save(state)
	local slice: any = {
		balance = 1000,
		inventory = { bag = bag },
		progression = Tree.level(Tree.new(Content, policy), policy, level),
	}
	local token: any =
		{ data = { stateRevision = 0, envelope = { genres = { ["survival-coop"] = { data = slice } } } } }
	local h: any = { commits = 0 }
	local personal = {
		update = function(_self: any, profile: any, transform: any)
			local nextView = transform(profile.data)
			if nextView ~= profile.data then
				h.commits += 1
			end
			token = { data = nextView }
			return token, nil
		end,
		commit = function(_self: any, _profile: any, revision: number, envelope: any)
			h.commits += 1
			token = { data = { stateRevision = revision + 1, envelope = envelope } }
			return token, nil
		end,
	}
	local port = {
		personal = personal,
		profile = function()
			return token
		end,
		install = function() end,
	}
	local world: any = {
		services = {
			survivalSpatial = {
				station = function(_actor: string, key: string)
					return if key == h.station
						then { kind = string.match(key, "^station%.(.+)%.t%d$"), reachable = true }
						else nil
				end,
			},
		},
	}
	local store = {
		snapshot = function()
			return { development = { points = h.points or 0, definitions = { ["rw.m1.gather"] = true } } }
		end,
	}
	local clock = 0
	Ports.bind(world, Content, store, function()
		return clock
	end)
	local latePorts: any = require("./src/server/LateEquipmentPorts")
	latePorts.bind(world)
	local ctx = {
		content = Content,
		world = world,
		personalTransfer = function()
			return port
		end,
		now = function()
			return clock
		end,
	}
	h.character = assert(Character.factory(ctx))
	h.late = assert(LateExtension.factory(ctx))
	h.slice = function()
		return token.data.envelope.genres["survival-coop"].data
	end
	h.tick = function(seconds: number)
		clock += seconds
	end
	local admit = function()
		return { ok = true }
	end
	h.run = function(action: string, args: any, request: string?): any
		local extension = if string.find(action, "gear%-") then h.character else h.late
		return extension.command(
			"1",
			action,
			args,
			{ sessionEpoch = 1, requestId = request or action },
			"client",
			admit
		)
	end
	return h
end

return {
	["gear-equip persists the slot and gear-unequip clears it; snapshot reflects both"] = function()
		local h = harness(5, { item("a", "axe-t1"), item("c", "cold-top") })
		assert(h.run(Character.EQUIP, { "a" }).ok, "equip axe")
		assert(h.run(Character.EQUIP, { "c" }).ok, "equip top")
		assert(h.slice().gear.equipped.weapon == "a" and h.slice().gear.equipped.top == "c", "persisted")
		local view = h.character.snapshot("1")
		assert(view.gear.equipped.weapon == "a" and view.points == 0 and view.definitions["rw.m1.gather"], "snapshot")
		assert(h.run(Character.UNEQUIP, { "weapon" }).ok and h.slice().gear.equipped.weapon == nil, "unequip")
	end,
	["refusals are typed and commit nothing"] = function()
		local h = harness(5, { item("w", "wood") })
		local before = h.commits
		assert(h.run(Character.EQUIP, { "w" }).reason == "NOT_EQUIPMENT", "material refused")
		assert(h.run(Character.EQUIP, { "zz" }).reason == "ITEM_NOT_OWNED", "missing refused")
		assert(h.run(Character.UNEQUIP, { "head" }).reason == "SLOT_EMPTY", "empty slot refused")
		assert(h.run(Character.EQUIP, { "" }).reason == "INVALID_ARGUMENT", "empty arg")
		assert(h.commits == before and h.slice().gear == nil, "no write")
	end,
	["bound owner makes research runnable: rank and station gates, start, cancel refund"] = function()
		local h = harness(30, { item("d", "dried-wood", 20) })
		h.points = 250
		assert(
			h.run("survival-coop:equipment-start", { "research-life-1", "research", 1 } :: { any }, "r0").reason
				== "DEVELOPMENT_GATE",
			"rank 2 refused"
		)
		h.points = 300
		local away = h.run("survival-coop:equipment-start", { "research-life-1", "research", 1 } :: { any }, "r1")
		assert(away.reason == "STATION_GATE", "away from lab: " .. tostring(away.reason))
		h.station = "station.laboratory.t1"
		local started = h.run("survival-coop:equipment-start", { "research-life-1", "research", 1 } :: { any }, "r2")
		assert(started.ok, tostring(started.reason))
		assert(h.slice().balance == 900 and h.slice().inventory.bag.items.d.quantity == 15, "coins and wood debited")
		local cancelled = h.run("survival-coop:equipment-cancel", { started.data.jobId }, "r3")
		assert(cancelled.ok and h.slice().balance == 950, "half the coin cost refunded")
	end,
	["technical support refuses below level 60 and upgrades the equipped item at 60"] = function()
		local h = harness(59, { item("a", "axe-t1"), item("i", "iron", 40) })
		assert(h.run(Character.EQUIP, { "a" }).ok, "equip")
		h.station = "station.signal-relay.t1"
		assert(
			h.run("survival-coop:equipment-start", { "support-tier-1", "a", 1 } :: { any }, "s0").reason
				== "CHARACTER_LEVEL_GATE",
			"level 59"
		)
		local slice = h.slice()
		slice.progression = Tree.level(slice.progression, Content.progressionPolicy.tree, 60)
		local started = h.run("survival-coop:equipment-start", { "support-tier-1", "a", 1 } :: { any }, "s1")
		assert(started.ok, tostring(started.reason))
		h.tick(30)
		assert(h.run("survival-coop:equipment-complete", { started.data.jobId }, "s2").ok, "complete")
		assert(h.slice().gear.equipment.a.support == "support-tier-1", "support recorded on the worn record")
		assert(h.character.snapshot("1").gear.equipment.a.completed["support-tier-1"], "snapshot shows tier")
	end,
	["actions are declared, durable and served by a registered factory"] = function()
		for _, id in { "gear-equip", "gear-unequip" } do
			assert(table.find(Contract.extensionActions :: { string }, id), "extension action " .. id)
			assert(table.find(Durable.actions, "survival-coop:" .. id), "durable " .. id)
		end
		assert(table.find(Extensions.factories, Character.factory), "factory registered")
	end,
}
