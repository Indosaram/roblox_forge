--!strict
-- Specs for the generated quality profile: it must validate, declare only the
-- starter tier, be byte-identical for the same input, and name the pack's own
-- loop rather than a genre template's.

local serde = require("@lune/serde")
local qualityscaffold = require("./qualityscaffold")
local qualityprofile = require("./qualityprofile")
local registryLib = require("./genreregistry")

local function decode(pack: string, spec: any): any
	local document = serde.decode("yaml", qualityscaffold.profile(pack, spec))
	local profile = qualityprofile.parse(document)
	assert(profile ~= nil, "the generated profile must validate")
	return profile
end

return {
	["a generated profile validates and declares only the starter tier"] = function()
		local profile = decode("starter-pack", nil)
		assert(profile.pack == "starter-pack", "the profile names its pack")
		assert(profile.tier == "starter", "generation may only declare the starter tier")
		assert(not qualityprofile.requiresEvaluation(profile), "a starter profile needs no evaluation receipt")
		assert(profile.provisionalTargets == true, "generated targets are provisional")
		-- Every canonical goal keeps the bounds the schema enforces.
		local goals: { [string]: any } = {}
		for _, goal in profile.firstPlayGoals do
			goals[goal.id] = goal
		end
		for _, bound in qualityprofile.REQUIRED_GOAL_BOUNDS do
			local goal = goals[bound.id]
			assert(goal ~= nil, "missing canonical goal " .. bound.id)
			assert(
				goal.withinMinutes ~= nil and goal.withinMinutes <= bound.withinMinutes,
				"goal " .. bound.id .. " relaxed its deadline"
			)
			assert(
				goal.players ~= nil and goal.players >= bound.minPlayers,
				"goal " .. bound.id .. " weakened its roster"
			)
		end
	end,

	["the profile is byte-identical for the same input"] = function()
		assert(
			qualityscaffold.profile("stable-pack", nil) == qualityscaffold.profile("stable-pack", nil),
			"generation must be deterministic"
		)
	end,

	["the loop goal names the actions the pack's own spec drives"] = function()
		local registry = assert(registryLib.discover())
		local spec = registry.packages["grow-harvest"].spec
		local actions = qualityscaffold.loopActions(spec)
		assert(#actions > 0, "a declared golden path yields action names")
		local description = qualityscaffold.loopDescription(actions)
		for _, action in actions do
			assert(string.find(description, action, 1, true) ~= nil, "the loop goal names " .. action)
		end
		-- The description reaches the emitted document, not only the helper.
		local text = qualityscaffold.profile("loop-pack", spec)
		assert(string.find(text, description, 1, true) ~= nil, "the emitted profile carries the derived loop text")
	end,

	["a spec with no golden path still yields a valid profile"] = function()
		local profile = decode("bare-pack", { qa = {} })
		assert(profile.tier == "starter", "a bare spec still declares starter")
		assert(
			string.find(qualityscaffold.loopDescription({}), "primary loop", 1, true) ~= nil,
			"an absent golden path uses the genre-neutral loop text"
		)
	end,
}
