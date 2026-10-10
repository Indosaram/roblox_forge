--!strict
local Audio = require("./SurvivalAudio")
return {
	["only uploaded IDs and exact shipped builtin paths are accepted"] = function()
		assert(Audio.contentId("rbxassetid://123") == "rbxassetid://123", "synthetic parser fixture")
		for _, filename in
			{
				"action_footsteps_plastic.mp3",
				"action_get_up.mp3",
				"action_jump.mp3",
				"action_jump_land.mp3",
				"action_swim.mp3",
				"action_falling.ogg",
			}
		do
			local source = "rbxasset://sounds/" .. filename
			assert(Audio.contentId(source) == source, "shipped source accepted")
		end
		for _, source in
			{
				"rbxasset://sounds/invented.wav",
				"rbxasset://sounds/../sounds/action_swim.mp3",
				"rbxasset://sounds/action_swim.mp3?alternate=1",
				"rbxasset://sounds/oof.ogg",
			}
		do
			assert(Audio.contentId(source) == nil, "only exact reviewed paths accepted")
		end
		for _, value in
			{ "", "rbxassetid://0", "rbxasset://forge/pack/local.wav", "C:/local.wav", "https://example.com/a.wav" }
		do
			assert(Audio.contentId(value) == nil, "unsupported source rejected")
		end
	end,
	["committed results map once and reservations never sound like completion"] = function()
		local cues = {}
		local audio = Audio.new(function(cue, active)
			if active then
				table.insert(cues, cue)
			end
		end)
		for _, verb in { "gather", "craft-complete", "food", "attack" } do
			local request = { action = "survival-coop:" .. verb, requestId = verb, sessionEpoch = 0 }
			audio.result(request, { ok = false, stateVersion = 1 })
			audio.result(request, { ok = true, data = { status = "pending" } })
			if verb == "gather" then
				audio.result(request, { ok = true, stateVersion = 1, data = { status = "pending" } })
			end
			local result = { ok = true, stateVersion = 1, data = { status = "confirmed" } }
			audio.result(request, result)
			audio.result(request, result)
		end
		audio.result({ action = "survival-coop:craft-reserve", requestId = "reserve" }, { ok = true, stateVersion = 2 })
		audio.result({ action = "survival-coop:rest", requestId = "rest" }, { ok = true, stateVersion = 3 })
		assert(table.concat(cues, ",") == "gather,craft,eat,hit", "confirmed cue mapping and duplicate suppression")
		audio.destroy()
		audio.result({ action = "survival-coop:food", requestId = "after" }, { ok = true, stateVersion = 3 })
		assert(#cues == 4, "destroy silences future results")
	end,
	["authoritative rest edges ignore stale snapshots and stop on death"] = function()
		local events = {}
		local audio = Audio.new(function(cue, active)
			table.insert(events, cue .. ":" .. tostring(active))
		end)
		local function receive(revision, resting, health)
			audio.receive({
				revision = revision,
				snapshots = {
					["survival-coop"] = { vitals = { resting = resting, healthMilli = health } },
				},
			})
		end
		receive(1, false, 100)
		receive(2, true, 100)
		receive(1, false, 100)
		receive(2, false, 100)
		receive(3, true, 0)
		assert(table.concat(events, ",") == "ambient:true,rest:true,rest:false", "state edge cues")
		audio.destroy()
		local count = #events
		audio.destroy()
		receive(4, true, 100)
		assert(#events == count, "idempotent cleanup")
	end,
}
