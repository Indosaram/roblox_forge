--!strict
local fs = require("@lune/fs")
local CharacterTracks = require("./CharacterTracks")

-- The engine limit: past 64 live tracks an Animator stops playing new animations.
local TRACK_LIMIT = 64

local function signal()
	local handlers: { [number]: (...any) -> () } = {}
	local nextId = 0
	local live = 0
	local value = {}
	function value.Connect(_self, handler)
		nextId += 1
		local id = nextId
		handlers[id] = handler
		live += 1
		return {
			Disconnect = function()
				if handlers[id] then
					handlers[id] = nil
					live -= 1
				end
			end,
		}
	end
	function value.Fire(_self, ...)
		for _, handler in table.clone(handlers) do
			handler(...)
		end
	end
	function value.live(): number
		return live
	end
	return value
end

-- A fake Animator that counts live tracks the way the engine does: LoadAnimation adds one, and
-- only Destroy releases it.
local function animator()
	local self: any = { live = 0, AnimationPlayed = signal() }
	function self.IsA(_, class)
		return class == "Animator"
	end
	function self.LoadAnimation(_, animation)
		self.live += 1
		local track: any = { Animation = animation, IsPlaying = false, destroyed = false }
		function track.Play()
			assert(not track.destroyed, "played a destroyed track")
			track.IsPlaying = true
			self.AnimationPlayed:Fire(track)
		end
		function track.Stop()
			track.IsPlaying = false
		end
		function track.Destroy()
			if not track.destroyed then
				track.destroyed = true
				track.IsPlaying = false
				self.live -= 1
			end
		end
		return track
	end
	return self
end

-- The observed leak: the default Animate script loads a fresh track on every state change and the
-- replaced one is stopped but never released (403 retries in Studio). 200 changes over 3 ids.
local IDS = { "rbxassetid://507766388", "rbxassetid://913376220", "rbxassetid://913402848" }
local function leakyAnimate(rig: any, changes: number)
	local current: any = nil
	for change = 1, changes do
		if current then
			current.Stop()
		end
		current = rig:LoadAnimation({ AnimationId = IDS[change % #IDS + 1] })
		current.Play()
	end
	return current
end

local function character(rig: any): any
	local humanoid: any = {}
	function humanoid.WaitForChild(_, name)
		return if name == "Animator" then rig else nil
	end
	local model: any = {}
	function model.WaitForChild(_, name)
		return if name == "Humanoid" then humanoid else nil
	end
	return model
end

return {
	["200 Animate state changes keep the Animator under its track limit"] = function()
		local rig = animator()
		local stop = CharacterTracks.guard(rig)
		local current = leakyAnimate(rig, 200)
		assert(rig.live <= 2 * #IDS, "bounded tracks per animation: " .. rig.live)
		assert(rig.live < TRACK_LIMIT, "under the engine limit")
		assert(current.IsPlaying and not current.destroyed, "the playing track is never destroyed")
		stop()
		assert(rig.AnimationPlayed.live() == 0, "guard disconnects")
	end,
	["a still-playing previous track may fade out; older ones are released"] = function()
		local rig = animator()
		CharacterTracks.guard(rig)
		local id = { AnimationId = "rbxassetid://1" }
		local a, b, c = rig:LoadAnimation(id), rig:LoadAnimation(id), rig:LoadAnimation(id)
		a.Play()
		b.Play()
		assert(not a.destroyed and not b.destroyed, "crossfade keeps the previous playing track")
		c.Play()
		assert(a.destroyed and not b.destroyed and not c.destroyed, "only two per animation")
	end,
	["200 respawns each guard only the live character"] = function()
		local added = signal()
		local player: any = { CharacterAdded = added, Character = nil }
		local stop = CharacterTracks.start(player)
		local rigs = {}
		for spawn = 1, 200 do
			local rig = animator()
			rigs[spawn] = rig
			player.Character = character(rig)
			added:Fire(player.Character)
			leakyAnimate(rig, 50)
			assert(rig.live <= 2 * #IDS, "respawn " .. spawn .. " bounded: " .. rig.live)
			if spawn > 1 then
				assert(rigs[spawn - 1].AnimationPlayed.live() == 0, "previous character guard released")
			end
		end
		stop()
		assert(added.live() == 0 and rigs[200].AnimationPlayed.live() == 0, "start() cleans up")
	end,
	["the client guards the local character's animation tracks"] = function()
		local source = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(
			string.find(source, 'require(script.Parent:WaitForChild("CharacterTracks")).start(player)', 1, true),
			"client starts CharacterTracks for the local player"
		)
		local project = fs.readFile("games/robango-island/default.project.json")
		assert(string.find(project, "src/client/CharacterTracks.luau", 1, true), "module ships with the client")
	end,
}
