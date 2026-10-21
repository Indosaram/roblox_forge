--!strict
local Selection = require("./SkinSelection")
return {
	["ownership precedes appearance and expiry removes selected subscription skin"] = function()
		local owned, fail = false, false
		local appearance: { skin: string } = { skin = "default" }
		local selector = Selection.new({
			supported = function(skin)
				return skin == "gold"
			end,
			owns = function()
				return owned
			end,
			apply = function(_actor, skin)
				if fail then
					return false
				end
				appearance.skin = skin
				return true
			end,
			clear = function()
				appearance.skin = "default"
				return true
			end,
		})
		assert(selector.select("1", "unknown").reason == "SKIN_UNSUPPORTED", "unknown skin accepted")
		assert(
			selector.select("1", "gold").reason == "SKIN_NOT_OWNED" and appearance.skin == "default",
			"unowned changed appearance"
		)
		owned, fail = true, true
		assert(not selector.select("1", "gold").ok and selector.snapshot("1").skin == nil, "failed apply selected skin")
		fail = false
		assert(selector.select("1", "gold").ok and tostring(appearance.skin) == "gold", "appearance did not change")
		assert(selector.resync("1").ok and tostring(appearance.skin) == "gold", "resync lost appearance")
		owned = false
		assert(
			selector.resync("1").ok and appearance.skin == "default" and selector.snapshot("1").skin == nil,
			"lapsed skin retained"
		)
	end,
}
