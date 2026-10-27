--!strict
-- G18 day-night (24-minute day) and climate weather. Pure functions take server seconds and the
-- recorded seed (day-night.spec.luau); ensure/apply/torch/start touch the engine (Roblox only).
local Rng = require("../../../../core/domain/random/Rng")
local Volcano = require("../../../../core/domain/survival/Volcano")
local M = {}

M.DAY_SECONDS = 24 * 60

type RGB = { number }

-- Day: warm and slightly desaturated (R13-6 day frames). Night: bright cool blue-grey moonlight
-- (R17-1): strong blue ambient, high exposure and a moon-coloured ColorShift_Top keep ground,
-- plants and the player readable like an overcast day with a blue cast; the sea's warm-grey
-- WaterColor turns slate under the cool tint instead of glowing royal blue; fires pool warm
-- light. `water` drives Terrain.WaterColor.
-- stylua: ignore start
local DAY: any = { brightness = 2.4, exposure = 0, ambient = { 118, 110, 98 }, outdoorAmbient = { 158, 148, 128 },
	colorShiftTop = { 255, 232, 196 }, colorShiftBottom = { 92, 82, 64 }, decay = { 132, 138, 140 },
	grade = { brightness = 0.02, contrast = 0.1, saturation = -0.12, tint = { 255, 242, 222 } },
	density = 0.26, haze = 1.1, glare = 0.25, bloom = 0.08, sunRays = 0.04, starCount = 0,
	water = { 69, 139, 153 }, fire = { brightness = 0.8, range = 10 } }
local NIGHT: any = { brightness = 2.2, exposure = 1.4, ambient = { 100, 126, 190 }, outdoorAmbient = { 116, 150, 228 },
	colorShiftTop = { 146, 180, 250 }, colorShiftBottom = { 50, 64, 100 }, decay = { 70, 86, 120 },
	grade = { brightness = 0.04, contrast = 0.06, saturation = -0.16, tint = { 180, 212, 255 } },
	fog = { 110, 130, 165 }, density = 0.28, haze = 0.8, glare = 0, bloom = 0.3, sunRays = 0, starCount = 3000,
	water = { 100, 92, 62 }, fire = { brightness = 2.6, range = 20 } }
-- stylua: ignore end
-- Sunrise/sunset push the warm grade further toward amber.
local GOLDEN_TINT = { 255, 214, 172 }

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function mix(a: RGB, b: RGB, t: number): RGB
	return {
		math.floor(lerp(a[1], b[1], t) + 0.5),
		math.floor(lerp(a[2], b[2], t) + 0.5),
		math.floor(lerp(a[3], b[3], t) + 0.5),
	}
end

local function smooth(x: number): number
	local t = math.clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Hour of day; day 0 starts at midnight of `origin`. One real minute is one game hour.
function M.clockTime(seconds: number, origin: number): number
	local phase = ((seconds - origin) % M.DAY_SECONDS) / M.DAY_SECONDS
	return (phase * 24) % 24
end

function M.daylight(hours: number): number
	return smooth((hours - 5.25) / 1.5) * (1 - smooth((hours - 17.25) / 1.5))
end

function M.golden(hours: number): number
	local near = math.min(math.abs(hours - 6.5), math.abs(hours - 17.5))
	return math.clamp(1 - near / 1.5, 0, 1)
end

function M.at(hours: number, fog: RGB): any
	local d = M.daylight(hours)
	local n = 1 - d
	local g = M.golden(hours) * d
	local tint = mix(mix(NIGHT.grade.tint, DAY.grade.tint, d), GOLDEN_TINT, g * 0.6)
	local function f(key: string): number
		return lerp(NIGHT[key], DAY[key], d)
	end
	local function c(key: string): RGB
		return mix(NIGHT[key], DAY[key], d)
	end
	local ng, dg = NIGHT.grade, DAY.grade
	-- stylua: ignore start
	return {
		clockTime = hours, daylight = d, golden = g, brightness = f("brightness"), exposure = f("exposure"),
		ambient = c("ambient"), outdoorAmbient = c("outdoorAmbient"), colorShiftBottom = c("colorShiftBottom"),
		colorShiftTop = mix(c("colorShiftTop"), GOLDEN_TINT, g * 0.5),
		grade = { brightness = lerp(ng.brightness, dg.brightness, d), contrast = lerp(ng.contrast, dg.contrast, d),
			saturation = lerp(ng.saturation, dg.saturation, d), tint = tint },
		atmosphere = { color = mix(NIGHT.fog, mix(fog, GOLDEN_TINT, g * 0.35), d), decay = c("decay"),
			density = f("density"), haze = f("haze"), glare = f("glare") },
		bloom = f("bloom"), sunRays = f("sunRays"), starCount = math.floor(f("starCount") + 0.5), water = c("water"),
		fire = { brightness = lerp(DAY.fire.brightness, NIGHT.fire.brightness, n),
			range = lerp(DAY.fire.range, NIGHT.fire.range, n) },
	}
	-- stylua: ignore end
end

function M.state(seconds: number, origin: number, fog: RGB): any
	return M.at(M.clockTime(seconds, origin), fog)
end

M.WINDOW_SECONDS = 240

-- rain/ash: particle rate per emitter at full quality.
M.VISUALS = {
	clear = { rain = 0, ash = 0, fogDensity = 0, fogHaze = 0, dim = 0 },
	rain = { rain = 220, ash = 0, fogDensity = 0.08, fogHaze = 0.6, dim = 0.15 },
	fog = { rain = 0, ash = 0, fogDensity = 0.3, fogHaze = 2.4, dim = 0.08 },
	storm = { rain = 400, ash = 0, fogDensity = 0.16, fogHaze = 1.2, dim = 0.3 },
	collapse = { rain = 0, ash = 60, fogDensity = 0.2, fogHaze = 1.6, dim = 0.25 },
	ash = { rain = 0, ash = 140, fogDensity = 0.22, fogHaze = 1.8, dim = 0.28 },
	haze = { rain = 0, ash = 20, fogDensity = 0.06, fogHaze = 1.4, dim = 0.05 },
}

-- Weighted weather per primary biome (unknown biomes use grassland).
-- stylua: ignore start
local function w(clear: number, rain: number, fog: number, storm: number, haze: number): any
	return { { id = "clear", weight = clear }, { id = "rain", weight = rain }, { id = "fog", weight = fog },
		{ id = "storm", weight = storm }, { id = "haze", weight = haze } }
end
M.CLIMATES = { grassland = w(6, 3, 1, 0, 0), forest = w(5, 3, 2, 0, 0), beach = w(7, 2, 0, 1, 0),
	tropical = w(4, 4, 0, 2, 0), swamp = w(3, 3, 4, 0, 0), desert = w(7, 0, 0, 0, 3), snow = w(5, 0, 5, 0, 0) }
-- stylua: ignore end

local function visual(id: string): any
	local result = table.clone(M.VISUALS[id] or M.VISUALS.clear)
	result.id = id
	return result
end

function M.climate(content: any, layout: any): string
	if content.brawlPolicy and content.brawlPolicy.layout == layout.id then
		return "brawl"
	elseif table.find(layout.biomes, "volcano") and (content.progressionPolicy or {}).volcano then
		return "volcano"
	end
	return "seeded"
end

function M.seeded(layout: any, seed: number, window: number): string
	local entries = M.CLIMATES[layout.biomes[1]] or M.CLIMATES.grassland
	local total = 0
	for _, entry in entries do
		total += entry.weight
	end
	local roll = Rng.new(seed):fork("weather:" .. layout.id .. ":" .. tostring(window)):nextInteger(1, total)
	for _, entry in entries do
		roll -= entry.weight
		if roll <= 0 then
			return entry.id
		end
	end
	return entries[1].id
end

-- Volcano layouts follow progressionPolicy.volcano's storm wave (the exposure timeline); the brawl
-- layout follows brawlPolicy.weather from `brawl.startsAt`; others draw a seeded window weather.
function M.weatherAt(content: any, layout: any, seed: number, seconds: number, origin: number, brawl: any?): any
	local climate = M.climate(content, layout)
	if climate == "volcano" then
		local stormy = Volcano.storm(seconds, origin, content.progressionPolicy.volcano)
		return visual(if stormy then "ash" else "haze")
	elseif climate == "brawl" then
		if brawl and brawl.startsAt and seconds >= brawl.startsAt then
			local elapsed = seconds - brawl.startsAt
			local selected = brawl.policy.weather[1]
			for _, weather in brawl.policy.weather do
				if elapsed >= weather.at then
					selected = weather
				end
			end
			return visual(selected.id)
		end
		return visual("clear")
	end
	return visual(M.seeded(layout, seed, (seconds - origin) // M.WINDOW_SECONDS))
end

function M.origin(layoutId: string, seed: number, epoch: number): number
	return epoch - Rng.new(seed):fork("weather-origin:" .. layoutId):nextInteger(0, 3600)
end

function M.particleScale(profile: string): number
	return if profile == "low" then 0.3 else 1
end

M.SKY = "ForgeSky"
M.GRADE = "ForgeWarmGrade"
M.BLOOM = "ForgeEmberBloom"
M.RAYS = "ForgeSunRays"
M.ATMOSPHERE = "ForgeBiomeAtmosphere"
M.TORCH_ATTRIBUTE = "ForgeTorch"

local function rgb(value: { number }): Color3
	return Color3.fromRGB(value[1], value[2], value[3])
end

local function ensure(lighting: Instance, class: string, name: string): any
	local found = lighting:FindFirstChild(name)
	if found and found:IsA(class) then
		return found
	end
	local value = Instance.new(class)
	value.Name, value.Parent = name, lighting
	return value
end

function M.ensure(lighting: Instance)
	local sky = ensure(lighting, "Sky", M.SKY)
	sky.CelestialBodiesShown, sky.SunAngularSize, sky.MoonAngularSize = true, 14, 9
	ensure(lighting, "ColorCorrectionEffect", M.GRADE)
	ensure(lighting, "BloomEffect", M.BLOOM).Size = 14
	ensure(lighting, "SunRaysEffect", M.RAYS).Spread = 0.5
	ensure(lighting, "Atmosphere", M.ATMOSPHERE).Offset = 0.12
end

function M.apply(lighting: any, state: any, weather: any, atmosphere: boolean, terrain: any?)
	local dim = 1 - weather.dim
	if terrain then
		terrain.WaterColor = rgb(state.water)
	end
	lighting.ClockTime = state.clockTime
	lighting.Brightness = state.brightness * dim
	lighting.ExposureCompensation = state.exposure
	lighting.Ambient = rgb(state.ambient)
	lighting.OutdoorAmbient = rgb(state.outdoorAmbient)
	lighting.ColorShift_Top = rgb(state.colorShiftTop)
	lighting.ColorShift_Bottom = rgb(state.colorShiftBottom)
	local sky = lighting:FindFirstChild(M.SKY)
	if sky then
		sky.StarCount = if weather.dim > 0.1 then 0 else state.starCount
	end
	local grade = lighting:FindFirstChild(M.GRADE)
	if grade then
		grade.Brightness, grade.Contrast = state.grade.brightness, state.grade.contrast
		grade.Saturation, grade.TintColor = state.grade.saturation - weather.dim * 0.15, rgb(state.grade.tint)
	end
	local bloom = lighting:FindFirstChild(M.BLOOM)
	if bloom then
		bloom.Intensity, bloom.Threshold = state.bloom, 1.8
	end
	local rays = lighting:FindFirstChild(M.RAYS)
	if rays then
		rays.Intensity = state.sunRays * dim
	end
	local air = lighting:FindFirstChild(M.ATMOSPHERE)
	if air then
		air.Color, air.Decay = rgb(state.atmosphere.color), rgb(state.atmosphere.decay)
		air.Glare = state.atmosphere.glare * dim
		if atmosphere then
			air.Density = math.min(state.atmosphere.density + weather.fogDensity, 0.6)
			air.Haze = state.atmosphere.haze + weather.fogHaze
		end
	end
end

function M.isFireLight(light: any): boolean
	local host = light.Parent
	return light:IsA("PointLight")
		and host ~= nil
		and (
			host:FindFirstChildOfClass("Fire") ~= nil
			or host:FindFirstChild("ForgeEffect") ~= nil
			or host:GetAttribute(M.TORCH_ATTRIBUTE) == true
		)
end

function M.applyFire(light: any, state: any)
	light.Brightness, light.Range = state.fire.brightness, state.fire.range
	light.Shadows = false
end

function M.torch(parent: Instance, at: Vector3): BasePart
	local pole = Instance.new("Part")
	pole.Name, pole.Anchored, pole.Size = "ForgeTorchPole", true, Vector3.new(0.5, 5, 0.5)
	pole.Material, pole.Color = Enum.Material.Wood, Color3.fromRGB(96, 66, 40)
	pole.CFrame = CFrame.new(at + Vector3.new(0, 2.5, 0))
	pole.CanCollide, pole.CanQuery, pole.CanTouch = false, false, false
	pole.Parent = parent
	local head = Instance.new("Part")
	head.Name, head.Anchored, head.Size = "ForgeTorchHead", true, Vector3.new(0.9, 0.7, 0.9)
	head.Material, head.Color = Enum.Material.Neon, Color3.fromRGB(255, 132, 40)
	head.CFrame = CFrame.new(at + Vector3.new(0, 5.3, 0))
	head.CanCollide, head.CanQuery, head.CanTouch = false, false, false
	head:SetAttribute(M.TORCH_ATTRIBUTE, true)
	head.Parent = parent
	local fire = Instance.new("Fire")
	fire.Size, fire.Heat, fire.Parent = 1.5, 3, head
	local light = Instance.new("PointLight")
	light.Color, light.Brightness, light.Range, light.Parent = Color3.fromRGB(255, 150, 70), 0.8, 10, head
	return head
end

M.STEP_SECONDS = 0.25

local function emitter(
	parent: Instance,
	name: string,
	texture: string,
	r: number,
	g: number,
	b: number,
	life: number,
	speed: number
): ParticleEmitter
	local value = Instance.new("ParticleEmitter")
	value.Name, value.Rate, value.LockedToPart = name, 0, false
	value.Texture = "rbxasset://textures/particles/" .. texture .. ".dds"
	value.Color, value.LightEmission, value.LightInfluence = ColorSequence.new(Color3.fromRGB(r, g, b)), 0, 1
	value.Lifetime, value.Speed = NumberRange.new(life * 0.75, life), NumberRange.new(speed * 0.8, speed * 1.1)
	value.EmissionDirection, value.SpreadAngle = Enum.NormalId.Bottom, Vector2.new(4, 4)
	value.Parent = parent
	return value
end

function M.start(ctx: any): () -> ()
	local lighting: any = game:GetService("Lighting")
	local camera = workspace.CurrentCamera
	-- One client-local emitter volume that follows the camera; rain streaks and ash flakes.
	local volume = Instance.new("Part")
	volume.Name, volume.Anchored, volume.Transparency = "ForgeWeatherVolume", true, 1
	volume.Size = Vector3.new(140, 1, 140)
	volume.CanCollide, volume.CanQuery, volume.CanTouch, volume.CastShadow = false, false, false, false
	local rain = emitter(volume, "ForgeRain", "sparkles_main", 196, 214, 232, 1.1, 90)
	rain.Size, rain.Squash, rain.Transparency =
		NumberSequence.new(0.18), NumberSequence.new(-2.5), NumberSequence.new(0.35)
	rain.Orientation = Enum.ParticleOrientation.VelocityParallel
	local ash = emitter(volume, "ForgeAsh", "smoke_main", 92, 86, 80, 7, 6)
	ash.Size = NumberSequence.new(0.6, 1.4)
	ash.Transparency = NumberSequence.new(0.3, 1)
	ash.RotSpeed, ash.SpreadAngle = NumberRange.new(-40, 40), Vector2.new(30, 30)
	volume.Parent = camera

	local fires: { [Instance]: boolean } = {}
	local function track(object: Instance)
		if object:IsA("PointLight") and M.isFireLight(object) then
			fires[object] = true
		elseif object:IsA("Fire") or object.Name == "ForgeEffect" then
			local light = object.Parent and object.Parent:FindFirstChildOfClass("PointLight")
			if light then
				fires[light] = true
			end
		end
	end
	for _, object in workspace:GetDescendants() do
		track(object)
	end
	local added = workspace.DescendantAdded:Connect(track)
	local removing = workspace.DescendantRemoving:Connect(function(object)
		fires[object] = nil
	end)

	local layoutId: string? = nil
	local layout: any = nil
	local fireBrightness = -1
	local elapsed = M.STEP_SECONDS
	local stepping = game:GetService("RunService").Heartbeat:Connect(function(dt: number)
		volume.CFrame = CFrame.new(camera.CFrame.Position + Vector3.new(0, 45, 0))
		elapsed += dt
		if elapsed < M.STEP_SECONDS then
			return
		end
		elapsed = 0
		local origin = workspace:GetAttribute("ForgeSkyOrigin")
		local id = workspace:GetAttribute("ForgeSkyLayout")
		if type(origin) ~= "number" or type(id) ~= "string" then
			return
		end
		if id ~= layoutId then
			layoutId, layout = id, nil
			for _, candidate in ctx.content.layouts do
				if candidate.id == id then
					layout = candidate
				end
			end
		end
		if not layout then
			return
		end
		local now = workspace:GetServerTimeNow()
		local fog: any = workspace:GetAttribute("ForgeSkyFog")
		local palette = if typeof(fog) == "Color3"
			then { math.floor(fog.R * 255 + 0.5), math.floor(fog.G * 255 + 0.5), math.floor(fog.B * 255 + 0.5) }
			else { 192, 215, 205 }
		local startsAt = workspace:GetAttribute("ForgeBrawlStartsAt")
		local brawl = if type(startsAt) == "number"
			then { startsAt = startsAt, policy = ctx.content.brawlPolicy }
			else nil
		local stormOrigin = workspace:GetAttribute("ForgeStormOrigin")
		local state = M.state(now, origin, palette)
		local weather = M.weatherAt(
			ctx.content,
			layout,
			workspace:GetAttribute("ForgeSkySeed") or 0,
			now,
			if type(stormOrigin) == "number" then stormOrigin else origin,
			brawl
		)
		local reduced = ctx.reduced()
		M.apply(lighting, state, weather, not ctx.aerial() and not reduced, workspace.Terrain)
		-- Phones: fewer particles and no sun rays; reduced effects: none.
		local low = ctx.low()
		local scale = if reduced then 0 else M.particleScale(if low then "low" else "high")
		rain.Rate, ash.Rate = weather.rain * scale, weather.ash * scale
		local rays = lighting:FindFirstChild(M.RAYS)
		if rays then
			rays.Enabled = not low
		end
		if math.abs(state.fire.brightness - fireBrightness) > 0.05 then
			fireBrightness = state.fire.brightness
			for light in fires do
				M.applyFire(light, state)
			end
		end
	end)
	return function()
		stepping:Disconnect()
		added:Disconnect()
		removing:Disconnect()
		volume:Destroy()
	end
end

return M
