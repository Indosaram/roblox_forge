--!strict
local Combat = require("./Combat")
local origin = { x = 0, y = 0, z = 0 }
local forward = { x = 0, y = 0, z = -1 }
local target = { x = 0, y = 0, z = -4 }
local rule = {
	mode = "melee",
	windupMillis = 600,
	recoveryMillis = 1000,
	range = 6,
	facingDot = 0.707,
	damageMilli = 10000,
	ammo = 0,
}
local function attack(): Combat.Attack
	return assert(Combat.begin("strike-1", "actor", rule, 0, 0, origin, forward, 0, false))
end
return {
	["dodge window avoids strike but late and expired dodges take damage"] = function()
		local defense = Combat.window(Combat.defense(), "dodge", 400, 300)
		local _, damage, outcome = Combat.resolve(attack(), 600, "actor", target, true, defense)
		assert(damage == 0 and outcome == "DODGE", "in window")
		for _, start in { 601, 100 } do
			local _, hit, result = Combat.resolve(
				attack(),
				900,
				"actor",
				target,
				true,
				Combat.window(Combat.defense(), "dodge", start, 300)
			)
			assert(hit == 10000 and result == "HIT", "late or expired")
		end
	end,
	["windup cannot hit early or twice and misses still recover"] = function()
		local windup, early, result = Combat.resolve(attack(), 599, "actor", target, true, Combat.defense())
		assert(early == 0 and result == "WINDUP" and not windup.resolved, "windup")
		local struck, hit = Combat.resolve(windup, 600, "actor", target, true, Combat.defense())
		assert(hit == 10000 and struck.resolved, "strike")
		assert(select(2, Combat.resolve(struck, 600, "actor", target, true, Combat.defense())) == 0, "single hit")
		for _, geometry in
			{
				{ target = "other", pos = target, los = true },
				{ target = "actor", pos = target, los = false },
				{ target = "actor", pos = { x = 0, y = 0, z = 4 }, los = true },
				{ target = "actor", pos = { x = 0, y = 0, z = -7 }, los = true },
			}
		do
			local miss, damage, outcome =
				Combat.resolve(attack(), 600, geometry.target, geometry.pos, geometry.los, Combat.defense())
			assert(damage == 0 and outcome == "MISS" and miss.recoveryUntil == 1600 and miss.resolved, "geometry")
		end
	end,
	["guard armor and stance apply after geometry"] = function()
		local defense = Combat.window(Combat.defense(), "guard", 500, 200)
		defense.guardPermille, defense.armorPermille, defense.stancePermille = 500, 800, 1250
		local _, damage, outcome = Combat.resolve(attack(), 600, "actor", target, true, defense)
		assert(damage == 5000 and outcome == "GUARD", "mitigation order")
	end,
	["ranged ammunition cannot be negative or free and mounted attacks are refused"] = function()
		local ranged = table.clone(rule)
		ranged.mode, ranged.ammo, ranged.range = "ranged", 1, 40
		local shot, ammo = Combat.begin("shot", "actor", ranged, 0, 0, origin, forward, 1, false)
		assert(shot and ammo == 0, "one ammunition consumed")
		assert(
			select(3, Combat.begin("shot", "actor", ranged, 0, 0, origin, forward, 0, false)) == "NO_AMMO",
			"no free shot"
		)
		assert(
			not pcall(Combat.begin, "shot", "actor", ranged, 0, 0, origin, forward, -1, false),
			"negative materials refused"
		)
		assert(
			select(3, Combat.begin("shot", "actor", rule, 0, 0, origin, forward, 0, true)) == "MOUNTED",
			"mounted combat refused"
		)
		assert(
			select(3, Combat.begin("shot", "actor", rule, 0, 1, origin, forward, 0, false)) == "RECOVERY",
			"recovery gate"
		)
	end,
}
