--!strict
-- Bounds the local character's AnimationTracks. The engine's default Animate script loads a new
-- track for every state change (idle, walk, run, jump, fall, tool). When the replaced tracks are
-- not released (in unpublished Studio places the default animation ids answer 403 and every retry
-- loads another track) the Animator reaches its 64-track limit and stops playing animations.
--
-- Engine semantics observed in Studio (p71): Animator:GetPlayingAnimationTracks() lists every track
-- that is not destroyed, stopped ones included (64 listed, 63 with IsPlaying=false); those count
-- toward the 64-track limit; Stop does not free a slot, only Destroy does. A track whose animation
-- failed to load may never fire Animator.AnimationPlayed, so the guard prunes on every
-- AnimationPlayed AND on a sweep of GetPlayingAnimationTracks() several times a second.
--
-- Tracks are grouped per animation (AnimationId, or the Animation instance when the id is empty) and
-- ranked: a track that fires AnimationPlayed becomes the newest of its animation; a track first seen
-- by the sweep while playing ranks as newest at discovery; a track first seen stopped ranks below
-- every track ranked by the two rules above (ordered among themselves by discovery), because a
-- stopped track nobody reported is a replaced one, not the one Animate is driving.
-- Per animation the newest track is kept (even stopped: a finished one-shot like jump is still the
-- one Animate holds), the previous one is kept while it is playing so a crossfade can finish, and
-- every other track is stopped and destroyed.
--
-- Why destroying them is safe: the default Animate script holds one track per slot
-- (currentAnimTrack, runAnimTrack, toolAnimTrack). On a change it stops (and destroys) that track and
-- assigns the result of a fresh LoadAnimation; it only ever plays or adjusts the track it holds, never
-- an older one. So a track that is neither the newest of its animation nor still fading out is one
-- Animate has already dropped.
--
-- Past MAX_TRACKS live tracks in total the oldest stopped tracks are destroyed first, then the oldest
-- playing ones. Engine calls are pcall'd so a track destroyed concurrently cannot raise. The guard
-- ends with its character.
local M = {}

M.MAX_TRACKS = 32
M.SWEEP_SECONDS = 0.2

-- Ranks of tracks first seen stopped live in a band below every played/discovered-playing rank.
local STOPPED_BAND = -1e9

local function release(track: AnimationTrack)
	pcall(function()
		track:Stop(0)
	end)
	pcall(function()
		track:Destroy()
	end)
end

local function isPlaying(track: AnimationTrack): boolean
	local ok, playing = pcall(function()
		return track.IsPlaying
	end)
	return ok and playing == true
end

local function keyOf(track: AnimationTrack): any
	local ok, key = pcall(function(): any
		local animation = track.Animation
		if not animation then
			return track
		end
		return if animation.AnimationId ~= "" then animation.AnimationId else animation
	end)
	return if ok then key else track
end

--- Watches `animator` and destroys superseded tracks per animation and past the total cap.
--- `heartbeat` defaults to RunService.Heartbeat. Returns the stop function.
function M.guard(animator: Animator, heartbeat: RBXScriptSignal?): () -> ()
	local rank = setmetatable({} :: { [AnimationTrack]: number }, { __mode = "k" })
	local counter = 0
	local discovered = 0

	local function newestFirst(a: AnimationTrack, b: AnimationTrack): boolean
		return rank[a] > rank[b]
	end

	local function sweep()
		local ok, listed = pcall(function()
			return animator:GetPlayingAnimationTracks()
		end)
		if not ok then
			return
		end
		local groups: { [any]: { AnimationTrack } } = {}
		for _, track in listed do
			if rank[track] == nil then
				if isPlaying(track) then
					counter += 1
					rank[track] = counter
				else
					discovered += 1
					rank[track] = STOPPED_BAND + discovered
				end
			end
			local key = keyOf(track)
			local group = groups[key]
			if not group then
				group = {}
				groups[key] = group
			end
			table.insert(group, track)
		end
		local live: { AnimationTrack } = {}
		for _, group in groups do
			table.sort(group, newestFirst)
			for index, track in group do
				if index == 1 or (index == 2 and isPlaying(track)) then
					table.insert(live, track)
				else
					rank[track] = nil
					release(track)
				end
			end
		end
		if #live > M.MAX_TRACKS then
			-- Oldest stopped tracks go first, then the oldest playing ones.
			table.sort(live, function(a, b)
				local pa, pb = isPlaying(a), isPlaying(b)
				if pa ~= pb then
					return pb
				end
				return rank[a] < rank[b]
			end)
			for index = 1, #live - M.MAX_TRACKS do
				rank[live[index]] = nil
				release(live[index])
			end
		end
	end

	local played = animator.AnimationPlayed:Connect(function(track: AnimationTrack)
		counter += 1
		rank[track] = counter
		sweep()
	end)
	local signal: RBXScriptSignal = heartbeat or game:GetService("RunService").Heartbeat
	local elapsed = 0
	local ticked = signal:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= M.SWEEP_SECONDS then
			elapsed = 0
			sweep()
		end
	end)
	sweep()
	return function()
		played:Disconnect()
		ticked:Disconnect()
	end
end

--- Guards each character `player` spawns; a respawn ends the previous character's guard.
function M.start(player: Player, heartbeat: RBXScriptSignal?): () -> ()
	local stop: (() -> ())? = nil
	local generation = 0
	local function attach(character: Model)
		generation += 1
		local mine = generation
		if stop then
			stop()
			stop = nil
		end
		local humanoid = character:WaitForChild("Humanoid", 30)
		local animator = if humanoid then humanoid:WaitForChild("Animator", 30) else nil
		if mine == generation and animator and animator:IsA("Animator") then
			stop = M.guard(animator, heartbeat)
		end
	end
	local added = player.CharacterAdded:Connect(attach)
	if player.Character then
		coroutine.wrap(attach)(player.Character)
	end
	return function()
		added:Disconnect()
		generation += 1
		if stop then
			stop()
			stop = nil
		end
	end
end

return M
