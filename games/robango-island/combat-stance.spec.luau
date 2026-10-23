--!strict
-- Six combat stances (fidelity contract S2 combat row): unlock nodes, 2 s switch cooldown,
-- windup lock, and the damage / incoming / speed multipliers.
local Stance = require("../../genres/survival-coop/module/Stance")
local Content = require("./src/shared/SurvivalContent")

local function learned(...: string): any
	local paid = {}
	for _, id in { ... } do
		paid[id] = 2
	end
	return { paid = paid }
end

return {
	["each stance is unlocked by its catalog skill node"] = function()
		local nodes: { [string]: boolean } = {}
		for _, node in (Content :: any).skillNodes do
			nodes[node.id] = true
		end
		for id: string, node: string in Stance.NODES :: { [string]: string } do
			assert(nodes[node], id .. " unlock node exists in content: " .. node)
		end
		local next, reason = Stance.select(nil, learned(), "attack", 0, 0)
		assert(next == nil and reason == "STANCE_LOCKED", "attack needs melee_1")
		local attack = assert(Stance.select(nil, learned("melee_1"), "attack", 0, 0))
		assert(attack.id == "attack" and attack.changedAt == 0, "attack selected")
		assert(Stance.select(nil, learned("melee_1"), "parry", 0, 0) == nil, "unknown stance refused")
		assert(assert(Stance.select(attack, learned(), "none", 5000, 0)).id == "none", "none needs no node")
	end,
	["switching waits two seconds and never interrupts a windup"] = function()
		local tree = learned("melee_1", "ranged_1")
		local first = assert(Stance.select(nil, tree, "attack", 1000, 0))
		local _, early = Stance.select(first, tree, "shoot", 2999, 0)
		assert(early == "STANCE_COOLDOWN", "2 s switch cooldown")
		local _, windup = Stance.select(first, tree, "shoot", 3000, 3200)
		assert(windup == "STANCE_WINDUP", "no switch during an attack windup")
		assert(assert(Stance.select(first, tree, "shoot", 3000, 3000)).id == "shoot", "switch after cooldown")
	end,
	["multipliers follow the stance table"] = function()
		local function at(id: string): any
			return { id = id, changedAt = 0 }
		end
		assert(Stance.damagePermille(nil, "melee", false) == 1000, "no stance is 1x")
		assert(Stance.damagePermille(at("attack"), "melee", false) == 1100, "attack 1.1x")
		assert(Stance.damagePermille(at("onslaught"), "ranged", false) == 1250, "onslaught 1.25x")
		assert(Stance.damagePermille(at("shoot"), "ranged", false) == 1150, "shoot 1.15x ranged")
		assert(Stance.damagePermille(at("shoot"), "melee", false) == 1000, "shoot only for ranged")
		assert(Stance.damagePermille(at("counter"), "melee", true) == 1300, "counter after a guard 1.3x")
		assert(Stance.damagePermille(at("counter"), "melee", false) == 1000, "counter without a guard 1x")
		assert(Stance.incomingPermille(at("defense")) == 750, "defense takes 0.75x")
		assert(Stance.incomingPermille(at("onslaught")) == 1200, "onslaught takes 1.2x")
		assert(Stance.incomingPermille(nil) == 1000, "no stance takes 1x")
		assert(Stance.speedPermille(at("defense")) == 900, "defense moves 0.9x")
		assert(Stance.speedPermille(at("charge")) == 1150, "charge moves 1.15x")
		assert(Stance.counterReady({ guardStart = 1000, guardEnd = 2000 }, 3999), "counter inside 2 s of a guard")
		assert(not Stance.counterReady({ guardStart = 1000, guardEnd = 2000 }, 4001), "counter window closes")
	end,
}
