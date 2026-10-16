--!strict
local fs = require("@lune/fs")
local tempdir = require("./tempdir")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Content = require("../../../core/domain/survival/Content")
local Capability = require("../../../core/domain/survival/Capability")
local render = require("./contentrender")
local command = require("../commands/content")
local generate = require("./genregenerate")

local function fixture(): any
	return {
		survival_content = 1,
		rules = table.clone(Content.RULES),
		limits = table.clone(Content.DEFAULT_LIMITS),
		items = { { id = "berry", name = "Berry", stackMax = 10, weightMilli = 100 } },
	}
end

return {
	["skills content renders a typed skills table and its absence changes nothing"] = function()
		local plain = assert(render.build(fixture(), "crafting"))
		assert(not string.find(plain.content, "SkillGrant", 1, true), "no skills section, no skills types")
		local raw = fixture()
		local disciplines = {}
		for _, id in { "f", "e", "d", "c", "b", "a" } do
			table.insert(disciplines, { id = id, thresholds = { 5, 20 } })
		end
		raw.skills = { baseStep = 1, disciplines = disciplines }
		raw.nodes = {
			{
				id = "bush",
				respawnMillis = 1000,
				harvest = { { item = "berry", quantity = 1 } },
				skill = { id = "b", xp = 3 },
			},
		}
		local rendered = assert(render.build(raw, "crafting"))
		local decoded = luau.load(rendered.content)()
		assert(#decoded.skills.disciplines == 6 and decoded.skills.disciplines[1].id == "a", "sorted skills ship")
		assert(decoded.skills.disciplines[1].thresholds[2] == 20, "thresholds ship")
		assert(decoded.nodes[1].skill.xp == 3, "node grant ships")
		assert(string.find(rendered.content, "skills: Skills?", 1, true), "generated type carries skills")
		local repeated = assert(render.build(raw, "crafting"))
		assert(repeated.content == rendered.content, "skills render byte-identical")
		raw.skills.disciplines[1].thresholds = { 20, 5 }
		local refused, errors = render.build(raw, "crafting")
		assert(refused == nil and #errors > 0, "invalid skills never render")
	end,
	["legacy content preserves absent optional values and current capability payload"] = function()
		local rendered = render.build(fixture(), "crafting")
		assert(rendered ~= nil, "legacy fixture renders")
		local decoded = luau.load(rendered.content)()
		assert(decoded.vitals == nil and decoded.items[1].foodEffects == nil, "optional values stay absent")
		local descriptor = Capability.describe("crafting")
		assert(decoded.capability.actionVersion == descriptor.actionVersion, "current action version ships")
		assert(decoded.capability.saveVersion == descriptor.saveVersion, "current save version ships")
		assert(#decoded.capability.actions == #descriptor.actions, "all current actions ship")
		for index, action in descriptor.actions do
			assert(decoded.capability.actions[index] == action, "canonical action ordering ships")
		end
		for index, feature in descriptor.features.implemented do
			assert(decoded.capability.features.implemented[index] == feature, "implemented capability ships")
		end
		assert(
			#decoded.capability.features.implemented == #descriptor.features.implemented,
			"no invented capability ships"
		)
		local repeated = assert(render.build(fixture(), "crafting"))
		assert(repeated.content == rendered.content, "same content and capability render identical bytes")
	end,
	["food and vitals codegen retains machine values and generated types"] = function()
		local root = generate.absolute(
			tempdir.root() .. "/forge-content-render-" .. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
		)
		local packDir = root .. "/fixture"
		local ok, reason = xpcall(function()
			generate.ensureDir(packDir)
			local raw = fixture()
			raw.vitals = { fatigueMilliPerAction = 0 }
			raw.items[1].foodEffects = { hungerMilli = 12345, healthMilli = 2000, fatigueMilli = 3000 }
			fs.writeFile(packDir .. "/content.yml", serde.encode("yaml", raw))
			assert(command.codegen("fixture", { packsDir = root }), "real codegen succeeds")
			local path = packDir .. "/src/shared/SurvivalContent.luau"
			local first = fs.readFile(path)
			local decoded = luau.load(first)()
			assert(decoded.vitals.hungerMillisPerUnit == 18000, "resolved hunger default ships")
			assert(decoded.vitals.starvationMillisPerUnit == 5000, "resolved starvation default ships")
			assert(decoded.vitals.restMilliPerSecond == 2000, "resolved rest default ships")
			assert(decoded.vitals.fatigueMilliPerAction == 0, "zero override ships")
			local food = decoded.items[1].foodEffects
			assert(food.hungerMilli == 12345 and food.healthMilli == 2000 and food.fatigueMilli == 3000, "food ships")
			assert(command.codegen("fixture", { packsDir = root }), "repeat codegen succeeds")
			assert(fs.readFile(path) == first, "codegen bytes deterministic")
			fs.writeFile(
				packDir .. "/consumer.luau",
				[[--!strict
local Catalog = require("./src/shared/SurvivalContent")
local food: Catalog.FoodEffects? = Catalog.items[1].foodEffects
local vitals: Catalog.VitalsConfig? = Catalog.vitals
if food then
	local value: number = food.hungerMilli + food.healthMilli + food.fatigueMilli
	assert(value >= 0)
end
if vitals then
	local value: number = vitals.hungerMillisPerUnit + vitals.starvationMillisPerUnit + vitals.restMilliPerSecond + vitals.fatigueMilliPerAction
	assert(value >= 0)
end
]]
			)
			local result =
				process.exec("luau-lsp", { "analyze", "--platform=standard", path, packDir .. "/consumer.luau" })
			assert(result.ok, result.stdout .. result.stderr)
		end, debug.traceback)
		if fs.isDir(root) then
			fs.removeDir(root)
		end
		assert(ok, tostring(reason))
	end,
}
