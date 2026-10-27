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
	armored = table.freeze({ "Root", "Spine", "Chest", "Neck", "Head", "Jaw", "Tail1", "Tail2", "Tail3", "Tail4", "ThighL", "ShinL", "FootL", "UpperArmL", "ForearmL", "ThighR", "ShinR", "FootR", "UpperArmR", "ForearmR" }),
	hadrosaur = table.freeze({ "Root", "Spine", "Chest", "Neck1", "Neck2", "Head", "Jaw", "Tail1", "Tail2", "Tail3", "Tail4", "Tail5", "ThighL", "ShinL", "FootL", "UpperArmL", "ForearmL", "ThighR", "ShinR", "FootR", "UpperArmR", "ForearmR" }),
	mammal = table.freeze({ "Root", "Spine", "Chest", "Neck1", "Neck2", "Head", "Jaw", "Tail1", "Tail2", "Tail3", "ThighL", "ShinL", "FootL", "UpperArmL", "ForearmL", "HandL", "EarL", "ThighR", "ShinR", "FootR", "UpperArmR", "ForearmR", "HandR", "EarR" }),
	elephant = table.freeze({ "Root", "Spine", "Chest", "Neck", "Head", "Jaw", "Trunk1", "Trunk2", "Trunk3", "Trunk4", "Tail1", "Tail2", "ThighL", "ShinL", "FootL", "UpperArmL", "ForearmL", "EarL", "ThighR", "ShinR", "FootR", "UpperArmR", "ForearmR", "EarR" }),
	crocodilian = table.freeze({ "Root", "Spine", "Chest", "Neck", "Head", "Jaw", "Tail1", "Tail2", "Tail3", "Tail4", "ThighL", "ShinL", "UpperArmL", "ForearmL", "ThighR", "ShinR", "UpperArmR", "ForearmR" }),
	turtle = table.freeze({ "Root", "Spine", "Neck", "Head", "Jaw", "Tail", "ThighL", "UpperArmL", "ForearmL", "ThighR", "UpperArmR", "ForearmR" }),
	bird = table.freeze({ "Root", "Neck1", "Neck2", "Head", "Jaw", "Tail", "ThighL", "ShinL", "FootL", "WingL", "ThighR", "ShinR", "FootR", "WingR" }),
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
	-- B2b: water travel (crocodilian, turtle) when the server publishes it; others treat it as walk.
	swim = "swim",
}

function M.clip(state: string): string
	return CLIPS[state] or "idle"
end

local function prefixed(plan: string, prefix: string): { string }
	local out = {}
	for _, name in M.BONES[plan] do
		if string.sub(name, 1, #prefix) == prefix then
			table.insert(out, name)
		end
	end
	return out
end

local function necks(plan: string): { string }
	return prefixed(plan, "Neck")
end

local function tails(plan: string): { string }
	return prefixed(plan, "Tail")
end

-- Plans whose forelimbs are legs (diagonal gait); the bird and theropod are bipeds.
local QUADRUPED: { [string]: boolean } = {
	ceratopsian = true,
	sauropod = true,
	armored = true,
	hadrosaur = true,
	mammal = true,
	elephant = true,
	crocodilian = true,
	turtle = true,
}
M.QUADRUPED = QUADRUPED
-- Water travel clip (asset catalog: crocodilian and turtle).
local SWIMMERS: { [string]: boolean } = { crocodilian = true, turtle = true }
M.SWIMMERS = SWIMMERS
-- Heavy, slow-stepping plans share the sauropod's stride rate.
local SLOW: { [string]: boolean } = { elephant = true, armored = true, turtle = true }

local function each(plan: string, prefix: string, fn: (string, number) -> ())
	for i, name in prefixed(plan, prefix) do
		fn(name, i)
	end
end

--- Samples one frame. `elapsed` is seconds in the current state, `speed` studs/s, `style` the
--- rig's AttackStyle, `period` the graze cycle (seconds). Every plan bone gets an entry.
function M.sample(plan: string, state: string, elapsed: number, speed: number, style: string?, period: number?): Frame
	local bones = assert(M.BONES[plan], "UNKNOWN_BODY_PLAN")
	local clip = M.clip(state)
	if clip == "swim" and not SWIMMERS[plan] then
		clip = "walk"
	end
	local frame: Frame = {}
	for _, name in bones do
		frame[name] = { x = 0, y = 0, z = 0 }
	end
	-- Shared clips address limb bones a plan may lack (the turtle has no shins, the bird no
	-- chest): those writes land in a scratch entry that is never returned.
	local scratch: Entry = { x = 0, y = 0, z = 0 }
	setmetatable(frame :: any, {
		__index = function()
			return scratch
		end,
	})
	local t = elapsed
	local quad = QUADRUPED[plan] == true
	local heavy = plan == "sauropod"
	local slow = SLOW[plan] == true
	local bird = plan == "bird"
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
		-- Trunk sway and ear fanning (elephant), ear twitch (mammal).
		each(plan, "Trunk", function(name, i)
			frame[name].x += math.sin(t * 1.3 - i * 0.5) * 0.06
			frame[name].z += math.sin(t * 0.9 - i * 0.4) * 0.05
		end)
		each(plan, "Ear", function(name)
			frame[name].z += math.sin(t * (if plan == "elephant" then 1.6 else 0.5)) * 0.12
		end)
	end
	if clip == "walk" or clip == "run" then
		local running = clip == "run"
		local rate = if running then 9 else (if heavy or slow then 2.6 else 5)
		local phase = t * rate * math.clamp((speed + 4) / (if running then 22 else 12), 0.6, 1.4)
		local swing = if running then 0.75 else (if heavy or slow then 0.28 else 0.42)
		-- Running mammals gallop: both hind legs strike together, the forelegs half a cycle later.
		local gallop = running and plan == "mammal"
		for _, side in { "L", "R" } do
			local s = if side == "L" then 1 else -1
			local p = if gallop then math.sin(phase + (if side == "L" then 0 else 0.35)) else math.sin(phase) * s
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
				-- Bird: wings held out for balance on the walk, flapped on the run.
				frame["Wing" .. side].y += s * (if running then 0.35 + math.sin(phase * 2) * 0.5 else 0.1)
			end
		end
		if gallop then
			frame.Spine.x += math.sin(phase) * 0.12
		end
		frame.Root.lift = math.abs(math.sin(phase)) * (if running then 0.06 else 0.025)
		if bird then
			-- Hop-waddle: two small hops per stride, the body rocking side to side.
			frame.Root.lift = math.abs(math.sin(phase * (if running then 2 else 1))) * (if running then 0.16 else 0.06)
			frame.Root.y += math.sin(phase) * 0.08
		end
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
	elseif clip == "swim" then
		-- Legs tucked (crocodilian) or paddling (turtle); the tail sculls; the body rides low.
		local phase = t * 3
		local croc = plan == "crocodilian"
		for i, name in tails(plan) do
			frame[name].z += math.sin(phase - i * 0.7) * (if croc then 0.35 else 0.15)
		end
		frame.Spine.z += math.sin(phase) * (if croc then 0.12 else 0.04)
		for _, side in { "L", "R" } do
			local s = if side == "L" then 1 else -1
			if croc then
				frame["Thigh" .. side].x -= 0.7
				frame["UpperArm" .. side].x += 0.7
			else
				frame["UpperArm" .. side].x += math.sin(phase + (if s > 0 then 0 else math.pi)) * 0.7
				frame["Forearm" .. side].x += math.max(0, math.sin(phase)) * 0.3
				frame["Thigh" .. side].x -= math.sin(phase + (if s > 0 then math.pi else 0)) * 0.4
			end
		end
		frame.Root.lift = -0.35
		frame.Head.x -= 0.08
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
		elseif kind == "tail" then
			-- Armored tail swing: the body pivots one way, the tail (plates, club) sweeps across.
			frame.Root.y += pulse * 0.35
			for i, name in tails(plan) do
				frame[name].z += pulse * (0.3 + 0.1 * i)
			end
			frame.Head.z -= pulse * 0.2
		elseif kind == "tusk" then
			-- Head-down sweep with the tusks, trunk curled up out of the way.
			frame.Root.forward = pulse * 0.2
			for _, name in necks(plan) do
				frame[name].x += pulse * 0.25
			end
			frame.Head.z += pulse * 0.5
			frame.Head.x += pulse * 0.2
			each(plan, "Trunk", function(name)
				frame[name].x -= pulse * 0.35
			end)
			each(plan, "Ear", function(name)
				frame[name].z += pulse * 0.4
			end)
		elseif kind == "lunge" then
			-- Crocodilian strike: a low burst forward, jaws wide, then a twisting shake.
			frame.Root.forward = pulse * 0.45
			frame.Head.x -= pulse * 0.2
			frame.Jaw.x += pulse * 0.9
			frame.Root.y += math.sin(t * 20) * pulse * 0.15
		elseif kind == "withdraw" then
			-- Turtle snap: the head pulls back toward the shell and snaps, the body hunkers down.
			for _, name in necks(plan) do
				frame[name].x += pulse * 0.6
			end
			frame.Head.x -= pulse * 0.4
			frame.Jaw.x += pulse * 0.45
			frame.Root.lift = -pulse * 0.15
		elseif kind == "flutter" then
			-- Bird: wings beat fast while it jumps forward and pecks.
			frame.Root.forward = pulse * 0.2
			frame.Root.lift = pulse * 0.25
			frame.WingL.y += (0.6 + math.sin(t * 30) * 0.6) * pulse
			frame.WingR.y -= (0.6 + math.sin(t * 30) * 0.6) * pulse
			frame.Head.x += pulse * 0.3
			frame.Jaw.x += pulse * 0.5
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
		frame.WingL.y += flinch * 0.6
		frame.WingR.y -= flinch * 0.6
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
	setmetatable(frame :: any, nil)
	return frame
end

return M
