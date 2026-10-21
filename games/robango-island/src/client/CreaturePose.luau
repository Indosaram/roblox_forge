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
}
function M.sample(clock: Clock, serverState: string?, speed: number, mounted: boolean, dt: number): (string, number)
	local clip = if serverState then clips[serverState] else nil
	local state: string = clip
		or (if mounted then "ridden" elseif speed > 14 then "run" elseif speed > 0.5 then "walk" else "idle")
	if state ~= clock.state then
		clock.state, clock.elapsed = state, 0
	end
	clock.elapsed += dt
	return state, clock.elapsed
end
return M
