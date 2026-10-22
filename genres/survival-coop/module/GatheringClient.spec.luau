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
}
