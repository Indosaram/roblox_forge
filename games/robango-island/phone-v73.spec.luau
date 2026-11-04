--!strict
-- p134 v73 phone acceptance (SM-N981N, ko-kr) defects.
local Content = require("./src/shared/SurvivalContent")
local Text = require("../../genres/survival-coop/module/CharacterText")
require("./PackText.fixture") -- installs the strings.csv lookup the genre text tables read

local NAMES = { fiber = "고사리 섬유", ["axe-t1"] = "도끼" }

-- A key named in a hint: a lone capital E/C/B (the PC verbs), or "키" / "key".
local function namesKey(line: string): boolean
	return string.find(line, "%f[%w]E%f[%W]") ~= nil
		or string.find(line, "%f[%w]C%f[%W]") ~= nil
		or string.find(line, "%f[%w]B%f[%W]") ~= nil
		or string.find(line, "키", 1, true) ~= nil
		or string.find(string.lower(line), "key", 1, true) ~= nil
end

return {
	["v73 #1: on touch the first-gather HUD line names no key; PC keeps the E hint"] = function()
		local ch = { level = 3, points = 50, definitions = {}, progress = {} }
		local phone = assert(Text.guideObjective("ko-kr", Content, ch, NAMES, true, true), "a guide line")
		assert(string.find(phone, "고사리 섬유", 1, true), phone)
		assert(not namesKey(phone), "touch line names a key: " .. phone)
		assert(string.find(phone, "누르기", 1, true), "touch wording: " .. phone)
		local en = assert(Text.guideObjective("en-us", Content, ch, NAMES, true, true))
		assert(not namesKey(en), "touch en line names a key: " .. en)
		local pc = assert(Text.guideObjective("ko-kr", Content, ch, NAMES, true))
		assert(string.find(pc, "(다가가서 E)", 1, true), "PC wording unchanged: " .. pc)
		-- Every guide step verb that names a key on PC has a key-free touch row.
		for _, action in { "gather", "craft", "place" } do
			for _, locale in { "en-us", "ko-kr" } do
				local touch = Text.text(locale, "guide_go_" .. action .. "_touch")
				assert(touch ~= "guide_go_" .. action .. "_touch", "touch row for " .. action)
				assert(not namesKey(string.format(touch, "x")), locale .. " " .. action .. ": " .. touch)
			end
		end
	end,
}
