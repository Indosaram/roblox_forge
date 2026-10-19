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
		assert(
			TamingPanel.refusal("en", { ok = false, reason = "NO_CAPTURE_TOOL" }) == "Craft a Hobble Bola first",
			"no tool"
		)
		assert(
			TamingPanel.refusal("ko", { ok = false, reason = "NO_CAPTURE_TOOL" })
				== "속박 볼라를 먼저 만드세요",
			"no tool ko"
		)
		assert(TamingPanel.refusal("en", { ok = false, reason = "COOLDOWN" }) == "", "cooldown is silent")
		assert(TamingPanel.refusal("en", { ok = false, reason = "OUT_OF_REACH" }):find("Too far") ~= nil, "reach")
		assert(TamingPanel.refusal("en", { ok = false, reason = "GAUGE_NOT_FULL" }):find("stun") ~= nil, "not full")
	end,
	["prompt stuns until the gauge for that wild id is full, then captures"] = function()
		local function pick(locale: string, gauge: any, wildId: string): string
			local action, text = TamingPanel.promptAction(locale, gauge, wildId)
			return action .. "|" .. text
		end
		assert(pick("en", nil, "ridge-01") == "survival-coop:tame-hit|Stun", "no gauge stuns")
		local partial = { wildId = "ridge-01", level = 75, max = 100 }
		assert(pick("ko", partial, "ridge-01") == "survival-coop:tame-hit|기절시키기", "partial gauge stuns")
		local full = { wildId = "ridge-01", level = 100, max = 100 }
		assert(pick("en", full, "ridge-01") == "survival-coop:tame-capture|Capture", "full gauge captures")
		local flagged = { wildId = "ridge-01", level = 0, max = 100, full = true }
		assert(pick("ko", flagged, "ridge-01") == "survival-coop:tame-capture|포획하기", "full flag captures")
		local other = { wildId = "fen-02", level = 100, max = 100 }
		assert(pick("en", other, "ridge-01") == "survival-coop:tame-hit|Stun", "another animal's full gauge")
	end,
	["capture outcomes report the catch or the escape"] = function()
		local capture = "survival-coop:tame-capture"
		local caught = { ok = true, data = { captured = true, species = "ridge-strider" } }
		assert(TamingPanel.outcome("en", capture, caught) == "Captured Ridge Strider! It is in your pen.", "caught")
		local escaped = { ok = true, data = { captured = false, retry = true } }
		assert(TamingPanel.outcome("en", capture, escaped):find("broke free") ~= nil, "escaped")
		assert(
			TamingPanel.outcome("en", "survival-coop:tame-hit", { ok = true, data = { level = 25 } }) == "",
			"hit ok"
		)
	end,
}
