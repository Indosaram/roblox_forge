--!strict
local PetRing = require("./PetRing")
-- Installs the strings.csv lookup the genre text tables read (the client installs the Strings table).
local _packText = (require :: any)("../../../games/robango-island/PackText.fixture")

local content: any = {
	wildlifeDetails = {
		{ id = "gallimimus", level = 6, health = 120, captureClass = "basic", mount = { enabled = true } },
		{ id = "compsognathus", level = 1, health = 20, captureClass = "basic", mount = { enabled = false } },
		{ id = "tyrannosaurus", level = 40, health = 900, captureClass = "never", mount = { enabled = false } },
	},
}

local function ids(tokens: { PetRing.Token }): string
	local out = {}
	for _, token in tokens do
		table.insert(out, token.id)
	end
	return table.concat(out, ",")
end

return {
	["ring verbs follow the pet: ride only for a saddled mount, dismount while riding, at most six"] = function()
		local pet = { id = "p", saddle = true }
		assert(ids(PetRing.verbs("en", pet, false, true)) == "ride,stay,feed,rename,recall,release", "mount")
		assert(
			ids(PetRing.verbs("en", { id = "p" }, false, true)) == "saddle,stay,feed,rename,recall,release",
			"saddle"
		)
		assert(ids(PetRing.verbs("en", pet, false, false)) == "stay,feed,rename,recall,release", "not rideable")
		assert(
			ids(PetRing.verbs("en", { id = "p", stay = true }, false, false)) == "follow,feed,rename,recall,release",
			"staying"
		)
		assert(ids(PetRing.verbs("en", pet, true, true)) == "dismount,feed,rename", "riding")
		local release = PetRing.verbs("en", pet, false, false)[5]
		assert(release.verb == "release:p", "release names the pet")
		assert(PetRing.verbs("ko-kr", pet, false, true)[1].label == "올라타기", "korean label")
	end,
	["shell fan arc opens upward, centred over the target, 40 degrees apart"] = function()
		local spots = PetRing.arc(3, 100, 200, 400)
		local r = PetRing.ARC_RADIUS * 400
		assert(math.abs(spots[2].x - 100) < 1e-6 and math.abs(spots[2].y - (200 - r)) < 1e-6, "middle straight up")
		assert(spots[1].x < 100 and spots[3].x > 100, "left to right")
		for _, spot in spots do
			assert(spot.y < 200, "every token above the target")
			assert(math.abs(math.sqrt((spot.x - 100) ^ 2 + (spot.y - 200) ^ 2) - r) < 1e-6, "on the radius")
		end
		local six = PetRing.arc(6, 0, 0, 360)
		local drop = math.sin(math.rad(10)) * PetRing.ARC_RADIUS * 360
		assert(math.abs(six[1].y - drop) < 1e-6 and math.abs(six[6].y - drop) < 1e-6, "six span 200 degrees")
	end,
	["downed means a tameable living target at a quarter health or less"] = function()
		local tameable = { gallimimus = true, compsognathus = true }
		assert(PetRing.downed(content, tameable, "gallimimus", 30000), "at 25%")
		assert(not PetRing.downed(content, tameable, "gallimimus", 30001), "above 25%")
		assert(not PetRing.downed(content, tameable, "gallimimus", 0), "dead")
		assert(not PetRing.downed(content, tameable, "tyrannosaurus", 1), "never capturable")
		assert(not PetRing.downed(content, {}, "gallimimus", 100), "not in the tameable list")
		assert(not PetRing.downed(content, tameable, "gallimimus", nil), "unknown health")
	end,
	["capture card: success shows level and riding, failure shows the reason"] = function()
		local won = PetRing.card("en", content, { ok = true, data = { captured = true } }, "gallimimus")
		assert(won.success and won.title == "Caught!", "success title")
		assert(table.find(won.lines, "Lv 6") and table.find(won.lines, "Can carry a rider"), "level and riding")
		local small = PetRing.card("ko-kr", content, { ok = true, data = { captured = true } }, "compsognathus")
		assert(table.find(small.lines, "탈 수 없어요"), "korean, not rideable")
		local missed = PetRing.card("en", content, { ok = true, data = { captured = false } }, "gallimimus")
		assert(not missed.success and missed.lines[2] == "Knock it down again and retry.", "roll failed")
		local refused = PetRing.card("en", content, { ok = false, reason = "NO_ROPE" }, "gallimimus")
		assert(not refused.success and refused.lines[2] == "Bring Capture Rope", "refusal reason")
	end,
	["refusals of the ring commands read as player text"] = function()
		assert(PetRing.refusal("en", { ok = true }) == "", "ok")
		assert(
			PetRing.refusal("en", { ok = false, reason = "NOT_RIDEABLE" }) == "This animal cannot be ridden.",
			"not rideable"
		)
		assert(PetRing.refusal("ko-kr", { ok = false, reason = "TOO_FAR" }) ~= "", "range uses the taming text")
		assert(PetRing.refusal("en", { ok = false, reason = "NAME_REJECTED" }) == "That name cannot be used.", "name")
	end,
}
