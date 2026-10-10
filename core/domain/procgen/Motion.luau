--!strict
-- Motion: pure, engine-free procedural motion for generated creatures. Given a
-- profile name, an absolute time t (seconds), and a seed, it returns the local
-- offset, pitch/yaw/roll, and scale to apply to a model's base pivot. Every
-- profile is a closed-form sine over t, so sampling is deterministic and
-- periodic; the seed only shifts the phase, which keeps creatures desynced
-- without any per-instance randomness at runtime.

local Motion = {}

export type Vec3 = { x: number, y: number, z: number }

export type Sample = {
	offset: Vec3,
	pitch: number,
	yaw: number,
	roll: number,
	scale: Vec3,
}

-- A profile is either a bare name ("idle", "walk", "serpent", "hatch",
-- "celebrate") or a name plus a period multiplier. profileFor uses the table
-- form to give titans a slower idle.
export type Profile = string | { name: string, periodScale: number? }

-- Loop period in seconds per profile. "hatch" is a one-shot and has no period.
local PERIODS: { [string]: number } = {
	idle = 3.0,
	walk = 0.9,
	serpent = 2.4,
	celebrate = 1.1,
}

-- Seconds a "hatch" one-shot spans; t is normalized 0..1 over this window.
Motion.HATCH_DURATION = 0.9

local C1 = 1.70158
local C3 = C1 + 1

local function seedPhase(seed: number): number
	local x = math.sin(seed * 12.9898 + 78.233) * 43758.5453
	return (x - math.floor(x)) * math.pi * 2
end

local function normalize(profile: Profile): (string, number)
	local name = "idle"
	local periodScale = 1
	if type(profile) == "table" then
		name = profile.name
		periodScale = profile.periodScale or 1
	elseif type(profile) == "string" then
		name = profile
	end
	if name ~= "hatch" and PERIODS[name] == nil then
		name = "idle"
	end
	return name, periodScale
end

local function clamp01(value: number): number
	if value < 0 then
		return 0
	elseif value > 1 then
		return 1
	end
	return value
end

-- Overshoots past 1 before settling exactly on 1 at t == 1.
local function easeOutBack(t: number): number
	local u = t - 1
	return 1 + C3 * u * u * u + C1 * u * u
end

--- Maps a creature archetype to its motion profile. Quad/biped breathe, serpents
--- sway, and titans use the idle profile at a 1.6x longer period.
function Motion.profileFor(archetype: string?): Profile
	if archetype == "serpent" then
		return { name = "serpent", periodScale = 1 }
	elseif archetype == "titan" then
		return { name = "idle", periodScale = 1.6 }
	end
	return { name = "idle", periodScale = 1 }
end

--- The loop period of `profile` in seconds, or 0 for one-shot profiles.
function Motion.periodOf(profile: Profile): number
	local name, periodScale = normalize(profile)
	local period = PERIODS[name]
	if period == nil then
		return 0
	end
	return period * periodScale
end

--- Samples `profile` at absolute time `t` for a creature identified by `seed`.
function Motion.sample(profile: Profile, t: number, seed: number): Sample
	local name, periodScale = normalize(profile)
	local phase = seedPhase(seed)
	local offset: Vec3 = { x = 0, y = 0, z = 0 }
	local pitch, yaw, roll = 0, 0, 0
	local scale: Vec3 = { x = 1, y = 1, z = 1 }

	if name == "hatch" then
		local progress = clamp01(t)
		local pop = 0.25 + 0.75 * easeOutBack(progress)
		scale.x = pop
		scale.y = pop * (1 + 0.06 * (1 - progress))
		scale.z = pop
		offset.y = 0.12 * math.sin(math.pi * progress)
	elseif name == "walk" then
		local a = (math.pi * 2 / (PERIODS.walk * periodScale)) * t + phase
		offset.y = 0.1 * math.abs(math.sin(a))
		pitch = 0.12 * math.sin(a * 2)
		roll = 0.05 * math.cos(a)
	elseif name == "serpent" then
		local a = (math.pi * 2 / (PERIODS.serpent * periodScale)) * t + phase
		yaw = 0.35 * math.sin(a)
		offset.x = 0.06 * math.sin(a * 2)
		scale.y = 1 + 0.02 * math.sin(a * 2)
	elseif name == "celebrate" then
		local a = (math.pi * 2 / (PERIODS.celebrate * periodScale)) * t + phase
		offset.y = 0.5 * math.abs(math.sin(a))
		pitch = -0.15 * math.sin(a)
		local squash = 1 + 0.06 * math.cos(a * 2)
		scale.y = squash
		scale.x = 1 / squash
		scale.z = 1 / squash
	else
		local a = (math.pi * 2 / (PERIODS.idle * periodScale)) * t + phase
		local amplitude = 0.02 + 0.02 * (0.5 + 0.5 * math.sin(seed * 7.137))
		local breath = math.sin(a)
		scale.y = 1 + amplitude * breath
		scale.x = 1 - amplitude * 0.5 * breath
		scale.z = 1 - amplitude * 0.5 * breath
		yaw = 0.04 * math.sin(a)
		offset.y = 0.015 * math.sin(a)
	end

	return { offset = offset, pitch = pitch, yaw = yaw, roll = roll, scale = scale }
end

return Motion
