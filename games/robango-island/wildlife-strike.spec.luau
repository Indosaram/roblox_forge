--!strict
-- Every aggressive species in the live content must be able to land a strike on a player it is
-- touching. Positions are what the engine binding observes: the creature's HumanoidRootPart (the
-- real DinosaurRig root, grounded) and the player's HumanoidRootPart (R15: 2x2x1, centre 3 studs
-- above the floor). Time is an explicit clock stepped through warn and telegraph.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Archetype = require("../../core/domain/survival/Archetype")
local Wildlife = require("../../genres/survival-coop/module/Wildlife")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")

local PLAYER_ROOT = { size = { x = 2, y = 2, z = 1 }, centreY = 3 }

local DinosaurRig = luau.load(fs.readFile("genres/survival-coop/module/DinosaurRig.luau"), {
	environment = {
		Instance = roblox.Instance,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		Enum = roblox.Enum,
	},
})()

-- The root size SurvivalWorld gives this species' rig: its render envelope, else the archetype rig.
local function rootSize(content: any, id: string, behavior: string): Wildlife.Position
	local engine = Archetype.engine(behavior) or "hunter"
	local envelope: any, visual: any = nil, nil
	for _, detail in content.wildlifeDetails or {} do
		if detail.id == id then
			engine, visual = detail.id, detail.visual
			local size = detail.renderEnvelope
			envelope = if size then roblox.Vector3.new(size.x, size.y, size.z) else nil
			break
		end
	end
	local model = DinosaurRig.new(engine, id, roblox.Vector3.zero, roblox.Instance.new("Folder"), envelope, visual)
	local size = model:FindFirstChild("HumanoidRootPart").Size
	return { x = size.X, y = size.Y, z = size.Z }
end

return {
	["every aggressive species strikes a player its body is touching"] = function()
		local engine = Engine.new(true)
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.a1.s1", 1776)
		local content, catalog = world.roleContent, world.roleWildlife.catalog
		local checked, missed = 0, {}
		for _, definition in content.wildlife do
			local archetype = assert(Archetype.get(definition.behavior), definition.id)
			if archetype.engine ~= "hunter" then
				continue
			end
			local body = rootSize(content, definition.id, definition.behavior)
			-- Worst touching pose: nose to the player along its longest horizontal axis, bodies in contact.
			local gap = math.max(body.x, body.z) / 2 + PLAYER_ROOT.size.z / 2
			local observation: Wildlife.Observation = {
				position = { x = 0, y = body.y / 2, z = 0 },
				actors = { { id = "1", position = { x = gap, y = PLAYER_ROOT.centreY, z = 0 }, alive = true } },
				pathFailed = false,
				lineOfSight = function()
					return true
				end,
				observerStuds = Wildlife.HIBERNATE_STUDS,
				-- Retaliators engage once hit; aggressors ignore it.
				provokedBy = "1",
				body = body,
			}
			local rule = catalog.species[definition.id]
			local state = Wildlife.new(definition.id .. ".1", definition.id, observation.position, catalog)
			local telegraph = assert(definition.telegraphMillis, definition.id)
			local damage: any = nil
			local modes = {}
			for _, now in { 0, telegraph, 2 * telegraph } do
				local intent
				state, intent = Wildlife.step(state, definition, rule, now, observation)
				observation.provokedBy = nil
				table.insert(modes, state.mode)
				damage = damage or intent.damage
			end
			checked += 1
			if not damage or damage.actorId ~= "1" or damage.damageMilli ~= rule.damageMilli then
				table.insert(
					missed,
					string.format(
						"%s(attack=%d body=%gx%gx%g modes=%s)",
						definition.id,
						definition.attackStuds,
						body.x,
						body.y,
						body.z,
						table.concat(modes, ">")
					)
				)
			end
		end
		assert(checked >= 20, "aggressive roster discovered: " .. checked)
		assert(#missed == 0, "touching but never strikes: " .. table.concat(missed, ", "))
		world.destroy()
	end,
	["strike range is measured from the body, not through it"] = function()
		local body = { x = 1, y = 1.5, z = 3 }
		local centre = { x = 0, y = 0.75, z = 0 }
		assert(Wildlife.bodyDistance(centre, body, { x = 0.4, y = 1, z = 0 }) == 0, "inside the body")
		assert(Wildlife.bodyDistance(centre, body, { x = 3.5, y = 0.75, z = 0 }) == 3, "level: past the side")
		assert(Wildlife.bodyDistance(centre, body, { x = 0, y = 4.5, z = 0 }) == 3, "above the body")
		-- Inscribed radius: yaw can never claim reach outside the real body.
		assert(Wildlife.bodyDistance(centre, body, { x = 0, y = 0.75, z = 1.5 }) == 1, "long axis not credited")
	end,
}
