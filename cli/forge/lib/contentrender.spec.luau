--!strict
local fs = require("@lune/fs")
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
			(process.env.TEMP or process.env.TMP or "C:/Windows/Temp")
				.. "/forge-content-render-"
				.. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
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
