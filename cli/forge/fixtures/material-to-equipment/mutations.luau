--!strict
-- Mutations run in memory, leaving shared working files untouched.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Tree = require("../../../../core/domain/progression/SkillTree")
local Materials = require("../../../../core/domain/crafting/MaterialGrowth")
local Extension = require("../../../../genres/survival-coop/module/ProgressionExtension")
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local Rng = require("../../../../core/domain/random/Rng")
local Policy = require("./policy")
local units = {
	{
		path = "core/domain/progression/SkillTree",
		spec = "cli/forge/fixtures/material-to-equipment/SkillTree.spec",
		key = "SkillTree",
		guards = {
			"state.mastery[node.category].level < node.proficiency",
			"state.sp < node.cost",
			"not state.paid[prerequisite]",
			"state.version ~= version",
			"inCombat or activeJobs > 0",
			"state.paid[id]",
		},
	},
	{
		path = "core/domain/crafting/MaterialGrowth",
		spec = "cli/forge/fixtures/material-to-equipment/MaterialGrowth.spec",
		key = "MaterialGrowth",
		guards = {
			"counts[required.item] ~= required.quantity",
			"input.level < (detail.primaryMaterialLevel or 0)",
			"budget < effect.value",
			"input.sourceSpeciesId ~= detail.sourceSpeciesId",
		},
	},
	{
		path = "genres/survival-coop/module/ProgressionExtension",
		spec = "cli/forge/fixtures/material-to-equipment/ProgressionExtension.spec",
		key = "ProgressionExtension",
		guards = {
			'cancelled or not state.paid[category .. "_6"]',
			"not categoryMatches",
			"slot ~= 1 and slot ~= 2",
			"not eligible",
			"not state.paid[node]",
			"not edible or policy.feed[material.item]",
			"not completed[prerequisite]",
			"facts.coins < (row.cost or 0)",
			"facts.station ~= row.station or facts.stationTier < (row.stationTier or 1)",
			"completed[id]",
		},
	},
}

local function resolve(path: string, overrides: any): any
	for _, name in { "SkillTree", "MaterialGrowth", "ProgressionExtension" } do
		if string.match(path, name .. "$") then
			return overrides[name]
				or ({ SkillTree = Tree, MaterialGrowth = Materials, ProgressionExtension = Extension })[name]
		end
	end
	if string.match(path, "SurvivalContent$") then
		return Content
	elseif string.match(path, "Rng$") then
		return Rng
	elseif string.match(path, "policy$") then
		return Policy
	end
	error("unmapped mutation dependency " .. path)
end

local killed = 0
for _, unit in units do
	local source = fs.readFile(unit.path .. ".luau")
	local spec = fs.readFile(unit.spec .. ".luau")
	for _, guard in unit.guards do
		local start, finish = string.find(source, guard, 1, true)
		assert(start and finish, "mutation target exists: " .. guard)
		local mutant = string.sub(source, 1, start - 1) .. "false" .. string.sub(source, finish + 1)
		local overrides: any = {}
		local function dependency(path)
			return resolve(path, overrides)
		end
		overrides[unit.key] = luau.load(mutant, { environment = { require = dependency } })()
		local tests = luau.load(spec, { environment = { require = dependency } })()
		local detected = false
		for _, test in tests do
			if not pcall(test) then
				detected = true
			end
		end
		assert(detected, "SURVIVED " .. unit.key .. " " .. guard)
		killed += 1
		print("KILLED " .. unit.key .. " " .. guard)
	end
end
print("mutation proof: " .. tostring(killed) .. " killed, 0 survived")
