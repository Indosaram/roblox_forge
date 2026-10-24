--!strict
-- Every live creature spawn point stands over generated terrain: the Studio onboarding preview
-- (projected spawns over the IslandTerrain heightfield plus node clearings) and every role layout
-- built by RoleWorld. Uses the same downward terrain ray as DinosaurRig.ground.
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local roblox: any = require("@lune/roblox")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")

local function offLand(engine: any, label: string, spawns: { any }, errors: { string })
	local workspace = engine.game:GetService("Workspace")
	-- Voxel writes become raycastable after an engine step.
	engine.game:GetService("RunService").Heartbeat:Wait()
	for _, spawn in spawns do
		local p = spawn.position
		local hit = workspace:Raycast(
			roblox.Vector3.new(p.x, 512, p.z),
			roblox.Vector3.new(0, -1024, 0),
			{ IgnoreWater = true, FilterDescendantsInstances = { workspace.Terrain } }
		)
		if not (hit and hit.Instance == workspace.Terrain) then
			table.insert(errors, string.format("%s %s (%g, %g) has no terrain below", label, spawn.id, p.x, p.z))
		end
	end
end

return {
	["every creature spawn point stands over generated terrain"] = function()
		local errors: { string } = {}
		local preview = Engine.new(nil, true)
		local world = preview.preview(Content, Source, Policy, function()
			return 0
		end, "onboarding", true)
		assert(#world.roleWildlife.spawns > 0, "preview spawns wildlife")
		offLand(preview, "preview", world.roleWildlife.spawns, errors)
		local checked = 0
		for _, layout in Content.layouts do
			if layout.id ~= "rw.home" and #layout.spawns > 0 then
				local engine = Engine.new(nil, true)
				engine.role.build(Content, Source, Policy, function()
					return 0
				end, layout.id, 1776)
				offLand(engine, layout.id, layout.spawns, errors)
				checked += 1
			end
		end
		assert(checked > 0, "role layouts with spawns")
		assert(#errors == 0, table.concat(errors, "\n"))
	end,
}
