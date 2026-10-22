--!strict
local GatheringClient = require("./GatheringClient")

return {
	["gather label follows the locale prefix and defaults to English"] = function()
		assert(GatheringClient.actionText("ko-kr") == "채집하기", "korean")
		assert(GatheringClient.actionText("en-us") == "Gather", "english")
		assert(GatheringClient.actionText(nil) == "Gather", "no locale")
	end,
	["a gather still pending is labelled as collecting, not as a fresh gather"] = function()
		assert(GatheringClient.actionText("ko-kr", true) == "채집 중...", "ko busy")
		assert(GatheringClient.actionText("en-us", true) == "Collecting...", "en busy")
		assert(GatheringClient.actionText("en-us", false) == "Gather", "idle")
	end,
	["refused gathers explain the reason in the player's locale"] = function()
		local refused = function(reason: string, requirement: any?)
			return { ok = false, reason = reason, data = { status = "rejected", requirement = requirement } }
		end
		assert(
			GatheringClient.refusalText("en-us", refused("LEVEL_LOCKED", { level = 30 })) == "Requires level 30",
			"en level"
		)
		assert(
			GatheringClient.refusalText("ko-kr", refused("LEVEL_LOCKED", { level = 30 })) == "레벨 30 필요",
			"ko level"
		)
		local names = { ["starter-axe"] = "Starter Axe" }
		local tool = GatheringClient.refusalText("en-us", refused("TOOL_UNAVAILABLE", { tool = "starter-axe" }), names)
		assert(tool == "Requires Starter Axe (equip it)", tostring(tool))
		assert(GatheringClient.refusalText("en-us", refused("TOOL_UNAVAILABLE")) == "Equip the right tool", "no detail")
		assert(GatheringClient.refusalText("en-us", refused("ODD")) == "Cannot gather (ODD)", "unknown still visible")
		assert(GatheringClient.refusalText("en-us", { ok = true, data = { status = "confirmed" } }) == nil, "success")
	end,
}
