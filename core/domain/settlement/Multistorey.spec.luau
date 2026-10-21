--!strict
local Building = require("./Multistorey")
local policy = { floors = 3, cellStuds = 16, floorHeight = 12, baseY = 2, stairSteps = 16 }
local function place(state: Building.State, id: string, kind: string, floor: number, x: number?)
	return assert(
		Building.place(state, policy, { id = id, kind = kind, floor = floor, x = x or 0, z = 0 }, state.version),
		"Multistorey.spec.luau: invariant at line 5"
	)
end
return {
	["three floors have support stair access and collision geometry"] = function()
		local state = Building.new()
		assert(
			not Building.place(state, policy, { id = "bad", kind = "floor", floor = 2, x = 0, z = 0 }, 0),
			"Multistorey.spec.luau: invariant at line 12"
		)
		for floor = 1, 3 do
			state = place(state, "f" .. floor, "floor", floor)
			assert(Building.reachable(state, floor, 0, 0), "Multistorey.spec.luau: invariant at line 15")
			if floor < 3 then
				state = place(state, "p" .. floor, "pillar", floor)
				state = place(state, "s" .. floor, "stairs", floor)
			end
		end
		for _, id in { "p1", "p2", "f1", "f2", "s1", "s2" } do
			assert(not Building.remove(state, id, state.version), "support/access removal must refuse: " .. id)
		end
		assert(
			not Building.place(
				state,
				policy,
				{ id = "overlap", kind = "floor", floor = 3, x = 0, z = 0 },
				state.version
			),
			"Multistorey.spec.luau: invariant at line 24"
		)
		assert(
			not Building.place(state, policy, { id = "four", kind = "floor", floor = 4, x = 0, z = 0 }, state.version),
			"Multistorey.spec.luau: invariant at line 32"
		)
		local geometry = Building.geometry(policy, state.parts.s1, state)
		assert(#geometry == policy.stairSteps, "Multistorey.spec.luau: invariant at line 36")
		local previous = 0
		for _, box in geometry do
			assert(
				box.canCollide and box.width >= 4 and box.height - previous <= 1,
				"Multistorey.spec.luau: invariant at line 39"
			)
			previous = box.height
		end
		assert(previous == policy.floorHeight, "Multistorey.spec.luau: invariant at line 42")
		local landing = Building.geometry(policy, state.parts.f2, state)[1]
		assert(landing.depth < policy.cellStuds, "stairwell must stay open")
		local upper = assert(Building.remove(state, "f3", state.version), "Multistorey.spec.luau: invariant at line 45")
		assert(Building.remove(upper, "p2", upper.version), "Multistorey.spec.luau: invariant at line 46")
	end,
}
