--!strict
-- p134 v74 phone acceptance (SM-N981N, ko-kr, touch, 2400x1080 landscape) defects.
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")

-- The live onboarding role (RoleWorld + OpeningDirector) on the headless engine.
local function onboarding(): (any, any)
	local engine = Engine.new(nil, true)
	local world = engine.role.build(Content, Source, Policy, function()
		return 0
	end, "rw.onboarding", 1776)
	return engine, world
end

local function prompts(engine: any, name: string): { any }
	local out = {}
	for _, item in engine.parts do
		if item.ClassName == "ProximityPrompt" and item.Name == name and not item.destroyed then
			table.insert(out, item)
		end
	end
	return out
end

return {
	-- #2: tapping the stake's 'Pull' did nothing (a hidden hold; SurvivalHUD's interact token only
	-- fires HoldDuration 0 prompts on a tap), and after a pull the token greyed out until the player
	-- walked: the next stake (8-9 studs on) was outside the 8-stud prompt reach.
	["v74 #2: a tap pulls a stake, and from a pulled stake the next one is in reach"] = function()
		local engine, world = onboarding()
		local stakes = prompts(engine, "ForgeOpeningStake")
		assert(#stakes == 3, "three stake prompts, got " .. #stakes)
		for _, prompt in stakes do
			assert(prompt.HoldDuration == 0, "a tap pulls (no hidden hold): " .. tostring(prompt.HoldDuration))
		end
		local farthest = 0
		for index, stake in world.opening.stakes do
			local nearestOther = math.huge
			for other, part in world.opening.stakes do
				if other ~= index then
					nearestOther = math.min(nearestOther, (part.Position - stake.Position).Magnitude)
				end
			end
			farthest = math.max(farthest, nearestOther)
		end
		for _, prompt in stakes do
			assert(
				prompt.MaxActivationDistance >= farthest + 1,
				string.format("next stake %.1f studs on, reach %s", farthest, tostring(prompt.MaxActivationDistance))
			)
			-- The server still accepts a pull from there (SurvivalWorld.nearPart: 12 studs).
			assert(prompt.MaxActivationDistance <= 12, "inside the server reach")
		end
		world.destroy()
	end,
}
