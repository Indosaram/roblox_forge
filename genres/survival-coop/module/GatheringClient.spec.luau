--!strict
local GatheringClient = require("./GatheringClient")

return {
	["gather label follows the locale prefix and defaults to English"] = function()
		assert(GatheringClient.actionText("ko-kr") == "채집하기", "korean")
		assert(GatheringClient.actionText("en-us") == "Gather", "english")
		assert(GatheringClient.actionText(nil) == "Gather", "no locale")
	end,
}
