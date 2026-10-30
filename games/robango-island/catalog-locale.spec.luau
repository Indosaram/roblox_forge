--!strict
-- text audit: the Korean UI showed catalog English (skills sheet effect "carcass meat extraction",
-- NPC names "Marit", the rescued survivor's lines, two dinosaur names). Every pack row the client
-- reads by a content.yml id must carry Korean: skill node effects (skills.<node>), skill categories,
-- wildlife and entity names, NPC names and every RECONSTRUCTED catalog line. A ko-kr cell that is
-- the English text, or holds no Hangul while the English has words, is untranslated.
local fs = require("@lune/fs")
local Strings = require("../../core/infra/localization/Strings")
local PackText = require("./src/shared/PackText")
local Content: any = require("./src/shared/SurvivalContent")
local HudLocale = require("../../genres/survival-coop/module/SurvivalHUDLocale")
local WildlifeNames = require("../../genres/survival-coop/module/WildlifeNames")
require("./PackText.fixture")

local rows = PackText.fromCsvRows(Strings.parseCsv(fs.readFile("games/robango-island/locale/strings.csv")).rows)
local byKey: { [string]: any } = {}
for _, row in rows do
	byKey[row.key] = row
end

-- Text the player would read as English in the Korean UI, or nil.
local function untranslated(row: any): string?
	if not string.find(row.en, "%a%a%a") then
		return nil -- symbols, numbers, format strings
	end
	if row.ko == row.en or not string.find(row.ko, "[\234-\237][\128-\191][\128-\191]") then
		return row.ko
	end
	return nil
end

local function check(keys: { string }, label: string)
	local bad: { string } = {}
	for _, key in keys do
		local row = byKey[key]
		if not row then
			table.insert(bad, key .. " (no row)")
		elseif untranslated(row) then
			table.insert(bad, key .. " = " .. row.ko)
		end
	end
	assert(#bad == 0, label .. " untranslated:\n" .. table.concat(bad, "\n"))
end

return {
	["every skill node effect and category the skills sheet reads has Korean"] = function()
		local keys, categories = {}, {}
		for _, node in Content.skillNodes do
			table.insert(keys, "skills." .. node.id)
			categories[node.category] = true
		end
		for category in categories do
			table.insert(keys, "skills." .. category)
		end
		assert(#keys >= 84, #keys .. " skill keys")
		check(keys, "skills")
		-- The sheet's own lookup returns that Korean text for the reported node.
		assert(HudLocale.text("ko-kr", "skills.butchering_1") == "사체에서 고기 얻기", "butchering_1 effect")
	end,
	["every wildlife species name is Korean"] = function()
		local keys = {}
		for _, creature in Content.wildlife do
			table.insert(keys, "wildlife_" .. string.gsub(creature.id, "%-", "_"))
			local ko = WildlifeNames.name("ko-kr", creature.id)
			assert(string.find(ko, "[\234-\237]"), creature.id .. " shows " .. ko)
		end
		check(keys, "wildlife")
	end,
	["no catalog or NPC row ships English in its ko-kr column"] = function()
		local keys = {}
		for _, row in rows do
			local catalog = row.context == "RECONSTRUCTED Robango catalog source"
				or string.sub(row.context, 1, 7) == "entity "
				or string.sub(row.key, 1, 4) == "npc."
			if catalog then
				table.insert(keys, row.key)
			end
		end
		assert(#keys > 300, #keys .. " catalog rows")
		check(keys, "catalog")
	end,
}
