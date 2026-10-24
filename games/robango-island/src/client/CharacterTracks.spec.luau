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

-- A fake Animator modelled on the engine as observed in Studio (p71, p75). GetPlayingAnimationTracks()
-- lists every track the Animator still runs and those count toward the 64-track limit. A loaded track
-- is listed until it is stopped with no fade or destroyed. On a `sticky` rig (animations that answer
-- 403) a playing track stopped with a fade (Stop() defaults to 0.1 s) never finishes the fade: it stays
-- listed and Stop(0) and Destroy do not remove it; only a fresh Play and a no-fade Stop do. On a
-- `silent` rig Play never fires AnimationPlayed. Playing or adjusting a destroyed track errors.
local function animator(options: { silent: boolean?, sticky: boolean? }?)
	local silent = options ~= nil and options.silent == true
	local sticky = options ~= nil and options.sticky == true
	local self: any = { live = 0, peak = 0, AnimationPlayed = signal(), tracks = {} }
	local function list(track)
		if not table.find(self.tracks, track) then
			assert(self.live < TRACK_LIMIT, "Animator track limit reached")
			table.insert(self.tracks, track)
			self.live += 1
			self.peak = math.max(self.peak, self.live)
		end
	end
	local function unlist(track)
		local index = table.find(self.tracks, track)
		if index then
			table.remove(self.tracks, index)
			self.live -= 1
		end
	end
	function self.IsA(_, class)
		return class == "Animator"
	end
	function self.GetPlayingAnimationTracks()
		return table.clone(self.tracks)
	end
	function self.LoadAnimation(_, animation)
		local track: any = { Animation = animation, IsPlaying = false, destroyed = false, stuck = false }
		list(track)
		function track.Play(_)
			assert(not track.destroyed or track.stuck, "played a destroyed track")
			list(track)
			track.stuck = false
			track.IsPlaying = true
			if not silent then
				self.AnimationPlayed:Fire(track)
			end
		end
		function track.AdjustSpeed(_)
			assert(not track.destroyed, "adjusted a destroyed track")
		end
		function track.Stop(_, fade: number?)
			local wasPlaying = track.IsPlaying
			track.IsPlaying = false
			if sticky and wasPlaying and (fade or 0.1) > 0 then
				track.stuck = true
			elseif not track.stuck then
				unlist(track)
			end
		end
		function track.Destroy(_)
			track.destroyed = true
			track.IsPlaying = false
			if not track.stuck then
				unlist(track)
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
			current:Stop()
		end
		current = rig:LoadAnimation({ AnimationId = IDS[change % #IDS + 1] })
		current:Play()
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

-- Animate's slots (core state, run, tool), each with its own animations; the core slot also uses an
-- Animation with an empty id (grouped by the shared instance).
local EMPTY = { AnimationId = "" }
local SLOTS = {
	{ { AnimationId = IDS[1] }, { AnimationId = IDS[2] }, { AnimationId = IDS[3] }, EMPTY },
	{ { AnimationId = "rbxassetid://913376220-run" } },
	{ { AnimationId = "rbxassetid://507768375-tool" }, { AnimationId = "rbxassetid://522635514-tool" } },
}

return {
	["500 silent Animate replacements stay under the track limit and the cap"] = function()
		local rig = animator({ silent = true, sticky = true })
		local heartbeat = signal()
		local stop = CharacterTracks.guard(rig, heartbeat :: any)
		local current: { [number]: any } = {}
		for change = 1, 500 do
			-- 403 retries: Animate fade-stops the track it holds in a slot (without destroying it), loads
			-- the replacement and plays it; the track never reports AnimationPlayed.
			local slot = change % #SLOTS + 1
			local animations = SLOTS[slot]
			if current[slot] then
				current[slot]:Stop()
			end
			current[slot] = rig:LoadAnimation(animations[change % #animations + 1])
			current[slot]:Play()
			-- Animate keeps driving the tracks it holds: this errors on a destroyed track.
			for _, held in current do
				held:AdjustSpeed(1)
			end
			heartbeat:Fire(0.1)
			assert(rig.live <= CharacterTracks.MAX_TRACKS, "live tracks capped: " .. rig.live)
		end
		assert(rig.peak < TRACK_LIMIT, "live tracks stayed under the engine limit, peak " .. rig.peak)
		for _, held in current do
			held:Play()
		end
		stop()
		assert(heartbeat.live() == 0, "sweep disconnects")
	end,
	["unknown stopped tracks never outrank the track Animate drives"] = function()
		local rig = animator({ silent = true })
		local heartbeat = signal()
		local id = { AnimationId = IDS[1] }
		local held = rig:LoadAnimation(id)
		held:Play()
		-- Stale tracks of the same animation, loaded later but stopped (failed 403 retries).
		local stale = { rig:LoadAnimation(id), rig:LoadAnimation(id), rig:LoadAnimation(id) }
		CharacterTracks.guard(rig, heartbeat :: any)
		for _ = 1, 5 do
			heartbeat:Fire(CharacterTracks.SWEEP_SECONDS)
		end
		for _, track in stale do
			assert(track.destroyed, "stale stopped sweep-only tracks are destroyed")
		end
		assert(not held.destroyed and held.IsPlaying, "the playing track is kept")
		held:AdjustSpeed(1)
		assert(rig.live == 1, "one live track: " .. rig.live)
	end,
	["the cap destroys the oldest tracks across many animations, stopped ones first"] = function()
		local rig = animator({ silent = true, sticky = true })
		local heartbeat = signal()
		CharacterTracks.guard(rig, heartbeat :: any)
		local tracks = {}
		for id = 1, 60 do
			tracks[id] = rig:LoadAnimation({ AnimationId = "rbxassetid://" .. id })
			tracks[id]:Play()
		end
		tracks[59]:Stop()
		heartbeat:Fire(CharacterTracks.SWEEP_SECONDS)
		assert(rig.live == CharacterTracks.MAX_TRACKS, "capped: " .. rig.live)
		assert(tracks[59].destroyed, "a stopped track goes before playing ones")
		assert(not tracks[60].destroyed and tracks[1].destroyed, "the oldest go first")
	end,
	["200 Animate state changes keep the Animator under its track limit"] = function()
		local rig = animator()
		local stop = CharacterTracks.guard(rig, signal() :: any)
		local current = leakyAnimate(rig, 200)
		assert(rig.live <= #IDS, "one track per animation: " .. rig.live)
		assert(current.IsPlaying and not current.destroyed, "the playing track is never destroyed")
		stop()
		assert(rig.AnimationPlayed.live() == 0, "guard disconnects")
	end,
	["a still-playing previous track may fade out; older ones are destroyed"] = function()
		local rig = animator({ sticky = true })
		local heartbeat = signal()
		CharacterTracks.guard(rig, heartbeat :: any)
		local id = { AnimationId = "rbxassetid://1" }
		-- Animate loads a track and plays it at once (playAnimation: LoadAnimation then Play).
		local a = rig:LoadAnimation(id)
		a:Play()
		local b = rig:LoadAnimation(id)
		b:Play()
		assert(not a.destroyed and not b.destroyed, "crossfade keeps the previous playing track")
		local c = rig:LoadAnimation(id)
		c:Play()
		assert(a.destroyed and not b.destroyed and not c.destroyed, "only two per animation")
		b:Stop()
		heartbeat:Fire(CharacterTracks.SWEEP_SECONDS)
		assert(b.destroyed and not c.destroyed, "the faded-out previous track is destroyed")
		assert(rig.live == 1, "the fade-stuck previous track leaves the Animator: " .. rig.live)
		c:AdjustSpeed(1)
	end,
	["fade-stopped 403 tracks that Animate destroys leave the Animator"] = function()
		-- Animate's playAnimation: Stop(transitionTime) and Destroy the held track, then load and play a
		-- new one. With 403 animations every replaced track sticks (p75 Studio evidence).
		local rig = animator({ silent = true, sticky = true })
		local heartbeat = signal()
		CharacterTracks.guard(rig, heartbeat :: any)
		local current: any = nil
		for change = 1, 600 do
			if current then
				current:Stop(0.1)
				current:Destroy()
			end
			current = rig:LoadAnimation({ AnimationId = IDS[change % #IDS + 1] })
			current:Play()
			current:AdjustSpeed(1)
			heartbeat:Fire(0.05)
			-- Between sweeps (every 4 changes here) the replaced tracks wait for the next sweep.
			assert(rig.live <= 2 * #IDS + 4, "bounded at change " .. change .. ": " .. rig.live)
		end
		assert(rig.peak < TRACK_LIMIT, "under the engine limit, peak " .. rig.peak)
		assert(current.IsPlaying and not current.destroyed, "the held track keeps playing")
	end,
	["200 respawns each guard only the live character"] = function()
		local added = signal()
		local player: any = { CharacterAdded = added, Character = nil }
		local stop = CharacterTracks.start(player, signal() :: any)
		local rigs = {}
		for spawn = 1, 200 do
			local rig = animator()
			rigs[spawn] = rig
			player.Character = character(rig)
			added:Fire(player.Character)
			leakyAnimate(rig, 50)
			assert(rig.live <= #IDS, "respawn " .. spawn .. " bounded: " .. rig.live)
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
