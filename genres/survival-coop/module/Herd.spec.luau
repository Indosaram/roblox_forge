--!strict
local Herd = require("./Herd")

local function line(count: number, spacing: number): { [string]: any }
	local positions = {}
	for index = 0, count - 1 do
		positions["m" .. index] = { x = index * spacing, y = 0, z = 0 }
	end
	return positions
end

return {
	["alarm recruits members within radius and leaves distant ones alone"] = function()
		local herd = Herd.new("h", "m0", { "m1", "m2", "far" }, { alarmStuds = 10, maxJoin = 8, maxChain = 1 })
		local positions = line(3, 6)
		positions.far = { x = 100, y = 0, z = 0 }
		local joins = Herd.alarm(herd, "m1", positions)
		assert(#joins == 2 and joins[1].id == "m0" and joins[2].id == "m2", "both neighbours join, id tiebreak")
		for _, join in joins do
			assert(join.id ~= "far" and join.id ~= "m1", "outside radius and the struck creature never join")
		end
		assert(#Herd.alarm(herd, "stranger", positions) == 0, "a non-member raises no alarm")
		positions.m2 = nil
		assert(#Herd.alarm(herd, "m1", positions) == 1, "absent or dead members neither join nor relay")
	end,
	["join chain cap and total join cap bound the cascade"] = function()
		local members = {}
		for index = 1, 9 do
			table.insert(members, "m" .. index)
		end
		local positions = line(10, 8)
		local chained = Herd.new("h", "m0", members, { alarmStuds = 10, maxJoin = 31, maxChain = 3 })
		local joins = Herd.alarm(chained, "m0", positions)
		assert(#joins == 3 and joins[3].id == "m3" and joins[3].hop == 3, "relay stops at the chain cap")
		local capped = Herd.new("h", "m0", members, { alarmStuds = 10, maxJoin = 2, maxChain = 8 })
		assert(#Herd.alarm(capped, "m0", positions) == 2, "join cap stops recruitment")
		local engaged = Herd.alarm(chained, "m0", positions, { m1 = true })
		assert(
			#engaged == 2 and engaged[1].id == "m2" and engaged[2].id == "m3",
			"already-engaged members relay without being recruited again"
		)
	end,
	["herd configuration is validated"] = function()
		assert(not pcall(Herd.new, "h", "a", { "a" }, { alarmStuds = 10, maxJoin = 1, maxChain = 1 }), "leader twice")
		assert(not pcall(Herd.new, "h", "a", {}, { alarmStuds = 0, maxJoin = 1, maxChain = 1 }), "zero radius")
		assert(not pcall(Herd.new, "h", "a", {}, { alarmStuds = 5, maxJoin = 32, maxChain = 1 }), "join above budget")
		assert(not pcall(Herd.new, "h", "a", {}, { alarmStuds = 5, maxJoin = 1, maxChain = 0 }), "chain below one")
	end,
}
