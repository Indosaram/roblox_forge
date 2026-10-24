--!strict
-- Bounds the local character's AnimationTracks. The engine's default Animate script loads a new
-- track for every state change (idle, walk, run, jump, fall, tool). When the replaced tracks are
-- not released (in unpublished Studio places the default animation ids answer 403 and every retry
-- loads another track) the Animator reaches its 64-track limit and stops playing animations.
--
-- A track whose animation failed to load may never fire Animator.AnimationPlayed, yet it still
-- counts toward the limit (p68: 64 playing tracks, all from 403 ids). So the guard prunes on every
-- AnimationPlayed AND on a sweep about once a second that reads Animator:GetPlayingAnimationTracks().
--
-- Per animation (AnimationId, or the Animation instance when the id is empty) it keeps the newest
-- track, plus the previous one while it is still playing so a crossfade can finish. Every older
-- track is stopped. The engine limit counts playing tracks (p68: GetPlayingAnimationTracks()
-- returned 64 at the warning burst), so Stop(0) alone frees a slot. A track is also destroyed only
-- when it fired AnimationPlayed and a newer track of the same animation has played since: that is
-- the ad75c87 rule, which ran 30 min in Studio with 0 errors, because Animate drops its reference
-- to a track once it loads the replacement. Tracks seen only by the sweep are never destroyed,
-- since Animate may still hold them: a later :Play/:AdjustSpeed on a stopped track is valid, and
-- a re-play makes that track the newest again. Past MAX_PLAYING playing tracks in total the least
-- recently played are stopped. Engine calls are pcall'd so a track Animate destroyed concurrently
-- cannot raise. The guard ends with its character.
local M = {}

M.PER_ANIMATION = 2
M.MAX_PLAYING = 32
M.SWEEP_SECONDS = 1

local function release(track: AnimationTrack, destroy: boolean)
	pcall(function()
		track:Stop(0)
	end)
	if destroy then
		pcall(function()
			track:Destroy()
		end)
	end
end

local function keyOf(track: AnimationTrack): any
	local animation = track.Animation
	if not animation then
		return track
	end
	return if animation.AnimationId ~= "" then animation.AnimationId else animation
end

--- Watches `animator` and releases superseded tracks per animation and past the playing cap.
--- `heartbeat` defaults to RunService.Heartbeat. Returns the stop function.
function M.guard(animator: Animator, heartbeat: RBXScriptSignal?): () -> ()
	local order = setmetatable({} :: { [AnimationTrack]: number }, { __mode = "k" })
	local heard = setmetatable({} :: { [AnimationTrack]: boolean }, { __mode = "k" })
	local counter = 0
	local groups: { [any]: { AnimationTrack } } = {}

	-- `played` marks a track that fired AnimationPlayed: it becomes the newest of its animation.
	local function remember(track: AnimationTrack, played: boolean)
		local known = order[track] ~= nil
		if played then
			heard[track] = true
		end
		if known and not played then
			return
		end
		counter += 1
		order[track] = counter
		if known then
			return
		end
		local key = keyOf(track)
		local group = groups[key]
		if not group then
			group = {}
			groups[key] = group
		end
		table.insert(group, track)
	end

	local function newestFirst(a: AnimationTrack, b: AnimationTrack): boolean
		return (order[a] or 0) > (order[b] or 0)
	end

	local function sweep()
		local ok, playing = pcall(function()
			return animator:GetPlayingAnimationTracks()
		end)
		if ok then
			for _, track in playing do
				remember(track, false)
			end
		end
		local live: { AnimationTrack } = {}
		for key, group in groups do
			table.sort(group, newestFirst)
			local kept = {}
			for index, track in group do
				local superseded = index > 1 and not (#kept < M.PER_ANIMATION and track.IsPlaying)
				if superseded then
					-- Destroy only what AnimationPlayed reported; sweep-only tracks are stopped.
					release(track, heard[track] == true)
				end
				local stillHeld = if heard[track] then not superseded else track.IsPlaying
				if stillHeld then
					table.insert(kept, track)
				else
					-- Forget it; if it plays again the sweep or AnimationPlayed re-registers it.
					order[track] = nil
				end
			end
			if #kept > 0 then
				groups[key] = kept
			else
				groups[key] = nil
			end
			for _, track in kept do
				if track.IsPlaying then
					table.insert(live, track)
				end
			end
		end
		if #live > M.MAX_PLAYING then
			table.sort(live, newestFirst)
			for index = #live, M.MAX_PLAYING + 1, -1 do
				release(live[index], false)
			end
		end
	end

	local played = animator.AnimationPlayed:Connect(function(track: AnimationTrack)
		remember(track, true)
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
	return function()
		played:Disconnect()
		ticked:Disconnect()
		table.clear(groups)
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
