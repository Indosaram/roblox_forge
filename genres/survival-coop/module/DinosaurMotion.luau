--!strict
-- Server presentation only. C0 replicates; Motor6D.Transform does not.
-- A strike gesture is an attempted attack, never a damage receipt.
local M = {}
export type State = { mode: string, healthMilli: number, strike: number }
export type Controller = {
	update: (State, number, Vector3) -> (),
	destroy: () -> (),
}
function M.new(model: Model, root: BasePart, initial: State, now: number): Controller
	local joints: { [string]: { joint: Motor6D, rest: CFrame } } = {}
	for _, child in root:GetChildren() do
		if child:IsA("Motor6D") then
			joints[child.Name] = { joint = child, rest = child.C0 }
		end
	end
	local outline = Instance.new("Highlight")
	outline.Name, outline.Adornee = "WildlifeFeedback", model
	outline.DepthMode = Enum.HighlightDepthMode.Occluded
	outline.FillTransparency, outline.OutlineTransparency = 1, 0.25
	outline.Enabled, outline.Parent = false, model
	local health, strike = initial.healthMilli, initial.strike
	local last, rendered, phase = now, now - 50, 0
	local hurtAt, attackAt, deadAt = -math.huge, -math.huge, if health == 0 then now else math.huge
	local stopped, feedback = false, ""
	local api = {}
	function api.update(state: State, millis: number, velocity: Vector3)
		if stopped then
			return
		end
		if state.healthMilli < health and state.healthMilli > 0 then
			hurtAt = millis
		end
		if state.strike > strike then
			attackAt = millis
		end
		if state.healthMilli == 0 and health > 0 then
			deadAt = millis
		end
		health, strike = state.healthMilli, state.strike
		local dt = math.clamp((millis - last) / 1000, 0, 0.1)
		last = millis
		-- Horizontal physical speed, not MoveTo intent: blocked rigs do not walk.
		local speed = math.min(Vector3.new(velocity.X, 0, velocity.Z).Magnitude, 24)
		if health > 0 then
			phase = (phase + speed * dt * 0.65) % (2 * math.pi)
		end
		-- At most 20 pose writes/sec/rig, no per-rig event or spawned task.
		if millis - rendered < 50 then
			return
		end
		rendered = millis
		local dead = health == 0
		local warning = state.mode == "warn" or state.mode == "telegraph"
		local attack = math.max(0, 1 - (millis - attackAt) / 350)
		local hurt = math.max(0, 1 - (millis - hurtAt) / 300)
		local death = if dead then math.clamp((millis - deadAt) / 450, 0, 1) else 0
		local gait = if dead or warning then 0 else math.clamp(speed / 10, 0, 1)
		local breath = if dead then 0 else math.sin(millis / 700) * 0.025
		local cue = if dead
			then "dead"
			elseif hurt > 0 then "hurt"
			elseif attack > 0 then "strike"
			elseif warning then state.mode
			else ""
		if cue ~= feedback then
			feedback = cue
			model:SetAttribute("ForgeWildlifeFeedback", if cue == "" then nil else cue)
			outline.Enabled = cue ~= ""
			outline.OutlineColor = if dead
				then Color3.fromRGB(112, 116, 105)
				elseif hurt > 0 then Color3.fromRGB(180, 146, 119)
				elseif attack > 0 then Color3.fromRGB(170, 108, 76)
				else Color3.fromRGB(190, 163, 98)
		end
		local function pose(name: string, x: number, y: number, z: number, lift: number?)
			local binding = joints[name .. "Joint"]
			if binding then
				binding.joint.C0 = binding.rest * CFrame.new(0, lift or 0, 0) * CFrame.Angles(x, y, z)
			end
		end
		pose("Torso", -attack * 0.16 + hurt * 0.1, 0, death * 0.95, breath - death * 1.2)
		for side = -1, 1, 2 do
			local swing = math.sin(phase + (if side == 1 then 0 else math.pi)) * gait
			pose("Thigh" .. side, swing * 0.42 + death * 0.35, 0, 0)
			pose("Shin" .. side, math.max(0, -swing) * 0.5, 0, 0)
			pose("Foot" .. side, -swing * 0.15, 0, 0)
			pose("Foreleg" .. side, -swing * 0.32 + death * 0.5, 0, 0)
			pose("Arm" .. side, -attack * 0.4 + breath, 0, 0)
		end
		for segment = 1, 4 do
			pose(
				"Tail" .. segment,
				death * 0.05,
				if dead then 0 else math.sin(phase - segment * 0.4) * gait * 0.06 + breath,
				0
			)
		end
		for _, name in { "Neck", "Neck1", "Neck2", "Neck3" } do
			pose(name, breath + (if warning then -0.1 else 0) + attack * 0.12 - hurt * 0.08 + death * 0.12, 0, 0)
		end
		pose("Head", (if warning then -0.16 else 0) + attack * 0.3 - hurt * 0.15, 0, 0)
		pose("Jaw", if dead then 0.12 elseif warning then 0.22 elseif attack > 0 then attack * 0.45 else 0, 0, 0)
	end
	function api.destroy()
		if stopped then
			return
		end
		stopped = true
		for _, binding in joints do
			binding.joint.C0 = binding.rest
		end
		table.clear(joints)
		outline:Destroy()
		model:SetAttribute("ForgeWildlifeFeedback", nil)
	end
	return api
end
return M
