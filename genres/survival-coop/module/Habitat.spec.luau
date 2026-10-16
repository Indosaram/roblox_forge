--!strict
local Habitat = require("./Habitat")

local HOME = { x = 0, y = 0, z = 0 }

return {
	["a vacated slot respawns exactly after its clock delay"] = function()
		local slot = Habitat.slot("den-1", "hunter", HOME, 60000)
		assert(Habitat.ready(slot, 0), "an empty slot populates immediately")
		local filled, npc = Habitat.fill(slot, 0)
		assert(npc == "den-1#1" and not Habitat.ready(filled, 0), "occupied slot is not due")
		local vacated = Habitat.vacate(filled, npc, 1000)
		assert(not Habitat.ready(vacated, 60999), "not before the respawn delay")
		assert(Habitat.ready(vacated, 61000), "due exactly at the delay")
		local _, second = Habitat.fill(vacated, 61000)
		assert(second == "den-1#2", "deterministic generation id")
		assert(not pcall(Habitat.fill, vacated, 60999), "early fill refused")
		assert(not pcall(Habitat.vacate, vacated, npc, 2000), "only the occupant vacates")
		assert(filled.occupant == npc and slot.occupant == nil, "copy-on-write")
	end,
	["due respects the 32 NPC world budget and earliest vacancy order"] = function()
		local slots = {}
		for index = 1, 40 do
			table.insert(slots, Habitat.slot(string.format("s%02d", index), "grazer", HOME, 1000))
		end
		assert(#Habitat.due(slots, 0, 0) == 32, "never more than the world budget")
		assert(#Habitat.due(slots, 0, 32) == 0, "a full world spawns nothing")
		assert(#Habitat.due(slots, 0, 30) == 2, "only the free budget")
		local a, idA = Habitat.fill(slots[1], 0)
		local b, idB = Habitat.fill(slots[2], 0)
		local due = Habitat.due({ Habitat.vacate(b, idB, 10), Habitat.vacate(a, idA, 20) }, 5000, 31)
		assert(#due == 1 and due[1] == "s02", "earliest vacancy refills first")
		assert(not pcall(Habitat.due, slots, 0, 0, 33), "budget above 32 refused")
	end,
}
