--!strict
-- Specs for Topology: kinds, capacity policy, and allowed transitions.

local Topology = require("./Topology")

return {
	["every kind defaults to the policy capacity of 8"] = function()
		local t = Topology.new()
		for _, kind in Topology.kinds() do
			assert(Topology.capacity(t, kind) == 8, kind .. " should default to 8")
		end
		assert(#Topology.kinds() == 5, "five kinds")
		assert(Topology.phase("contested") == "P2", "contested is P2")
		assert(Topology.phase("harbor") == "P0", "harbor is P0")
	end,

	["capacity overrides may only lower the cap"] = function()
		local t = Topology.new({ harbor = 6 })
		assert(Topology.capacity(t, "harbor") == 6, "override applied")
		assert(Topology.capacity(t, "landing") == 8, "others untouched")
		assert(not (pcall(Topology.new, { harbor = 9 })), "above policy cap")
		assert(not (pcall(Topology.new, { harbor = 0 })), "zero capacity")
		assert(not (pcall(Topology.new, { harbor = 2.5 })), "fractional capacity")
		assert(not (pcall(Topology.new, { lobby = 4 })), "unknown kind")
	end,

	["allowed transitions"] = function()
		local pairs = {
			{ "landing", "homestead" },
			{ "landing", "harbor" },
			{ "homestead", "harbor" },
			{ "harbor", "homestead" },
			{ "harbor", "expedition" },
			{ "expedition", "harbor" },
			{ "harbor", "contested" },
			{ "contested", "harbor" },
		}
		for _, p in pairs do
			local ok, code = Topology.validateTransition(p[1], p[2])
			assert(ok and code == nil, p[1] .. "->" .. p[2] .. " should be allowed")
		end
	end,

	["invalid transitions are rejected with a code"] = function()
		local cases = {
			{ "homestead", "landing", "transition_not_allowed" },
			{ "expedition", "homestead", "transition_not_allowed" },
			{ "landing", "expedition", "transition_not_allowed" },
			{ "harbor", "harbor", "same_kind" },
			{ "lobby", "harbor", "unknown_source_kind" },
			{ "harbor", "lobby", "unknown_target_kind" },
		}
		for _, c in cases do
			local ok, code = Topology.validateTransition(c[1], c[2])
			assert(not ok, c[1] .. "->" .. c[2] .. " should be rejected")
			assert(code == c[3], "expected " .. c[3] .. " got " .. tostring(code))
			assert(not Topology.canTransition(c[1] :: any, c[2] :: any), "canTransition agrees")
		end
	end,
}
