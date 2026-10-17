--!strict
local TamingPanel = require("./TamingPanel")

return {
	["text falls back to English and fills the argument"] = function()
		assert(TamingPanel.text("en", "tame_remaining", "1:30") == "Ready in 1:30", "english")
		assert(TamingPanel.text("ko-kr", "tame_remaining", "1:30") == "1:30 후 준비", "korean")
		assert(TamingPanel.text("en", "no-such-key") == "no-such-key", "unknown key falls back to the key")
	end,
	["species names come from wildlife strings with the id as fallback"] = function()
		assert(TamingPanel.species("en", "ridge-strider") == "Ridge Strider", "known species")
		assert(TamingPanel.species("ko", "ridge-strider") == "능선걸음이", "korean species")
		assert(TamingPanel.species("en", "mystery") == "mystery", "unknown species")
	end,
	["pen label counts down and reads Ready at zero"] = function()
		assert(TamingPanel.clock(61000) == "1:01", "clock")
		assert(TamingPanel.clock(1) == "0:01", "rounds up to a whole second")
		assert(TamingPanel.pen("en", 0) == "Ready", "ready")
		assert(TamingPanel.pen("en", 90000) == "Ready in 1:30", "remaining")
	end,
	["gauge line shows species and level over max in both locales"] = function()
		local gauge = { species = "ridge-strider", level = 60, max = 100 }
		assert(TamingPanel.gauge("en", gauge) == "Stun gauge: Ridge Strider 60/100", "english")
		assert(TamingPanel.gauge("ko", gauge) == "기절 게이지: 능선걸음이 60/100", "korean")
		assert(TamingPanel.gauge("en", { level = 3, max = 4 }) == "Stun gauge: 3/4", "unknown species omitted")
	end,
	["refusals map to localized messages and success is empty"] = function()
		assert(TamingPanel.refusal("en", { ok = true }) == "", "ok")
		assert(
			TamingPanel.refusal("en", { ok = false, reason = "NO_FEED_ITEM" }) == "That did not work. Try again.",
			"failure"
		)
		assert(TamingPanel.refusal("en", { ok = false, reason = "CHARGE_PENDING" }):find("Saving") ~= nil, "pending")
	end,
}
