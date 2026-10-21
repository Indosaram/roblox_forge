--!strict
local Combat = require("../../../../genres/survival-coop/module/Combat")
local Wildlife = require("../../../../genres/survival-coop/module/Wildlife")
local TamingRuntime = require("../../../../genres/survival-coop/module/TamingRuntime")
local Mounts = require("../../../../genres/survival-coop/module/Mounts")
local Taming = require("../../../../core/domain/taming/Taming")
local Content: any = require("../../../../games/robango-island/src/shared/SurvivalContent")
local Policy = require("../../../../games/robango-island/src/shared/TamingConfig")
local M = {}
M.operations = {
	creature_combat = function(ctx: any, step: any): string?
		local species = ctx.fixture.species
		local rule = species.attacks[1]
		local origin = { x = 0, y = 0, z = 0 }
		local direction = { x = 0, y = 0, z = -1 }
		local attack = assert(Combat.begin("fixture-strike", "owner", {
			mode = "melee",
			windupMillis = rule.windupSeconds * 1000,
			recoveryMillis = rule.recoverySeconds * 1000,
			range = rule.range,
			facingDot = 0.707,
			damageMilli = rule.damage * 1000,
			ammo = 0,
		}, 0, 0, origin, direction, 0, false))
		local start = attack.resolveAt + (if step.late then 1 else -100)
		local _, damage, result = Combat.resolve(
			attack,
			attack.resolveAt + 20,
			"owner",
			direction,
			true,
			Combat.window(Combat.defense(), "dodge", start, 300)
		)
		if (step.late and damage <= 0) or (not step.late and damage ~= 0) then
			return "dodge timing mismatch"
		end
		ctx.results[ctx.playerOf(step)] = { ok = true, data = { outcome = result, damage = damage } }
		return nil
	end,
	creature_tame_ride = function(ctx: any, step: any): string?
		local actor = ctx.playerOf(step)
		local runtime = ctx.fixture.runtime
		assert(runtime.spawnWild("fixture-wild", "protoceratops") == nil, "spawn")
		runtime.hit("fixture-wild", 4)
		local captured = runtime.capture(actor, "capture", "fixture-wild", { durabilityMilli = 100000 })
		assert(captured.captured and captured.animalId, "seeded capture")
		assert(
			not runtime.capture(actor, "duplicate", "fixture-wild", { durabilityMilli = 100000 }).ok,
			"duplicate refused"
		)
		local state = Wildlife.new("fixture-wild", "protoceratops", { x = 0, y = 0, z = 0 }, {
			species = {
				protoceratops = {
					healthMilli = ctx.fixture.species.health * 1000,
					damageMilli = ctx.fixture.species.damage * 1000,
					drops = {},
				},
			},
			weapons = {},
		})
		assert(Wildlife.capture(state, state.version, "captured"), "capture branch")
		state.healthMilli = 0
		assert(select(2, Wildlife.capture(state, state.version, "dead")) == "ALREADY_DEAD", "death branch")
		ctx.fixture.clock = 300000
		assert(runtime.mount(actor, captured.animalId, nil, { pvp = false }), "ready mount")
		local saved = runtime.list(actor)
		runtime.forget(actor)
		assert(runtime.restore(actor, saved) == nil, "reconnect restores ownership")
		local ride = assert(runtime.mount(actor, captured.animalId, nil, { pvp = false }))
		assert(ride.speedStuds == ctx.fixture.species.mount.runSpeed, "catalog ride")
		ctx.results[actor] = { ok = true, data = { animals = #saved, ride = ride.species, duplicate = 0 } }
		return nil
	end,
}
function M.new(ctx: any): any
	local fixture: any = { clock = 0 }
	for _, species in Content.wildlifeDetails or {} do
		if species.id == "protoceratops" then
			fixture.species = species
		end
	end
	local config = table.clone(Policy.taming)
	config.successPermille = 1000 -- fixture outcome, not a shipped probability change
	fixture.runtime = TamingRuntime.new({
		taming = Taming.config(config),
		mounts = Mounts.catalog(Content, Policy.mounts),
		content = Content,
		tameable = Policy.tameable,
		seed = ctx.scenario.seed,
		now = function()
			return fixture.clock
		end,
		maxWild = Policy.maxWild,
		maxAnimalsPerOwner = Policy.maxAnimalsPerOwner,
		maxReceipts = Policy.maxReceipts,
	})
	return fixture
end
return M
