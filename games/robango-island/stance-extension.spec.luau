--!strict
-- stance-set: durable client action, validated on the personal slice, read back by snapshot.
local StanceExtension = require("../../genres/survival-coop/module/StanceExtension")
local Contract = require("../../genres/survival-coop/module/Contract")
local Durable = require("./src/shared/GenreDurable")

return {
	["stance-set and attack-ranged are declared durable client actions"] = function()
		for _, id in { "stance-set", "attack-ranged" } do
			assert(table.find(Contract.extensionActions :: { string }, id), "extension action " .. id)
			assert(table.find(Durable.actions, "survival-coop:" .. id), "durable " .. id)
		end
	end,
	["apply writes the stance only when its node is learned and the cooldown passed"] = function()
		local slice: any = { progression = { paid = { ranged_1 = 2 } }, combat = { windupUntil = 0 } }
		local locked, why = StanceExtension.apply(slice, "attack", 0)
		assert(locked == nil and why == "STANCE_LOCKED", "attack locked without melee_1")
		local shoot = assert(StanceExtension.apply(slice, "shoot", 100))
		assert(shoot.stance.id == "shoot" and shoot.stance.changedAt == 100, "shoot selected")
		assert(slice.stance == nil, "input slice untouched")
		local _, cooldown = StanceExtension.apply(shoot, "none", 1000)
		assert(cooldown == "STANCE_COOLDOWN", "switch cooldown")
		shoot.combat = { windupUntil = 5000 }
		local _, windup = StanceExtension.apply(shoot, "none", 4000)
		assert(windup == "STANCE_WINDUP", "a drawn shot locks the stance")
		assert(assert(StanceExtension.apply(shoot, "none", 5000)).stance.id == "none", "cleared after windup")
	end,
}
