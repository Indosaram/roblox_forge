--!strict
local Topology = require("./Topology")
return {
	["role map rejects zero unknown and duplicate places"] = function()
		assert(
			Topology.resolveRole({ home = 2, harbor = 3 }, 2) == "home",
			"TopologyRoles.spec.luau: routing invariant"
		)
		assert(Topology.resolveRole({ home = 0 }, 0) == nil, "TopologyRoles.spec.luau: routing invariant")
		assert(Topology.resolveRole({ home = 2, harbor = 2 }, 2) == nil, "TopologyRoles.spec.luau: routing invariant")
		assert(Topology.resolveRole({ invalid = 2 }, 2) == nil, "TopologyRoles.spec.luau: routing invariant")
	end,
	["frontiers need only character level and hub transition"] = function()
		for _, level in { 30, 40, 50, 60 } do
			local target = "frontier" .. level
			assert(
				Topology.validateRoleTransition("harbor", target, level),
				"TopologyRoles.spec.luau: routing invariant"
			)
			local ok, reason = Topology.validateRoleTransition("harbor", target, level - 1)
			assert(not ok and reason == "level_gate", "TopologyRoles.spec.luau: routing invariant")
		end
		assert(
			not Topology.validateRoleTransition("home", "frontier60", 60),
			"TopologyRoles.spec.luau: routing invariant"
		)
	end,
}
