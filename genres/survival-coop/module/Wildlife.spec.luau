--!strict
local Wildlife = require("./Wildlife")
local Content = require("../../../core/domain/survival/Content")
local Inventory = require("../../../core/domain/inventory/Inventory")
local function fixture()
	local items: { any } = {
		{ id = "spear", name = "Spear", stackMax = 1, weightMilli = 100, maxDurabilityMilli = 1000 },
		{ id = "meat", name = "Meat", stackMax = 10, weightMilli = 100 },
	}
	local content, errors = Content.canonicalize({
		survival_content = 1,
		rules = Content.RULES,
		limits = Content.DEFAULT_LIMITS,
		items = items,
		wildlife = { { id = "grazer", behavior = "grazer" }, { id = "hunter", behavior = "hunter" } },
	})
	assert(content, table.concat(errors, "; "))
	local catalog = Wildlife.catalog(content, {
		species = {
			grazer = { healthMilli = 20000, damageMilli = 0, drops = { { item = "meat", quantity = 1 } } },
			hunter = { healthMilli = 40000, damageMilli = 10000, drops = { { item = "meat", quantity = 2 } } },
		},
		weapons = {
			spear = { damageMilli = 20000, wearMilli = 100, rangeStuds = 8, facingDot = 0.5, cooldownMillis = 2000 },
		},
	})
	local state = Wildlife.new("hunter-1", "hunter", { x = 0, y = 0, z = 0 }, catalog)
	local observation: Wildlife.Observation = {
		position = { x = 0, y = 0, z = 0 },
		actors = {
			{ id = "bob", position = { x = 3, y = 0, z = 0 }, alive = true },
			{
				id = "alice",
				position = { x = 3, y = 0, z = 0 },
				alive = true,
			},
		},
		pathFailed = false,
		lineOfSight = function()
			return true
		end,
	}
	return content, catalog, state, observation
end
return {
	["hunter tie warning telegraph cooldown LOS and path failure"] = function()
		local content, catalog, state, observation = fixture()
		local definition = content.wildlife[2]
		local function step(now: number): Wildlife.Intent
			local nextState, intent = Wildlife.step(state, definition, catalog.species.hunter, now, observation)
			state = nextState
			return intent
		end
		assert(not step(0).damage and tostring(state.mode) == "warn" and state.target == "alice", "wildlife invariant")
		assert(not step(999).damage and tostring(state.mode) == "warn", "wildlife invariant")
		assert(not step(1000).damage and tostring(state.mode) == "telegraph", "wildlife invariant")
		assert(not step(1999).damage, "wildlife invariant")
		local hit = assert(step(2000).damage, "wildlife invariant")
		assert(
			hit.actorId == "alice" and hit.damageMilli == 10000 and hit.strikeId == "hunter-1:1",
			"wildlife invariant"
		)
		assert(not step(3999).damage and tostring(state.mode) == "chase", "wildlife invariant")
		step(4000)
		observation.lineOfSight = function()
			return false
		end
		assert(not step(5000).damage and state.nextAttack == 7000, "LOS sampled at strike")
		observation.lineOfSight = function()
			return true
		end
		step(7000)
		observation.pathFailed = true
		assert(not step(8000).damage and tostring(state.mode) == "idle" and state.target == nil, "wildlife invariant")
		observation.pathFailed = false
		step(8001)
		assert(tostring(state.mode) == "warn", "lost path must restart warning")
		assert(not pcall(step, 8000), "clock cannot regress")
	end,
	["range escape target changes and leash cancel pending strike"] = function()
		local content, catalog, state, observation = fixture()
		local function step(now: number): Wildlife.Intent
			local nextState, intent =
				Wildlife.step(state, content.wildlife[2], catalog.species.hunter, now, observation)
			state = nextState
			return intent
		end
		step(0)
		step(1000)
		for _, actor in observation.actors do
			actor.position.x = 8.1
		end
		assert(not step(2000).damage, "wildlife invariant")
		observation.actors[2].alive = false
		step(2001)
		assert(tostring(state.mode) == "warn" and state.target == "bob", "wildlife invariant")
		observation.position.x = 41
		local intent = step(3001)
		assert(
			not intent.damage
				and tostring(state.mode) == "return"
				and assert(intent.destination, "return destination").x == 0,
			"return without strike"
		)
		observation.position.x = 0
		step(3002)
		assert(tostring(state.mode) == "idle", "wildlife invariant")
	end,
	["grazer senses twelve flees through twenty four then roams"] = function()
		local content, catalog, _, observation = fixture()
		local state = Wildlife.new("grazer-1", "grazer", { x = 0, y = 0, z = 0 }, catalog)
		observation.actors = { { id = "alice", position = { x = 12, y = 0, z = 0 }, alive = true } }
		local nextState, intent = Wildlife.step(state, content.wildlife[1], catalog.species.grazer, 0, observation)
		assert(
			tostring(nextState.mode) == "flee" and assert(intent.destination, "flee destination").x == -24,
			"flee away from actor"
		)
		observation.actors[1].position.x = 24
		nextState = Wildlife.step(nextState, content.wildlife[1], catalog.species.grazer, 1, observation)
		assert(tostring(nextState.mode) == "flee", "wildlife invariant")
		observation.actors[1].position.x = 24.1
		nextState = Wildlife.step(nextState, content.wildlife[1], catalog.species.grazer, 2, observation)
		assert(tostring(nextState.mode) == "roam" and tostring(state.mode) == "idle", "wildlife invariant")
	end,
	["combat refuses forged spatial equipment and reserved broken weapons"] = function()
		local _, catalog, state = fixture()
		local bag = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		bag.items.spear = {
			itemId = "spear",
			catalogId = "spear",
			quantity = 1,
			qualityMilli = 1000,
			durabilityMilli = 1000,
			attributes = {},
		}
		local access: Wildlife.Access = {
			actorId = "alice",
			alive = true,
			position = { x = 0, y = 0, z = 0 },
			targetPosition = { x = 4, y = 0, z = 0 },
			facing = { x = 1, y = 0, z = 0 },
			lineOfSight = true,
			equipped = { spear = true },
		}
		local function refuse(reason: string, cooldown: number?)
			local result, err = Wildlife.attack(state, bag, catalog, 0, cooldown or 0, access)
			assert(not result and err == reason, tostring(err))
			assert(state.healthMilli == 40000 and bag.items.spear.durabilityMilli == 1000, "wildlife invariant")
		end
		refuse("COOLDOWN", 1)
		access.alive = false
		refuse("NOT_ALIVE")
		access.alive = true
		access.equipped = {}
		refuse("WEAPON_UNAVAILABLE")
		access.equipped = { spear = true }
		bag.reservations.job = { spear = 1 }
		refuse("WEAPON_UNAVAILABLE")
		bag.reservations = {}
		access.targetPosition.x = 8.01
		refuse("OUT_OF_RANGE")
		access.targetPosition.x = 4
		access.lineOfSight = false
		refuse("BLOCKED")
		access.lineOfSight = true
		access.facing.x = -1
		refuse("NOT_FACING")
		access.facing.x = 1
		bag.items.spear.durabilityMilli = 0
		local broken, err = Wildlife.attack(state, bag, catalog, 0, 0, access)
		assert(not broken and err == "WEAPON_UNAVAILABLE", "wildlife invariant")
	end,
	["owner publishes wear health cooldown and single death entitlement together"] = function()
		local _, catalog, state = fixture()
		local bag = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		bag.items.spear = {
			itemId = "spear",
			catalogId = "spear",
			quantity = 1,
			qualityMilli = 1000,
			durabilityMilli = 1000,
			attributes = {},
		}
		local access: Wildlife.Access = {
			actorId = "alice",
			alive = true,
			position = { x = 0, y = 0, z = 0 },
			targetPosition = { x = 4, y = 0, z = 0 },
			facing = { x = 1, y = 0, z = 0 },
			lineOfSight = true,
			equipped = { spear = true },
		}
		local first = assert(Wildlife.attack(state, bag, catalog, 0, 0, access))
		assert(
			first.wildlife.healthMilli == 20000
				and first.inventory.items.spear.durabilityMilli == 900
				and not first.deathId,
			"wildlife invariant"
		)
		assert(bag.items.spear.durabilityMilli == 1000 and state.healthMilli == 40000, "failed commit immutable")
		local retry = assert(Wildlife.attack(state, bag, catalog, 0, 0, access))
		assert(retry.wildlife.healthMilli == first.wildlife.healthMilli, "wildlife invariant")
		local dead = assert(Wildlife.attack(first.wildlife, first.inventory, catalog, 2000, first.nextAttack, access))
		assert(
			dead.deathId == "hunter-1:death" and dead.wildlife.killer == "alice" and dead.drops[1].quantity == 2,
			"wildlife invariant"
		)
		local duplicate, err = Wildlife.attack(dead.wildlife, dead.inventory, catalog, 4000, dead.nextAttack, access)
		assert(not duplicate and err == "ALREADY_DEAD", "wildlife invariant")
	end,
}
