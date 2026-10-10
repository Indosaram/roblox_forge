--!strict
-- Specs for the cue policy's result envelope: a HUD dispatch and a world prompt are the
-- same committed outcome, so both must resolve to the action that succeeded and fire the
-- action-bound cue.
--
-- The kit names Roblox globals, so it is loaded as a chunk against a fake engine rather
-- than required: a spec that only wanted the pure policy would otherwise drag `game` and
-- `Instance` into the Lune type check. The same fake engine is what proves playback
-- headlessly — a committed action ends in a `Sound` carrying the declared asset id, and a
-- cue whose asset is missing plays nothing at all.

local fs = require("@lune/fs")
local luau = require("@lune/luau")

-- The genre's declared document, in the same runtime form a pack requires.
local GrowHarvestAudio = require("../../../genres/grow-harvest/module/Audio")

--- One fake engine: `calls` records every Stop/Play a Sound received, `sounds` holds the
--- Sounds themselves, and `folder` is the kit's own cue folder once it creates one.
local function engine(): any
	return { calls = {}, sounds = {}, folder = nil }
end

local function loadKit(fakes: any): any
	local function newInstance(className: string): any
		if className == "Folder" then
			local folder: any = {
				Name = "",
				Parent = nil,
				attributes = {} :: { [string]: any },
				children = {} :: { any },
				SetAttribute = function(self: any, key: string, value: any): ()
					self.attributes[key] = value
				end,
				GetChildren = function(self: any): { any }
					return self.children
				end,
				Destroy = function(self: any): ()
					table.clear(self.children)
				end,
			}
			fakes.folder = folder
			return folder
		end
		local sound: any
		sound = {
			ClassName = className,
			Name = "",
			SoundId = "",
			Looped = false,
			Volume = 0,
			attributes = {} :: { [string]: any },
			SetAttribute = function(self: any, key: string, value: any): ()
				self.attributes[key] = value
			end,
			Stop = function(_self: any): ()
				table.insert(fakes.calls, { cue = sound.Name, soundId = sound.SoundId, event = "Stop" })
			end,
			Play = function(_self: any): ()
				table.insert(fakes.calls, { cue = sound.Name, soundId = sound.SoundId, event = "Play" })
			end,
		}
		table.insert(fakes.sounds, sound)
		return sound
	end
	local player: any = {
		GetAttribute = function(_self: any, _name: string): any
			return nil
		end,
		GetAttributeChangedSignal = function(_self: any, _name: string): any
			return {
				Connect = function(_self: any, _callback: any): any
					return { Disconnect = function(): () end }
				end,
			}
		end,
	}
	local environment: any = {
		Instance = { new = newInstance },
		game = {
			GetService = function(_self: any, name: string): any
				if name == "Players" then
					return { LocalPlayer = player }
				end
				return {}
			end,
		},
	}
	return luau.load(fs.readFile("core/ui-kit/genre/AudioKit.luau"), { environment = environment })()
end

local AudioKit: any = loadKit(engine())

local audio: any = {
	cues = { { key = "cue-attack" } },
	bindings = { { on = "action:pvp-arena:attack", cue = "cue-attack" } },
}

local function controller(extra: any)
	local fired = 0
	local options: any = {
		genre = "pvp-arena",
		audio = audio,
		playback = function()
			fired += 1
		end,
	}
	for key, value in extra do
		options[key] = value
	end
	return AudioKit.policy(options), function(): number
		return fired
	end
end

local M = {}

M["a HUD result envelope carrying packet.action fires the action-bound cue"] = function()
	-- The generated client publishes `{ result = result, action = actionId }`, so the action is
	-- read straight off the packet rather than looked up from a control id it never carries.
	local policy, fired = controller({})
	policy.receive(({ result = { ok = true }, action = "pvp-arena:attack" }) :: any)
	assert(fired() == 1, "the HUD envelope's action must fire its binding")
end

M["a prompt result envelope carrying only a control fires through the control mapping"] = function()
	-- A world prompt publishes `{ result = result, control = controlId }`; the echoed control
	-- resolves to the action it drives.
	local policy, fired = controller({ controlActions = { ["pvp-arena:attack"] = "pvp-arena:attack" } })
	policy.receive(({ result = { ok = true }, control = "pvp-arena:attack" }) :: any)
	assert(fired() == 1, "the prompt envelope's control must resolve to its action")
end

M["a namespaced control id resolves to the action it drives"] = function()
	local policy, fired = controller({ controlActions = { ["pvp-arena:attack-button"] = "pvp-arena:attack" } })
	policy.receive(({ result = { ok = true }, control = "pvp-arena:attack-button" }) :: any)
	assert(fired() == 1, "a control whose id is not the action must resolve through the mapping")
end

M["a refused result fires nothing"] = function()
	local policy, fired = controller({})
	policy.receive(({ result = { ok = false, reason = "RATE_LIMITED" }, action = "pvp-arena:attack" }) :: any)
	assert(fired() == 0, "only a committed success fires a cue")
end

M["the genre's declared document binds each grow-harvest action to its own cue"] = function()
	-- The declaration is the spec's, in its runtime form: a pack names an action and the cue
	-- comes from here, so a binding that stopped resolving is caught by a spec rather than by
	-- silence in a live session.
	local pairs_: { { string } } = {
		{ "grow-harvest:buy-seed", "grow-harvest-buy" },
		{ "grow-harvest:plant", "grow-harvest-plant" },
		{ "grow-harvest:harvest", "grow-harvest-harvest" },
		{ "grow-harvest:sell-held", "grow-harvest-sell" },
	}
	for _, pair in pairs_ do
		local action, cue = pair[1], pair[2]
		local got: { string } = {}
		local policy: any = AudioKit.policy({
			genre = "grow-harvest",
			audio = GrowHarvestAudio,
			playback = function(playedCue: string): ()
				table.insert(got, playedCue)
			end,
		})
		policy.receive(({ result = { ok = true }, action = action }) :: any)
		assert(#got == 1 and got[1] == cue, action .. " must play " .. cue .. ", got " .. table.concat(got, ", "))
	end
end

M["a committed action plays a Sound carrying the declared asset id"] = function()
	local fakes = engine()
	local kit: any = loadKit(fakes).start({
		genre = "grow-harvest",
		audio = GrowHarvestAudio,
		contentIds = { ["grow-harvest-plant"] = "rbxassetid://76044104452678" },
	})
	kit.result("grow-harvest:plant", { ok = true })
	local played = nil
	for _, call in fakes.calls do
		if call.event == "Play" then
			played = call
		end
	end
	assert(played ~= nil, "the committed action must play a sound")
	assert(played.cue == "grow-harvest-plant", "the sound is named for its cue: " .. tostring(played.cue))
	assert(
		played.soundId == "rbxassetid://76044104452678",
		"the sound carries the declared asset id: " .. tostring(played.soundId)
	)
	assert(fakes.folder ~= nil and fakes.folder.Name == "ForgeHudAudio", "the sound lives in the kit's own folder")
end

M["a cue whose asset is not uploaded plays nothing and is recorded as unavailable"] = function()
	-- An unuploaded cue degrades silently: no error, no sound, and the kit's own folder names
	-- what was unavailable so tooling can see it.
	local fakes = engine()
	local kit: any = loadKit(fakes).start({ genre = "grow-harvest", audio = GrowHarvestAudio, contentIds = {} })
	kit.result("grow-harvest:plant", { ok = true })
	for _, call in fakes.calls do
		assert(call.event ~= "Play", "a cue without a content id must not play")
	end
	assert(#kit.missing == 4, "every declared cue without an id is reported: " .. table.concat(kit.missing, ", "))
	assert(
		string.find(fakes.folder.attributes.UnavailableCues, "grow-harvest-plant", 1, true) ~= nil,
		"the folder names the unavailable cue"
	)
end

M["a refused action and an unbound action play nothing"] = function()
	local fakes = engine()
	local kit: any = loadKit(fakes).start({
		genre = "grow-harvest",
		audio = GrowHarvestAudio,
		contentIds = { ["grow-harvest-plant"] = "rbxassetid://76044104452678" },
	})
	kit.result("grow-harvest:plant", { ok = false, reason = "NO_SEED" })
	kit.result("grow-harvest:teleport", { ok = true })
	assert(#fakes.calls == 0, "only a committed, bound action plays")
end

return M
