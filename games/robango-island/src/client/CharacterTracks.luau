--!strict
-- Bounds the local character's AnimationTracks. The engine's default Animate script loads a new
-- track for every state change (idle, walk, run, jump, fall, tool). When the replaced tracks are
-- not released (in unpublished Studio places the default animation ids answer 403 and every retry
-- loads another track) the Animator reaches its 64-track limit and stops playing animations.
-- This keeps one generation per AnimationId: when a track plays, the newest older track of the
-- same animation may keep fading out if it is still playing; every other older track is stopped
-- and destroyed. So the Animator holds at most two tracks per animation. The guard ends with its
-- character.
local M = {}

--- Watches `animator` and destroys superseded tracks per AnimationId. Returns the stop function.
function M.guard(animator: Animator): () -> ()
	local tracks: { [string]: { AnimationTrack } } = {}
	local connection = animator.AnimationPlayed:Connect(function(track: AnimationTrack)
		local animation = track.Animation
		local id = if animation then animation.AnimationId else ""
		local kept = { track }
		local previous = tracks[id] or {}
		for index = #previous, 1, -1 do
			local older = previous[index]
			if older == track then
				continue
			end
			if #kept < 2 and older.IsPlaying then
				table.insert(kept, 1, older)
			else
				older:Stop(0)
				older:Destroy()
			end
		end
		tracks[id] = kept
	end)
	return function()
		connection:Disconnect()
		table.clear(tracks)
	end
end

--- Guards each character `player` spawns; a respawn ends the previous character's guard.
function M.start(player: Player): () -> ()
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
			stop = M.guard(animator)
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
