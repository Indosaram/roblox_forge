--!strict
-- R20 rift look (D2c/D2 Studio: the drift-camp rift read as a flat glowing pink-white slab).
-- Durango's warp hole is a glowing red/orange crack-ring over a dark crater (R20-2/R20-3). Our
-- rift keeps its stone row (town.rift-ring) and gets, on one invisible host above the cleft:
--   * layered swirl: three flat, slowly spinning particle discs (outer haze, mid ring, hot core)
--     that read as a turning vortex from the quarter camera, each partly transparent;
--   * rising embers and a low ground haze around the lip;
--   * one warm unshadowed PointLight (the crater glow on the ground and the stones);
--   * the row's __glow cleft recoloured from teal-white Neon to an ember red with some
--     transparency, so bloom no longer turns it into a white slab.
-- Only existing approved textures are used (fx-puff, fx-spark, fx-ember; L13). Particle budget:
-- the summed emission rate stays at or under RATE_BUDGET per rift, and the host carries
-- ForgeEffectRank = 1 so the low phone profile keeps it (RenderBudget.keepEffect) while
-- ForgeDecorRank leaves the invisible host alone.
local M = {}

M.HOST = "ForgeRiftFx"
M.CORE = { 255, 92, 40 }
-- The cleft glow: a darker ember so the night exposure (SkyCycle NIGHT +1.8) and bloom keep it red.
M.CLEFT = { 190, 50, 20 }
M.RIM = { 255, 160, 70 }
M.HAZE = { 120, 40, 60 }
M.LIGHT = { brightness = 3, range = 18 }
-- The rift light rides the fire cycle (SkyCycle.applyFire via ForgeTorch): FIRE_SCALE x the
-- cycle's fire light, so it never washes the camp at night (Studio 01:00: a fixed 3/18 light
-- turned the drift camp lilac-white).
M.FIRE_SCALE = 1.2
M.RATE_BUDGET = 40

-- Swirl layers: name, texture key, colour, size (studs), transparency (start, end), spin (deg/s),
-- rate, lifetime, height over the cleft floor.
M.LAYERS = table.freeze({
	{
		name = "SwirlHaze",
		texture = "fx-puff",
		color = M.HAZE,
		size = 15,
		alpha = { 0.75, 1 },
		spin = 25,
		rate = 3,
		life = 3.2,
		y = 0.4,
	},
	{
		name = "SwirlRing",
		texture = "fx-puff",
		color = M.RIM,
		size = 9,
		alpha = { 0.45, 1 },
		spin = -60,
		rate = 4,
		life = 2.4,
		y = 0.7,
	},
	{
		name = "SwirlCore",
		texture = "fx-spark",
		color = M.CORE,
		size = 5,
		alpha = { 0.2, 1 },
		spin = 120,
		rate = 6,
		life = 1.4,
		y = 1,
	},
})
M.EMBERS = table.freeze({ name = "RiftEmbers", texture = "fx-ember", color = M.RIM, rate = 10, life = 2.6, speed = 5 })

--- Summed emission rate of one rift (spec: <= RATE_BUDGET).
function M.rate(): number
	local total = M.EMBERS.rate
	for _, layer in M.LAYERS do
		total += layer.rate
	end
	return total
end

--- RotSpeed range of a layer: 80-100% of its spin, ordered (a counter-spinning layer has a
--- negative spin; the engine refuses a NumberRange whose min exceeds its max).
function M.spinRange(spin: number): (number, number)
	return math.min(spin * 0.8, spin), math.max(spin * 0.8, spin)
end

local function rgb(value: { number }): Color3
	return Color3.fromRGB(value[1], value[2], value[3])
end

--- Builds the rift effects on `parent` at ground point `ground` (cleft floor). `glows` are the
--- row's __glow parts (recoloured); `assets` maps texture keys to content ids. Returns the host.
function M.build(parent: Instance, ground: Vector3, glows: { BasePart }, assets: { [string]: string }): BasePart
	for _, glow in glows do
		glow.Color, glow.Transparency = rgb(M.CLEFT), 0.2
		for _, light in glow:GetChildren() do
			if light:IsA("PointLight") then
				light:Destroy()
			end
		end
	end
	local host = Instance.new("Part")
	host.Name, host.Anchored, host.Transparency = M.HOST, true, 1
	host.Size = Vector3.new(1, 1, 1)
	host.CanCollide, host.CanQuery, host.CanTouch, host.CastShadow = false, false, false, false
	host.Position = ground + Vector3.new(0, 0.5, 0)
	host.CFrame = CFrame.new(host.Position)
	host:SetAttribute("ForgeEffectRank", 1)
	host:SetAttribute("ForgeTorch", true)
	host:SetAttribute("ForgeFireScale", M.FIRE_SCALE)
	for _, layer in M.LAYERS do
		local attachment = Instance.new("Attachment")
		attachment.Name, attachment.Position, attachment.Parent = layer.name, Vector3.new(0, layer.y, 0), host
		local value = Instance.new("ParticleEmitter")
		value.Name, value.Texture = layer.name, assets[layer.texture] or ""
		value.Color, value.LightEmission, value.LightInfluence = ColorSequence.new(rgb(layer.color)), 1, 0
		value.Size = NumberSequence.new(layer.size * 0.85, layer.size)
		value.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, layer.alpha[1]),
			NumberSequenceKeypoint.new(1, layer.alpha[2]),
		})
		value.Lifetime, value.Rate = NumberRange.new(layer.life * 0.8, layer.life), layer.rate
		-- Flat on the ground, turning in place: a disc that faces up and spins is the vortex.
		value.Orientation = Enum.ParticleOrientation.VelocityPerpendicular
		value.EmissionDirection, value.Speed = Enum.NormalId.Top, NumberRange.new(0.01)
		value.Rotation = NumberRange.new(0, 360)
		value.RotSpeed = NumberRange.new(M.spinRange(layer.spin))
		value.LockedToPart, value.ZOffset = true, -1
		value.Parent = attachment
	end
	local embers = Instance.new("ParticleEmitter")
	local e = M.EMBERS
	embers.Name, embers.Texture = e.name, assets[e.texture] or ""
	embers.Color, embers.LightEmission, embers.LightInfluence = ColorSequence.new(rgb(e.color)), 1, 0
	embers.Size = NumberSequence.new(0.5, 0.1)
	embers.Transparency = NumberSequence.new(0.1, 1)
	embers.Lifetime, embers.Rate = NumberRange.new(e.life * 0.6, e.life), e.rate
	embers.Speed, embers.SpreadAngle = NumberRange.new(e.speed * 0.6, e.speed), Vector2.new(35, 35)
	embers.Acceleration = Vector3.new(0, 1.5, 0)
	embers.Parent = host
	local light = Instance.new("PointLight")
	light.Name, light.Color = "RiftGlow", rgb(M.CORE)
	light.Brightness, light.Range, light.Shadows = M.LIGHT.brightness, M.LIGHT.range, false
	light.Parent = host
	host.Parent = parent
	return host
end

return M
