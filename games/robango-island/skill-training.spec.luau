--!strict
local Training = require("../../genres/survival-coop/module/SkillTraining")
local Text = require("../../genres/survival-coop/module/CharacterText")
local Content: any = require("./src/shared/SurvivalContent")
require("./PackText.fixture") -- installs the strings.csv lookup the genre text tables read

-- Every guide before g33 done: the HUD line is g33's first step, learn processing_2.
local function beforeLeather(): { [string]: boolean }
	local done = {}
	for _, guide in Content.guides do
		done[guide.id] = guide.id ~= "rw.g33.first-leather"
	end
	return done
end

return {
	["training count follows the shipped proficiency curve"] = function()
		local p = Content.progressionPolicy.tree
		assert(
			Training.actions(p, { level = 0, xp = 0 }, 3) == 5,
			"processing rank two needs 5 actions from zero (fun-first curve)"
		)
		assert(Training.actions(p, { level = 1, xp = 0 }, 3) == 4, "first action already earned")
		assert(Training.actions(p, { level = 3, xp = 0 }, 3) == 0, "eligible node needs no practice")
		assert(Training.actions(p, { level = 0, xp = 0 }, 6) == 16, "rank three training cost remains explicit")
	end,
	["HUD guide line names the practice a proficiency-gated skill step needs"] = function()
		local ch = {
			level = 12,
			points = 200,
			definitions = beforeLeather(),
			mastery = { processing = { level = 1, xp = 0 } },
		}
		local line = Text.guideObjective("en-us", Content, ch, {}, true)
		assert(
			line and string.find(line, "Practice 4 more times first", 1, true),
			"gated learn names the practice: " .. tostring(line)
		)
		local ko = Text.guideObjective("ko-kr", Content, ch, {}, true)
		assert(ko and string.find(ko, "4회 더 연습", 1, true), "korean line: " .. tostring(ko))
		ch.mastery.processing.level = 3
		local ready = Text.guideObjective("en-us", Content, ch, {}, true)
		assert(
			ready and not string.find(ready, "Practice", 1, true),
			"eligible learn has no practice line: " .. tostring(ready)
		)
	end,
}
