--!strict
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local Volcano = require("../../../../core/domain/survival/Volcano")
local Materials = require("../../../../core/domain/crafting/MaterialGrowth")
local Tree = require("../../../../core/domain/progression/SkillTree")
local Late = require("../../../../core/domain/survival/LateEquipment")
local Runtime = require("../../../../genres/survival-coop/module/LateEquipmentRuntime")
local Progression = require("../../../../genres/survival-coop/module/ProgressionExtension")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Catalog = require("../../../../core/domain/inventory/ItemCatalog")
local Data = require("../../../../core/domain/genre/SerializedData")
local Ledger = require("../../../../core/domain/command/Ledger")
local M = {}
local Policy = assert(Content.progressionPolicy, "missing progression policy")

local function row(rows: any, id: string): any
	for _, value in rows do
		if value.id == id then
			return value
		end
	end
	error("missing catalog row " .. id)
end

local function volcano(): any
	local policy = assert(Policy.volcano, "missing volcanic policy")
	local layout = row(Content.layouts, "rw.a5.s1")
	local vitals = { health = 100, maxHealth = 100, fatigue = 50 }
	local exposed = { exposed = true, spring = false, lava = false }
	local bare = Volcano.advance(vitals, 0, 10, 0, exposed, false, policy, 1)
	local protected = Volcano.advance(vitals, 0, 10, 0, exposed, true, policy, 1)
	local storm = Volcano.advance(vitals, 300, 310, 0, exposed, false, policy, 1)
	assert(bare.health == 90 and bare.fatigue == 70, "bare exposure")
	assert(protected.health == 95 and protected.fatigue == 60, "protected exposure")
	assert(storm.health == 80 and storm.fatigue == 90, "storm exposure")
	local springZone = Volcano.zone(layout, { x = -48, y = 18, z = 140 })
	local spring = Volcano.advance(vitals, 300, 310, 0, springZone, false, policy, 1)
	assert(spring.health == 100 and spring.fatigue == 0, "spring recovery")
	local arena = Volcano.zone(layout, { x = -280, y = 18, z = 0 })
	assert(not arena.exposed and not arena.lava, "first rex arena protection")
	local lava = Volcano.zone(layout, { x = 240, y = 18, z = 0 })
	local burned = Volcano.advance(vitals, 0, 1, 0, lava, true, policy, 1)
	assert(burned.health <= 75, "boots must not protect standing lava")
	local one = Volcano.advance(vitals, 295, 305, 0, exposed, true, policy, 1)
	local split = Volcano.advance(
		Volcano.advance(vitals, 295, 300, 0, exposed, true, policy, 1),
		300,
		305,
		0,
		exposed,
		true,
		policy,
		1
	)
	assert(one.health == split.health and one.fatigue == split.fatigue, "heartbeat partition")
	assert(
		not Volcano.storm(299, 0, policy) and Volcano.storm(300, 0, policy) and not Volcano.storm(420, 0, policy),
		"weather boundaries"
	)
	local tree = Tree.level(Tree.new(Content, Policy.tree), Policy.tree, 60)
	-- Test setup buys actual nodes with earned proficiency rather than bypassing gates.
	for _, category in { "processing", "tailoring" } do
		for i = 1, 8100 do
			tree = Tree.award(tree, Policy.tree, category, category .. tostring(i))
		end
		for rank = 1, if category == "processing" then 4 else 5 do
			tree = assert(Tree.learn(Content, tree, category .. "_" .. tostring(rank)))
		end
	end
	local hide = Materials.raw(Content, "hide", 60, 0, "tyrannosaurus")
	local leather = assert(Progression.craft(Content, tree, "tan-rex-hide", { hide }))
	assert(leather.sourceSpeciesId == "tyrannosaurus", "processing provenance")
	local fake = Materials.copy(hide)
	fake.sourceSpeciesId = nil
	local denied, reason = Progression.craft(Content, tree, "tan-rex-hide", { fake })
	assert(not denied and reason == "SOURCE_SPECIES_GATE", "generic hide refused")
	leather.quantity = 4
	local ore = Materials.raw(Content, "volcanic-ore", 60, 0, nil)
	local charcoal = Materials.raw(Content, "charcoal", 60, 0, nil)
	local alloy = assert(Progression.craft(Content, tree, "smelt-volcanic-alloy", { ore, charcoal }))
	alloy.quantity = 3
	local bone = Materials.raw(Content, "volcanic-bone", 60, 0, "tyrannosaurus")
	bone.quantity = 2
	local thick = Materials.copy(leather)
	thick.item, thick.quantity = "thick-leather", 2
	local boots = assert(Progression.craft(Content, tree, policy.bootsItem, { leather, alloy, bone, thick }))
	assert(boots.item == policy.bootsItem and boots.level == 60, "volcanic boots output")
	return { bare = bare, protected = protected, storm = storm, spring = spring, boots = boots.item }
end

local function equipment(): any
	local policy = Policy
	local tree = Tree.new(Content, policy.tree)
	-- Train exactly to the tailoring_4 proficiency (30); a fixed award count would overshoot
	-- the character level under the spec curve (owner decision 2026-10-23).
	local i = 0
	while tree.mastery.tailoring.level < 30 do
		i += 1
		tree = Tree.award(tree, policy.tree, "tailoring", "tailoring" .. tostring(i))
	end
	assert(tree.level < 59, "mastery training stays below the support character gate")
	tree = Tree.level(tree, policy.tree, 59)
	for rank = 1, 4 do
		tree = assert(Tree.learn(Content, tree, "tailoring_" .. tostring(rank)))
	end
	local definitions: { Catalog.Definition } = {}
	for _, item in Content.items do
		table.insert(definitions, {
			id = item.id,
			stackMax = item.stackMax,
			weightMilli = item.weightMilli,
			maxDurabilityMilli = item.maxDurabilityMilli,
		})
	end
	local catalog = Catalog.new(definitions)
	local bag =
		Inventory.new("bag", { contentVersion = 2, slots = 30, softWeightMilli = 60000, hardWeightMilli = 90000 })
	for _, item in { "iron", "dried-wood", "polished-bone", "fur-leather", "thick-leather" } do
		bag = assert(Inventory.add(bag, catalog, {
			itemId = item,
			catalogId = item,
			quantity = if item == "iron" then 35 elseif item == "dried-wood" or item == "polished-bone" then 35 else 2,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = {},
		}, bag.version))
	end
	local material = Materials.raw(Content, "hide", 60, 0, "tyrannosaurus")
	bag = assert(Inventory.add(bag, catalog, {
		itemId = "iron-extra",
		catalogId = "iron",
		quantity = 37,
		qualityMilli = 1000,
		durabilityMilli = 0,
		attributes = {},
	}, bag.version))
	material.item = "temperate-top"
	local aggregate: any = {
		coins = 30000,
		bag = Inventory.save(bag),
		tree = tree,
		equipment = { coat = { tags = { "clothing" }, base = 5, material = material } },
	}
	local facts = { developmentRank = 3, station = "signal-relay", stationTier = 3, reachable = true }
	local no, reason =
		Runtime.apply(Content, aggregate, "start", { id = "support-tier-1", target = "coat" }, "59", 0, facts)
	assert(not no and reason == "CHARACTER_LEVEL_GATE", tostring(reason))
	aggregate.tree = Tree.level(tree, policy.tree, 60)
	for tier = 1, 3 do
		local id, receipt = "support-tier-" .. tostring(tier), "support" .. tostring(tier)
		aggregate = assert(Runtime.apply(Content, aggregate, "start", { id = id, target = "coat" }, receipt, 0, facts))
		local before = Data.clone(aggregate)
		local duplicate, duplicateReason =
			Runtime.apply(Content, aggregate, "start", { id = id, target = "coat" }, receipt, 0, facts)
		assert(not duplicate and duplicateReason == "DUPLICATE_RECEIPT", "receipt deduplication")
		assert(aggregate.coins == before.coins, "duplicate consumed coins")
		assert(Ledger.canonical(aggregate) == Ledger.canonical(before), "duplicate mutated aggregate")
		aggregate = assert(
			Runtime.apply(
				Content,
				aggregate,
				"complete",
				{ jobId = receipt },
				receipt .. "done",
				Late.operation(Content, id).seconds,
				facts
			)
		)
	end
	assert(aggregate.equipment.coat.support == "support-tier-3", "support progression")
	facts.station, facts.stationTier = "workbench", 2
	local beforeInvalid = Ledger.canonical(aggregate)
	local invalid, invalidReason = Runtime.apply(
		Content,
		aggregate,
		"start",
		{ id = "modify-hardness", target = "coat", slot = 3 },
		"wrongslot",
		0,
		facts
	)
	assert(not invalid and invalidReason == "INVALID_MODIFICATION_SLOT", "wrong slot refusal")
	assert(Ledger.canonical(aggregate) == beforeInvalid, "wrong slot consumed materials")
	for slot, id in { "modify-hardness", "modify-insulation" } do
		local receipt = "modify" .. tostring(slot)
		aggregate = assert(
			Runtime.apply(Content, aggregate, "start", { id = id, target = "coat", slot = slot }, receipt, 0, facts)
		)
		aggregate = assert(
			Runtime.apply(
				Content,
				aggregate,
				"complete",
				{ jobId = receipt },
				receipt .. "done",
				Late.operation(Content, id).seconds,
				facts
			)
		)
	end
	assert(
		aggregate.equipment.coat.modifications["1"][1].value == 2
			and aggregate.equipment.coat.modifications["2"][1].value == 2,
		"two modification slots"
	)
	facts.station = "laboratory"
	for _, line in { "life", "light", "heavy" } do
		for tier = 1, 3 do
			local id = "research-" .. line .. "-" .. tostring(tier)
			aggregate = assert(Runtime.apply(Content, aggregate, "start", { id = id }, id, 0, facts))
			aggregate = assert(
				Runtime.apply(
					Content,
					aggregate,
					"complete",
					{ jobId = id },
					id .. "done",
					Late.operation(Content, id).seconds,
					facts
				)
			)
		end
	end
	local effects = Late.effects(Content, aggregate.lateEquipment)
	assert(
		math.abs(Progression.staminaExpenditure(Content, aggregate.lateEquipment, 100, true) - 85.54) < 0.00001,
		"research stamina effects"
	)
	assert(
		effects["life-reduction"] == -6 and effects["light-reduction"] == -6 and effects["heavy-reduction"] == -9,
		"research tiers replace"
	)
	local empty = Data.clone(aggregate)
	empty.bag = Inventory.save(
		Inventory.new("bag", { contentVersion = 2, slots = 30, softWeightMilli = 60000, hardWeightMilli = 90000 })
	)
	facts.station = "workbench"
	local beforeMissing = Ledger.canonical(empty)
	local missing, missingReason = Runtime.apply(
		Content,
		empty,
		"start",
		{ id = "modify-hardness", target = "coat", slot = 1 },
		"missing",
		0,
		facts
	)
	assert(not missing and missingReason == "INSUFFICIENT_MATERIALS", "material refusal")
	assert(Ledger.canonical(empty) == beforeMissing, "insufficient materials mutated aggregate")
	local stats = Progression.equipment(Content, aggregate.equipment.coat, policy)
	assert(stats.armor > 5 and stats.cold > policy.clothing[material.item].cold, "equipment consumers")
	return {
		level59Refused = true,
		supportTier = 3,
		slots = 2,
		lifeReduction = effects["life-reduction"],
		coins = aggregate.coins,
	}
end

M.operations = {
	volcano_progression = function(ctx: any, step: any): string?
		local data = volcano()
		ctx.fixture.state = data
		ctx.results[ctx.playerOf(step)] = { ok = true, data = data }
		return nil
	end,
	equipment_support = function(ctx: any, step: any): string?
		local data = equipment()
		ctx.fixture.state = data
		ctx.results[ctx.playerOf(step)] = { ok = true, data = data }
		return nil
	end,
}

function M.new(_ctx: any): any
	local fixture: any = { state = {} }
	fixture.snapshot = function(): any
		return Data.clone(fixture.state)
	end
	return fixture
end

return M
