--!strict
local Deploy = require("./deploy")
return {
	["per role deploy refuses unknown missing duplicate and zero targets"] = function()
		local config =
			{ environments = { staging = { universeId = 1, placeId = 2, roles = { harbor = 3, home = 4 } } } }
		local selected =
			assert(Deploy.roleTarget(config, "staging", "home"), "deploy-role.spec.luau: routing invariant")
		assert(selected.environments.staging.placeId == 4, "deploy-role.spec.luau: routing invariant")
		assert(config.environments.staging.placeId == 2, "deploy-role.spec.luau: routing invariant")
		assert(Deploy.roleTarget(config, "staging", "invalid") == nil, "deploy-role.spec.luau: routing invariant")
		assert(Deploy.roleTarget(config, "staging", "brawl") == nil, "deploy-role.spec.luau: routing invariant")
		config.environments.staging.roles.home = 0
		assert(Deploy.roleTarget(config, "staging", "home") == nil, "deploy-role.spec.luau: routing invariant")
		config.environments.staging.roles.home = 3
		assert(Deploy.roleTarget(config, "staging", "home") == nil, "deploy-role.spec.luau: routing invariant")
	end,
}
