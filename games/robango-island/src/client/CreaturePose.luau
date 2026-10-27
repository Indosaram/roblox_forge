--!strict
-- Translate server wildlife state into render-only clips. The caller owns its
-- render connection and supplies the measured velocity and frame delta.
local M = {}
export type Clock = { state: string, elapsed: number }
local clips: { [string]: string } = {
	warn = "warning",
	windup = "windup",
	strike = "attack",
	recovery = "recovery",
	dead = "dead",
	stunned = "stun",
	sleep = "rest",
	hibernate = "rest",
	walk = "walk", -- Studio species gallery (StudioSetup.gallery) only
}
function M.sample(clock: Clock, serverState: string?, speed: number, mounted: boolean, dt: number): (string, number)
	local clip = if serverState then clips[serverState] else nil
	local state: string = clip
		-- Ridden (C4): the mount strides with its rider's speed, runs past a jog and idles at rest.
		or (
			if speed > 14
				then "run"
				elseif mounted and speed > 0.5 then "ridden"
				elseif speed > 0.5 then "walk"
				else "idle"
		)
	if state ~= clock.state then
		clock.state, clock.elapsed = state, 0
	end
	clock.elapsed += dt
	return state, clock.elapsed
end
return M
