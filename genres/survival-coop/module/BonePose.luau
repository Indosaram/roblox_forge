--!strict
-- BonePose: pure Bone.Transform keyframes per body plan (gen_creatures.py rigs). Bone +Y runs
-- along the bone, X is the side axis: +x pitches, z yaws (rolls the upright Root). lift/forward
-- move the Root as a fraction of hip height.
local M = {}

export type Entry = { x: number, y: number, z: number, lift: number?, forward: number? }
export type Frame = { [string]: Entry }

-- Bones per body plan, as exported (asset catalog section 5 bone counts).
-- stylua: ignore
M.BONES = table.freeze({
	theropod = table.freeze({ "Root", "Spine", "Chest", "Neck1", "Neck2", "Head", "Jaw", "Tail1", "Tail2", "Tail3", "Tail4", "Tail5", "ThighL", "ShinL", "FootL", "ToeL", "ArmL", "ThighR", "ShinR", "FootR", "ToeR", "ArmR" }),
	ceratopsian = table.freeze({ "Root", "Spine", "Chest", "Neck", "Head", "Jaw", "Tail1", "Tail2", "Tail3", "Tail4", "ThighL", "ShinL", "FootL", "UpperArmL", "ForearmL", "ThighR", "ShinR", "FootR", "UpperArmR", "ForearmR" }),
	sauropod = table.freeze({ "Root", "Spine", "Chest", "Neck1", "Neck2", "Neck3", "Neck4", "Neck5", "Neck6", "Head", "Jaw", "Tail1", "Tail2", "Tail3", "Tail4", "Tail5", "ThighL", "ShinL", "FootL", "UpperArmL", "ForearmL", "ThighR", "ShinR", "FootR", "UpperArmR", "ForearmR" }),
})

-- Every state the client clock (CreaturePose.sample) can produce, mapped to its clip.
local CLIPS: { [string]: string } = {
	idle = "idle",
	walk = "walk",
	ridden = "walk",
	run = "run",
	graze = "graze",
	attack = "attack",
	strike = "attack",
	windup = "windup",
	warning = "windup",
	telegraph = "windup",
	recovery = "idle",
	hurt = "hurt",
	hit = "hurt",
	dead = "death",
	death = "death",
	stun = "rest",
	sleep = "rest",
	rest = "rest",
}

function M.clip(state: string): string
	return CLIPS[state] or "idle"
end

local function necks(plan: string): { string }
	if plan == "sauropod" then
		return { "Neck1", "Neck2", "Neck3", "Neck4", "Neck5", "Neck6" }
	elseif plan == "ceratopsian" then
		return { "Neck" }
	end
	return { "Neck1", "Neck2" }
end

local function tails(plan: string): { string }
	return if plan == "ceratopsian"
		then { "Tail1", "Tail2", "Tail3", "Tail4" }
		else { "Tail1", "Tail2", "Tail3", "Tail4", "Tail5" }
end

--- Samples one frame. `elapsed` is seconds in the current state, `speed` studs/s, `style` the
--- rig's AttackStyle, `period` the graze cycle (seconds). Every plan bone gets an entry.
function M.sample(plan: string, state: string, elapsed: number, speed: number, style: string?, period: number?): Frame
	local bones = assert(M.BONES[plan], "UNKNOWN_BODY_PLAN")
	local clip = M.clip(state)
	local frame: Frame = {}
	for _, name in bones do
		frame[name] = { x = 0, y = 0, z = 0 }
	end
	local t = elapsed
	local quad = plan ~= "theropod"
	local heavy = plan == "sauropod"
	-- Idle breathing and a slow tail sway under every living clip.
	local breath = math.sin(t * (if heavy then 1.1 else 1.8))
	if clip ~= "death" then
		frame.Chest.x += breath * 0.015
		for i, name in tails(plan) do
			frame[name].z += math.sin(t * 0.9 - i * 0.45) * (if heavy then 0.03 else 0.05)
		end
		for _, name in necks(plan) do
			frame[name].x += math.sin(t * 0.7) * 0.02
		end
	end
	if clip == "walk" or clip == "run" then
		local running = clip == "run"
		local rate = if running then 9 else (if heavy then 2.6 else 5)
		local phase = t * rate * math.clamp((speed + 4) / (if running then 22 else 12), 0.6, 1.4)
		local swing = if running then 0.75 else (if heavy then 0.28 else 0.42)
		for _, side in { "L", "R" } do
			local s = if side == "L" then 1 else -1
			local p = math.sin(phase) * s
			frame["Thigh" .. side].x += swing * p
			frame["Shin" .. side].x += swing * 0.9 * math.max(0, math.sin(phase + 1.3) * s)
			frame["Foot" .. side].x -= swing * 0.6 * p
			if quad then
				-- Diagonal gait: a foreleg moves opposite its own-side hind leg.
				frame["UpperArm" .. side].x -= swing * 0.85 * p
				frame["Forearm" .. side].x -= swing * 0.6 * math.max(0, -math.sin(phase + 1.3) * s)
			else
				frame["Toe" .. side].x -= swing * 0.3 * p
				frame["Arm" .. side].x += 0.1 * p
			end
		end
		frame.Root.lift = math.abs(math.sin(phase)) * (if running then 0.06 else 0.025)
		frame.Root.z += math.sin(phase) * 0.03
		if running then
			frame.Root.x += 0.1
			frame.Chest.x -= 0.05
		end
		for i, name in tails(plan) do
			frame[name].z += math.sin(phase - i * 0.6) * (if running then 0.08 else 0.06)
			frame[name].x += if running then 0.04 else 0
		end
		for _, name in necks(plan) do
			frame[name].x += math.sin(phase * 2) * 0.025 - (if running then 0.06 else 0)
		end
	elseif clip == "graze" then
		local cycle = (t % (period or 10)) / (period or 10)
		local dip = if cycle > 0.3 and cycle < 0.9 then math.sin((cycle - 0.3) / 0.6 * math.pi) else 0
		local n = necks(plan)
		for _, name in n do
			frame[name].x += dip * (if heavy then 0.09 else 0.55 / #n)
		end
		frame.Head.x += dip * (if heavy then 0.2 else 0.45)
		frame.Head.z += math.sin(t * 0.8) * 0.12 * (1 - dip)
		frame.Jaw.x += dip * 0.18 * math.abs(math.sin(t * 6))
		if not heavy then
			frame.Root.x += dip * 0.06
			frame.ThighL.x -= dip * 0.06
			frame.ThighR.x -= dip * 0.06
		end
	elseif clip == "windup" then
		-- Warning: head raised, jaw open, weight shifted back.
		local k = math.clamp(t / 0.3, 0, 1)
		for _, name in necks(plan) do
			frame[name].x -= k * 0.12
		end
		frame.Head.x -= k * 0.2
		frame.Jaw.x += k * 0.4
		frame.Root.x -= k * 0.05
	elseif clip == "attack" then
		local pulse = math.sin(math.clamp(t / 0.5, 0, 1) * math.pi)
		local kind = style or "bite"
		if kind == "charge" then
			frame.Head.x += pulse * 0.45
			frame.Root.forward = pulse * 0.35
			frame.Root.x += pulse * 0.08
		elseif kind == "stomp" then
			-- Rear up on the hind legs, forelegs raised, then slam.
			frame.Root.x -= pulse * 0.32
			frame.UpperArmL.x -= pulse * 0.7
			frame.UpperArmR.x -= pulse * 0.7
			frame.ForearmL.x += pulse * 0.5
			frame.ForearmR.x += pulse * 0.5
			for _, name in necks(plan) do
				frame[name].x += pulse * 0.05
			end
		elseif kind == "kick" then
			frame.ThighL.x -= pulse * 1.0
			frame.ShinL.x += pulse * 0.4
			frame.Root.x -= pulse * 0.08
		else
			-- bite / jab / slash / pounce: lunge forward, neck and head strike, jaw snaps.
			frame.Root.forward = pulse * (if kind == "pounce" then 0.45 else 0.25)
			frame.Root.lift = if kind == "pounce" then pulse * 0.2 else 0
			frame.Root.x += pulse * 0.1
			for _, name in necks(plan) do
				frame[name].x += pulse * 0.12
			end
			frame.Head.x += pulse * 0.1
			frame.Jaw.x += pulse * (if kind == "bite" then 0.7 else 0.35)
			if not quad and (kind == "slash" or kind == "pounce" or kind == "jab") then
				frame.ArmL.x -= pulse * 0.8
				frame.ArmR.x -= pulse * 0.8
			end
		end
		for i, name in tails(plan) do
			frame[name].x += pulse * 0.05 * i
		end
	elseif clip == "hurt" then
		local flinch = math.sin(math.clamp(t / 0.3, 0, 1) * math.pi)
		frame.Root.z += flinch * 0.2
		frame.Root.forward = -flinch * 0.08
		for _, name in necks(plan) do
			frame[name].x -= flinch * 0.1
		end
		frame.Head.z += flinch * 0.25
		frame.Jaw.x += flinch * 0.3
	elseif clip == "rest" then
		frame.Root.lift = -0.22
		for _, side in { "L", "R" } do
			frame["Thigh" .. side].x -= 0.5
			frame["Shin" .. side].x += 0.9
			if quad then
				frame["UpperArm" .. side].x += 0.4
				frame["Forearm" .. side].x -= 0.6
			end
		end
		for _, name in necks(plan) do
			frame[name].x += 0.08
		end
		frame.Head.x += 0.25
	elseif clip == "death" then
		-- Roll onto the side over 1.2 s, legs and tail go limp, head drops.
		local k = math.clamp(t / 1.2, 0, 1)
		local ease = k * k * (3 - 2 * k)
		-- Root points up (local Z forward), so z about it is a roll onto the flank.
		frame.Root.z += ease * (math.pi / 2)
		frame.Root.lift = -ease * 0.55
		for _, side in { "L", "R" } do
			frame["Thigh" .. side].x -= ease * 0.35
			frame["Shin" .. side].x += ease * 0.5
			if quad then
				frame["UpperArm" .. side].x += ease * 0.4
			end
		end
		for _, name in necks(plan) do
			frame[name].x += ease * 0.12
		end
		frame.Head.x += ease * 0.2
		frame.Jaw.x += ease * 0.25
		for _, name in tails(plan) do
			frame[name].x -= ease * 0.06
		end
	end
	return frame
end

return M
