--!strict
-- Specs for CraftingAdapter analytics: committed craft completions and deaths
-- emit typed core analytics events exactly once, after the stage applies.
local CraftingAdapter = require("./CraftingAdapter")
local Content = require("../../../core/domain/survival/Content")
local Events = require("../../../core/infra/analytics/Events")
local Shared = require("../../../core/domain/genre/Contract")

type Seen = { { name: string, fields: { [string]: any } } }

local function config(): any
	local content = {
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		items = {
			{ id = "fiber", name = "Fiber", stackMax = 100, weightMilli = 100 },
			{ id = "cord", name = "Cord", stackMax = 100, weightMilli = 100 },
		},
		recipes = {
			{
				id = "cord",
				craftMillis = 1000,
				inputs = { { item = "fiber", quantity = 3 } },
				outputs = { { item = "cord", quantity = 1 } },
			},
		},
		vitals = {},
	}
	assert(Content.canonicalize(content), "fixture content is valid")
	return {
		mode = "crafting",
		currency = "Coins",
		startingBalance = 0,
		contentVersion = 1,
		inventory = {
			content = content,
			carriedContainer = "bag",
			speedPenaltyMilli = 0,
			containers = {
				bag = {
					{
						itemId = "fiber",
						catalogId = "fiber",
						quantity = 30,
						qualityMilli = 1000,
						durabilityMilli = 0,
						attributes = {},
					},
				},
			},
		},
	}
end

local function setup(death: boolean?): (Shared.Instance, Seen)
	local seen: Seen = {}
	local emitter = Events.new(function(name: string, fields: { [string]: any })
		table.insert(seen, { name = name, fields = fields })
	end)
	local services: Shared.Services = {
		now = function()
			return 0
		end,
		roll = function()
			return 0
		end,
		emit = function(_) end,
		survivalDeath = if death
			then {
				worldRevision = "world-1",
				equipment = function()
					return {}
				end,
				position = function()
					return { x = 1, y = 0, z = 2 }
				end,
				reachable = function()
					return true
				end,
			}
			else nil,
	}
	local cfg = config()
	cfg.survivalDeath = death
	local instance = CraftingAdapter.new(cfg, services, nil, emitter)
	assert(instance.join("alice", nil).ok, "join")
	return instance, seen
end

local function context(requestId: string, nowMillis: number): Shared.CommandContext
	return { actorId = "alice", requestId = requestId, sessionEpoch = 0, nowMillis = nowMillis } :: any
end

local function run(instance: Shared.Instance, action: string, args: { any }, ctx: Shared.CommandContext): Shared.Result
	local stage = assert((instance :: any).stageCommand("alice", action, args, ctx))
	stage.apply()
	return stage.result
end

return {
	["v2 join migrates a persisted twenty slot bag without changing its items"] = function()
		local legacy = setup()
		local saved: any = legacy.save("alice")
		saved.inventory.bag.limits.slots = 20
		local cfg = config()
		cfg.contentVersion = 2
		cfg.inventory.content.survival_content = 2
		cfg.inventory.content.limits.slots = 30
		local instance = CraftingAdapter.new(cfg, {
			now = function()
				return 0
			end,
			roll = function()
				return 0
			end,
			emit = function(_) end,
		})
		local joined = instance.join("alice", saved)
		assert(joined.ok, tostring(joined.reason))
		local migrated: any = instance.save("alice")
		assert(
			migrated.inventory.bag.limits.slots == 30 and migrated.inventory.bag.limits.kind == "bag",
			"v2 bag capacity"
		)
		assert(migrated.inventory.bag.items.fiber.quantity == 30, "persisted items survive join")
		assert(saved.inventory.bag.limits.slots == 20, "join does not mutate persisted input")
	end,
	["empty death ledgers follow role travel without accepting foreign bundles"] = function()
		local instance = setup(true)
		local saved: any = instance.save("alice")
		assert(saved.death == nil or next(saved.death.bundles.bundles) == nil, "fresh actor has no dropped bag")
		-- An ordinary damage transition initializes the world-owned death ledger.
		local ctx: any = context("tick", 0)
		ctx.serverId = "server-1"
		assert(run(instance, "vitals-damage", { 1000 }, ctx).ok, "damage commits")
		saved = instance.save("alice")
		assert(saved.death, "tick records the source world")
		saved.death.worldRevision = "previous-role"
		instance.leave("alice")
		assert(instance.join("alice", saved).ok, "empty source ledger can enter the destination role")
		assert((instance.save("alice") :: any).death.worldRevision == "world-1", "destination revision persisted")
	end,
	["legacy items keep missing provenance and material state roundtrips without aliasing"] = function()
		local instance = setup()
		local saved: any = instance.save("alice")
		assert(saved.inventory.bag.items.fiber.material == nil, "legacy origin is not invented")
		saved.inventory.bag.items.fiber.material = {
			item = "fiber",
			quantity = 30,
			level = 10,
			quality = 1,
			budget = 3,
			attributes = { hardness = 2 },
			history = "recorded-gather",
			sourceSpeciesId = "recorded-species",
		}
		assert(instance.hydrate and instance.hydrate("alice", saved).ok, "hydrate recorded provenance")
		local reloaded: any = instance.save("alice")
		assert(
			reloaded.inventory.bag.items.fiber.material.sourceSpeciesId == "recorded-species",
			"origin survives adapter"
		)
		reloaded.inventory.bag.items.fiber.material.attributes.hardness = 9
		local isolated: any = instance.save("alice")
		assert(
			isolated.inventory.bag.items.fiber.material.attributes.hardness == 2,
			"save candidate does not alias live material"
		)
	end,
	["v2 explicitly opts into larger bags and clans while v1 keeps its caps"] = function()
		local cfg = config()
		cfg.inventory.content.limits.slots = 30
		cfg.inventory.content.limits.tribeMaxMembers = 50
		cfg.inventory.content.wildlife = { { id = "direWolf", behavior = "hunter" } }
		assert(#CraftingAdapter.validateConfig(cfg) > 0, "v1 rejects v2 limits and identities")
		cfg.contentVersion = 2
		assert(#CraftingAdapter.validateConfig(cfg) > 0, "outer version alone cannot upgrade legacy content")
		cfg.inventory.content.survival_content = 2
		local errors = CraftingAdapter.validateConfig(cfg)
		assert(#errors == 0, table.concat(errors, "; "))
		cfg.inventory.content.limits.slots = 31
		assert(#CraftingAdapter.validateConfig(cfg) > 0, "v2 bag maximum remains bounded")
		cfg.inventory.content.limits.slots = 30
		cfg.inventory.content.limits.tribeMaxMembers = 51
		assert(#CraftingAdapter.validateConfig(cfg) > 0, "v2 clan maximum remains bounded")
	end,

	["committed craft-complete emits one craft event after apply"] = function()
		local instance, seen = setup()
		local reserved = run(instance, "craft-reserve", { "cord", "" }, context("r1", 0))
		assert(reserved.ok, tostring(reserved.reason))
		local jobId = assert(reserved.data).jobId
		assert(run(instance, "craft-start", { jobId }, context("r2", 0)).ok, "start")
		local early = run(instance, "craft-complete", { jobId }, context("r3", 10))
		assert(not early.ok and early.reason == "NOT_READY", "not ready yet: " .. tostring(early.reason))
		assert(#seen == 0, "reserve, start and a refused complete emit nothing")
		local unapplied =
			assert((instance :: any).stageCommand("alice", "craft-complete", { jobId }, context("r4", 2000)))
		assert(unapplied.result.ok, "staged completion")
		assert(#seen == 0, "an uncommitted stage emits nothing")
		assert(run(instance, "craft-complete", { jobId }, context("r5", 2000)).ok, "complete")
		assert(#seen == 1, "one craft event, got " .. #seen)
		assert(seen[1].name == "craft", "craft event")
		assert(seen[1].fields.actorId == "alice" and seen[1].fields.recipeId == "cord", "actor and recipe")
		assert(seen[1].fields.jobId == jobId and seen[1].fields.atMillis == 2000, "job and explicit clock")
	end,

	["lethal damage emits one death event and non-lethal damage none"] = function()
		local instance, seen = setup()
		assert(run(instance, "vitals-damage", { 1000 }, context("d1", 0)).ok, "survivable hit")
		assert(#seen == 0, "non-lethal damage emits nothing")
		assert(run(instance, "vitals-damage", { 100000 }, context("d2", 0)).ok, "lethal hit")
		assert(#seen == 1 and seen[1].name == "death", "one death event")
		assert(seen[1].fields.actorId == "alice" and seen[1].fields.cause == "vitals-damage", "actor and cause")
		local again = run(instance, "vitals-damage", { 1 }, context("d3", 0))
		assert(not again.ok and again.reason == "NOT_ALIVE", "dead actors cannot die again")
		assert(#seen == 1, "a refused hit emits nothing")
	end,

	["survival death emits one death event with the dropped bundle size"] = function()
		local instance, seen = setup(true)
		local ctx: any = { actorId = "alice", requestId = "k1", sessionEpoch = 0, nowMillis = 0, serverId = "server-1" }
		assert(run(instance, "vitals-damage", { 100000 }, ctx).ok, "early lethal hit")
		assert(#seen == 1 and seen[1].name == "death", "one death event, got " .. #seen)
		local fields = seen[1].fields
		assert(fields.deathId == "death:1" and fields.cause == "vitals-damage", "death id and cause")
		assert(fields.droppedItems == 0, "an early death keeps the bag, got " .. tostring(fields.droppedItems))
		ctx.requestId = "k2"
		local again = run(instance, "vitals-damage", { 1 }, ctx)
		assert(not again.ok and again.reason == "NOT_ALIVE", "dead actors cannot die again")
		assert(#seen == 1, "a refused hit emits nothing")

		local late, lateSeen = setup(true)
		ctx = { actorId = "alice", requestId = "k3", sessionEpoch = 0, nowMillis = 1800000, serverId = "server-1" }
		assert(run(late, "vitals-damage", { 100000 }, ctx).ok, "late lethal hit")
		assert(#lateSeen == 1, "one late death event, got " .. #lateSeen)
		assert(
			lateSeen[1].fields.droppedItems == 1,
			"the fiber stack drops, got " .. tostring(lateSeen[1].fields.droppedItems)
		)
	end,
}
