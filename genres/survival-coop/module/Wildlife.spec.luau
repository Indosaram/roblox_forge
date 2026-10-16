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
	["leash escape returns home healing and arrival restores full health"] = function()
		local content, catalog, state, observation = fixture()
		local definition, rule = content.wildlife[2], catalog.species.hunter
		state.healthMilli = 10000
		observation.position = { x = 41, y = 0, z = 0 }
		local returning, intent = Wildlife.step(state, definition, rule, 1000, observation)
		assert(tostring(returning.mode) == "return" and returning.target == nil, "beyond leash returns")
		assert(assert(intent.destination, "home").x == 0, "return aims at home")
		assert(returning.healthMilli == 20000 and intent.healMilli == 10000, "regen while returning: 25%/s")
		observation.position = { x = 0.5, y = 0, z = 0 }
		observation.actors = {}
		local home, arrived = Wildlife.step(returning, definition, rule, 1100, observation)
		assert(tostring(home.mode) == "idle" and home.healthMilli == 40000, "arrival restores full health")
		assert(arrived.healMilli == 20000, "heal delta is published for the owner")
		local again, none = Wildlife.step(home, definition, rule, 1200, observation)
		assert(again.healthMilli == 40000 and none.healMilli == nil, "no heal past maximum")
	end,
	["no stuck aggro: unreachable engagement disengages and vanished provokers are forgotten"] = function()
		local content, catalog, state, observation = fixture()
		local definition, rule = content.wildlife[2], catalog.species.hunter
		observation.actors = { { id = "alice", position = { x = 6, y = 0, z = 0 }, alive = true } }
		local function step(now: number): Wildlife.Intent
			local nextState, intent = Wildlife.step(state, definition, rule, now, observation)
			state = nextState
			return intent
		end
		step(0)
		assert(tostring(state.mode) == "warn", "engages")
		step(1000)
		step(19999)
		assert(tostring(state.mode) == "chase", "still chasing inside the disengage window")
		local intent = step(20000)
		assert(tostring(state.mode) == "idle" and state.target == nil, "disengages after 20s out of strike range")
		assert(intent.damage == nil, "disengage never strikes")
		-- Negative control: a target kept inside strike range refreshes the engagement.
		local _, catalog2, fresh, near = fixture()
		near.actors = { { id = "bob", position = { x = 3, y = 0, z = 0 }, alive = true } }
		local s = fresh
		for _, now in { 0, 1000, 2000, 4000, 8000, 12000, 16000, 20000, 24000 } do
			s = Wildlife.step(s, definition, catalog2.species.hunter, now, near)
		end
		assert(tostring(s.mode) ~= "idle" and tostring(s.mode) ~= "return", "an engaged fight is not dropped")
		-- A provoker that dies or teleports away cannot keep the creature hostile.
		local _, catalog3, sweeper = fixture()
		local tail: any = table.clone(definition)
		tail.behavior = "tail-sweeper"
		local quiet: Wildlife.Observation = {
			position = { x = 0, y = 0, z = 0 },
			actors = { { id = "carol", position = { x = 3, y = 0, z = 0 }, alive = true } },
			pathFailed = false,
			lineOfSight = function()
				return true
			end,
		}
		sweeper = Wildlife.step(sweeper, tail, catalog3.species.hunter, 0, quiet)
		assert(tostring(sweeper.mode) == "idle", "retaliator ignores an unprovoking actor in range")
		quiet.provokedBy = "carol"
		sweeper = Wildlife.step(sweeper, tail, catalog3.species.hunter, 10, quiet)
		assert(tostring(sweeper.mode) == "warn" and sweeper.provoker == "carol", "provocation engages")
		quiet.provokedBy = nil
		quiet.actors[1].alive = false
		sweeper = Wildlife.step(sweeper, tail, catalog3.species.hunter, 20, quiet)
		assert(sweeper.provoker == nil and sweeper.target == nil, "dead provoker forgotten")
		assert(tostring(sweeper.mode) == "idle", "no aggro survives its target")
	end,
	["sleep wakes only on close approach and hibernation outside observers heals in place"] = function()
		local content, catalog, state, observation = fixture()
		local definition, rule = content.wildlife[2], catalog.species.hunter
		observation.actors = { { id = "alice", position = { x = 8, y = 0, z = 0 }, alive = true } }
		observation.resting = true
		local slept = Wildlife.step(state, definition, rule, 0, observation)
		assert(tostring(slept.mode) == "sleep", "inside detection but beyond the wake radius it sleeps")
		observation.actors[1].position.x = 5
		local woke = Wildlife.step(slept, definition, rule, 1, observation)
		assert(tostring(woke.mode) == "warn", "a close approach wakes it")
		-- Negative control: awake (no rest window), the same approach at 8 studs warns.
		observation.resting = nil
		observation.actors[1].position.x = 8
		assert(tostring(Wildlife.step(state, definition, rule, 0, observation).mode) == "warn", "awake warns")
		observation.observerStuds = Wildlife.HIBERNATE_STUDS
		observation.actors[1].position.x = 200
		local hurt = table.clone(state)
		hurt.healthMilli = 1
		local idle, intent = Wildlife.step(hurt, definition, rule, 5, observation)
		assert(tostring(idle.mode) == "hibernate" and idle.healthMilli == 40000, "unobserved at home hibernates whole")
		assert(intent.destination == nil and intent.healMilli == 39999, "hibernation stops movement")
		observation.position = { x = 30, y = 0, z = 0 }
		local away, walk = Wildlife.step(hurt, definition, rule, 5, observation)
		assert(tostring(away.mode) == "return" and assert(walk.destination, "home").x == 0, "strays walk home first")
		observation.actors[1].position.x = 40
		observation.position = { x = 0, y = 0, z = 0 }
		local seen = Wildlife.step(idle, definition, rule, 6, observation)
		assert(tostring(seen.mode) == "idle", "an observer inside the radius ends hibernation")
	end,
	["danger band widens hunter detection and herd-grazer flees provocation"] = function()
		local content, catalog, state, observation = fixture()
		local banded: any = table.clone(content.wildlife[2])
		banded.behavior, banded.dangerBand = "charger", 3
		observation.actors = { { id = "alice", position = { x = 17, y = 0, z = 0 }, alive = true } }
		assert(
			tostring(Wildlife.step(state, content.wildlife[2], catalog.species.hunter, 0, observation).mode) == "idle",
			"band 1 ignores 17 studs"
		)
		assert(
			tostring(Wildlife.step(state, banded, catalog.species.hunter, 0, observation).mode) == "warn",
			"band 3 (x1.5 = 18) notices 17 studs"
		)
		local grazer = Wildlife.new("g", "grazer", { x = 0, y = 0, z = 0 }, catalog)
		local herd: any = table.clone(content.wildlife[1])
		herd.behavior = "herd-grazer"
		observation.actors[1].position.x = 30
		observation.provokedBy = "alice"
		local fled = Wildlife.step(grazer, herd, catalog.species.grazer, 0, observation)
		assert(tostring(fled.mode) == "flee" and fled.target == "alice", "alarm makes a grazer flee its provoker")
	end,
}
