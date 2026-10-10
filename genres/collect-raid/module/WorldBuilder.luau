--!strict
-- WorldBuilder: builds a generic collect-raid world from pure `layout` data and
-- a `theme` table. Every instance name, attribute, position, and prompt parent
-- is part of the contract gameplay code reads back, so packs only supply data.

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local Terrain = Workspace.Terrain
local WorldBuilderMath = require("./WorldBuilderMath")

export type Vec = { x: number, y: number, z: number }
export type Rgb = { r: number, g: number, b: number }

export type GroundLayout = {
	cells: number,
	cellSize: number,
	originX: number,
	originZ: number,
	y: number,
	thickness: number,
}

export type ParadeLayout = {
	name: string,
	positions: { Vec },
}

export type BaseLayout = {
	team: string,
	center: Vec,
	size: Vec,
	spawn: Vec,
	spawnTeamColor: string,
	incubators: { Vec },
	vault: Vec,
	parade: ParadeLayout,
	shop: Vec,
	color: Rgb,
}

export type ArenaLayout = {
	center: Vec,
	radius: number,
	covers: { { position: Vec, size: Vec } },
	torches: { Vec },
}

export type Decoration = {
	kind: string,
	position: Vec,
	scale: Vec,
	seed: number,
}

export type Layout = {
	name: string?,
	ground: GroundLayout,
	bases: { BaseLayout },
	arena: ArenaLayout,
	decorations: { Decoration }?,
	flowers: { Decoration }?,
}

export type SkyTheme = {
	celestialBodiesShown: boolean?,
	sunAngularSize: number?,
	starCount: number?,
	skybox: { [string]: string }?,
}

export type CloudsTheme = {
	cover: number?,
	density: number?,
	color: Color3?,
}

export type DepthOfFieldTheme = {
	farIntensity: number?,
	focusDistance: number?,
	inFocusRadius: number?,
	nearIntensity: number?,
}

export type LightingTheme = {
	technology: string?,
	clockTime: number,
	brightness: number,
	ambient: Color3,
	outdoorAmbient: Color3?,
	globalShadows: boolean?,
	shadowSoftness: number?,
	environmentDiffuseScale: number?,
	environmentSpecularScale: number?,
	fogEnd: number?,
	sky: SkyTheme?,
	clouds: CloudsTheme?,
	atmosphere: { density: number, haze: number, color: Color3, decay: Color3? }?,
	colorCorrection: { saturation: number, contrast: number }?,
	bloom: { intensity: number, size: number, threshold: number }?,
	sunRays: { intensity: number }?,
	depthOfField: DepthOfFieldTheme?,
}

export type TerrainTheme = {
	enabled: boolean?,
	half: number,
	flatHalf: number,
	cellSize: number,
	baseY: number,
	hillHeight: number,
	waterLevel: number,
	waterDepth: number,
	columnDepth: number,
	noiseScale: number,
	seed: number,
	water: { color: Color3, waveSize: number, waveSpeed: number, transparency: number, reflectance: number },
}

export type DetailTheme = {
	cornerRadius: number?,
	fenceHeight: number?,
	fencePostSpacing: number?,
	bannerHeight: number?,
	flagHeight: number?,
	standRadius: number?,
	standCount: number?,
	incubatorSparkleRate: number?,
	fireflyRate: number?,
	dustRate: number?,
}

export type Theme = {
	palette: { [string]: any },
	materials: { [string]: Enum.Material },
	particles: { [string]: string }?,
	terrain: TerrainTheme?,
	detail: DetailTheme?,
	lighting: LightingTheme,
	budget: { worldPartsMax: number }?,
}

-- decorate(kind, cframe, scale, seed) may return a custom Instance for a
-- decoration; returning nil falls back to a simple Part.
export type BuildOpts = {
	decorate: ((kind: string, cframe: CFrame, scale: Vector3, seed: number) -> Instance?)?,
}

local WorldBuilder = {}

local SKYBOX_KEYS: { [string]: boolean } = {
	SkyboxBk = true,
	SkyboxDn = true,
	SkyboxFt = true,
	SkyboxLf = true,
	SkyboxRt = true,
	SkyboxUp = true,
}

local function v(p: Vec): Vector3
	return Vector3.new(p.x, p.y, p.z)
end

local function rgb(c: Rgb): Color3
	return Color3.fromRGB(c.r, c.g, c.b)
end

local function part(props: { [string]: any }, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function makeBillboard(parent: Instance, text: string, color: Color3, offset: Vector3): BillboardGui
	local gui = Instance.new("BillboardGui")
	-- Stud-scaled so labels shrink with distance, and depth-tested (not AlwaysOnTop)
	-- so a far base's label cannot draw over a nearer one.
	gui.Size = UDim2.fromScale(10, 2.5)
	gui.StudsOffset = offset
	gui.AlwaysOnTop = false
	gui.MaxDistance = 120
	gui.LightInfluence = 0
	gui.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = color
	label.Font = Enum.Font.GothamBold
	label.Parent = gui

	return gui
end

-- Team-colored text painted onto a banner's face.
local function makeSurfaceText(parent: BasePart, text: string, color: Color3, face: Enum.NormalId): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = color
	label.Font = Enum.Font.GothamBlack
	label.Parent = gui

	return gui
end

-- Team color: theme palette wins, the layout's own rgb is the fallback.
local function teamColor(base: BaseLayout, theme: Theme): Color3
	local fromTheme = theme.palette[string.lower(base.team)]
	if typeof(fromTheme) == "Color3" then
		return fromTheme
	end
	return rgb(base.color)
end

local function buildGround(parent: Instance, ground: GroundLayout, theme: Theme): ()
	local colors = theme.palette.ground
	for gx = 0, ground.cells - 1 do
		for gz = 0, ground.cells - 1 do
			local cell = WorldBuilderMath.groundCellPosition(ground, gx, gz)
			part({
				Name = "Ground",
				Size = Vector3.new(ground.cellSize, ground.thickness, ground.cellSize),
				Position = Vector3.new(cell.x, ground.y, cell.z),
				Material = theme.materials.ground,
				Color = colors[WorldBuilderMath.groundCellVariant(gx, gz)],
			}, parent)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Terrain

-- Replaces the flat ground Parts with workspace.Terrain: a grass plateau with
-- procedural hills, a sand path from each base to the arena, and an edge lake.
-- Returns false (after clearing its region) so the caller can fall back to Parts.
local function buildTerrain(t: TerrainTheme, layout: Layout, theme: Theme): boolean
	local spec: WorldBuilderMath.TerrainSpec = {
		half = t.half,
		flatHalf = t.flatHalf,
		cellSize = t.cellSize,
		baseY = t.baseY,
		hillHeight = t.hillHeight,
		waterLevel = t.waterLevel,
		waterDepth = t.waterDepth,
		columnDepth = t.columnDepth,
		noiseScale = t.noiseScale,
		seed = t.seed,
	}

	local region = Region3.new(Vector3.new(-t.half, -100, -t.half), Vector3.new(t.half, 80, t.half))
	local function clear(): ()
		Terrain:FillRegion(region, 4, Enum.Material.Air)
	end

	local ok = pcall(function()
		clear()

		local materials: { [string]: Enum.Material } = {
			grass = theme.materials.terrainGrass,
			rock = theme.materials.terrainRock,
		}
		for _, col in WorldBuilderMath.terrainColumns(spec) do
			local height = col.top - col.bottom
			if height > 0.1 then
				Terrain:FillBlock(
					CFrame.new(col.x, (col.top + col.bottom) / 2, col.z),
					Vector3.new(spec.cellSize, height, spec.cellSize),
					materials[col.kind] or materials.grass
				)
			end
			if col.waterTop then
				local waterHeight = col.waterTop - col.top
				if waterHeight > 0.1 then
					Terrain:FillBlock(
						CFrame.new(col.x, (col.top + col.waterTop) / 2, col.z),
						Vector3.new(spec.cellSize, waterHeight, spec.cellSize),
						Enum.Material.Water
					)
				end
			end
		end

		for _, base in layout.bases do
			local span =
				WorldBuilderMath.pathBetween(base.center, base.size.x / 2, layout.arena.radius, layout.arena.center)
			if span then
				Terrain:FillBlock(
					CFrame.new(span.position.x, t.baseY - 0.5, span.position.z) * CFrame.Angles(0, span.yaw, 0),
					Vector3.new(span.size.x, 1, span.size.z),
					theme.materials.sand
				)
			end
		end

		Terrain.WaterColor = t.water.color
		Terrain.WaterWaveSize = t.water.waveSize
		Terrain.WaterWaveSpeed = t.water.waveSpeed
		Terrain.WaterTransparency = t.water.transparency
		Terrain.WaterReflectance = t.water.reflectance
	end)

	if not ok then
		pcall(clear)
	end
	return ok
end

-- ---------------------------------------------------------------------------
-- Base / arena detail

local function buildIncubatorDetail(model: Instance, p: Vector3, color: Color3, theme: Theme): ()
	local materials = theme.materials
	part({
		Name = "Pedestal",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.8, 9, 9),
		CFrame = CFrame.new(p + Vector3.new(0, -0.2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Material = materials.pedestal,
		Color = theme.palette.platform,
	}, model)

	part({
		Name = "GlowRing",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.25, 9.6, 9.6),
		CFrame = CFrame.new(p + Vector3.new(0, 0.35, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Material = materials.trim,
		Color = color,
		CanCollide = false,
	}, model)
end

-- Floating sparkles that hover over a base's incubators.
local function addSparkles(
	anchor: BasePart,
	texture: string,
	color: Color3,
	rate: number,
	lift: number
): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = texture
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 1
	emitter.Rate = rate
	emitter.Lifetime = NumberRange.new(2, 4.5)
	emitter.Speed = NumberRange.new(0.3, 1.4)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, lift, 0)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = anchor
	return emitter
end

local function buildBase(parent: Instance, b: BaseLayout, arena: ArenaLayout, theme: Theme, terrainOk: boolean): ()
	local color = teamColor(b, theme)
	local half = b.size.x / 2
	local detail: DetailTheme = theme.detail or {}
	local materials = theme.materials
	local openDir = if b.center.x < 0 then 1 else -1

	local folder = Instance.new("Folder")
	folder.Name = b.team .. "Base"
	folder.Parent = parent

	part({
		Name = "Platform",
		Size = Vector3.new(b.size.x, 2, b.size.z),
		Position = Vector3.new(b.center.x, 0.5, b.center.z),
		Material = materials.platform,
		Color = theme.palette.platform,
	}, folder)

	-- Rounded corners: vertical cylinders that cap the platform's sharp edges.
	local cornerRadius = detail.cornerRadius or 2.5
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			part({
				Name = "Corner" .. tostring(sx) .. tostring(sz),
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(2, cornerRadius * 2, cornerRadius * 2),
				CFrame = CFrame.new(b.center.x + sx * half, 0.5, b.center.z + sz * half)
					* CFrame.Angles(0, 0, math.rad(90)),
				Material = materials.platform,
				Color = theme.palette.platform,
			}, folder)
		end
	end

	for i, trim in WorldBuilderMath.platformTrims(b.center, half) do
		part({
			Name = "Trim" .. i,
			Size = v(trim.size),
			Position = v(trim.position),
			Material = materials.trim,
			Color = color,
		}, folder)
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = b.team .. "Spawn"
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.Position = v(b.spawn)
	spawn.Anchored = true
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.BottomSurface = Enum.SurfaceType.Smooth
	spawn.TeamColor = BrickColor.new(b.spawnTeamColor :: any)
	spawn.Neutral = false
	spawn.AllowTeamChangeOnTouch = false
	spawn.Duration = 0
	spawn.Parent = folder

	for i, incubatorPos in b.incubators do
		local p = v(incubatorPos)
		local model = Instance.new("Model")
		model.Name = "Incubator" .. i
		model:SetAttribute("Team", b.team)
		model:SetAttribute("Index", i)

		local base = part({
			Name = "Base",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.5, 7, 7),
			CFrame = CFrame.new(p) * CFrame.Angles(0, 0, math.rad(90)),
			Material = materials.metal,
			Color = theme.palette.metal,
		}, model)

		local dome = part({
			Name = "Dome",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(6, 6, 6),
			Position = p + Vector3.new(0, 2.5, 0),
			Material = materials.glass,
			Transparency = 0.45,
			Color = theme.palette.glass,
			CanCollide = false,
		}, model)

		part({
			Name = "Ring",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.4, 7.6, 7.6),
			CFrame = CFrame.new(p + Vector3.new(0, 0.9, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Material = materials.trim,
			Color = color,
		}, model)

		buildIncubatorDetail(model, p, color, theme)

		local light = Instance.new("PointLight")
		light.Range = 10
		light.Brightness = 1.5
		light.Color = color
		light.Parent = dome

		if theme.particles then
			addSparkles(base, theme.particles.sparkle or "", color, detail.incubatorSparkleRate or 4, 1.2)
		end

		local attach = Instance.new("Attachment")
		attach.Name = "EggPoint"
		attach.Position = Vector3.new(0, 2, 0)
		attach.Parent = base

		model.PrimaryPart = base
		model.Parent = folder
	end

	local vault = Instance.new("Model")
	vault.Name = b.team .. "Vault"
	vault:SetAttribute("Team", b.team)
	local vaultPos = v(b.vault)

	local crate = part({
		Name = "Crate",
		Size = Vector3.new(10, 8, 10),
		Position = vaultPos + Vector3.new(0, 2, 0),
		Material = materials.crate,
		Color = theme.palette.crate,
	}, vault)

	part({
		Name = "Band",
		Size = Vector3.new(10.2, 1, 10.2),
		Position = vaultPos + Vector3.new(0, 4, 0),
		Material = materials.trim,
		Color = color,
	}, vault)

	makeBillboard(crate, string.upper(b.team) .. " VAULT", color, Vector3.new(0, 7, 0))
	vault.PrimaryPart = crate
	vault.Parent = folder

	for k, slotPos in b.parade.positions do
		part({
			Name = b.parade.name .. k,
			Size = Vector3.new(4, 0.4, 4),
			Position = v(slotPos),
			Material = materials.slot,
			Color = theme.palette.slot,
		}, folder):SetAttribute("Team", b.team)
	end

	local shop = part({
		Name = "Shop",
		Size = Vector3.new(6, 6, 3),
		Position = v(b.shop),
		Material = materials.shop,
		Color = theme.palette.wood,
	}, folder)
	makeBillboard(shop, "SHOP", color, Vector3.new(0, 5, 0))

	-- Team banners on the back wall, facing the arena.
	local bannerHeight = detail.bannerHeight or 10
	local bannerFace = if openDir > 0 then Enum.NormalId.Right else Enum.NormalId.Left
	for _, bz in { -22, 22 } do
		local banner = part({
			Name = "Banner" .. tostring(bz),
			Size = Vector3.new(0.4, bannerHeight, 12),
			Position = Vector3.new(b.center.x - openDir * (half - 1), bannerHeight / 2, b.center.z + bz),
			Material = materials.banner,
			Color = theme.palette.banner,
			CanCollide = false,
		}, folder)
		makeSurfaceText(banner, string.upper(b.team), color, bannerFace)
	end

	-- Flag poles at the two front corners.
	local flagHeight = detail.flagHeight or 15
	for _, fz in { -1, 1 } do
		local flagPos = Vector3.new(b.center.x + openDir * (half - 6), 0, b.center.z + fz * 32)
		part({
			Name = "FlagPole" .. tostring(fz),
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(flagHeight, 0.5, 0.5),
			CFrame = CFrame.new(flagPos + Vector3.new(0, flagHeight / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Material = materials.metal,
			Color = theme.palette.metal,
		}, folder)
		part({
			Name = "Flag" .. tostring(fz),
			Size = Vector3.new(0.2, 3, 5),
			Position = flagPos + Vector3.new(0, flagHeight - 2.5, 2.5),
			Material = materials.flag,
			Color = color,
			CanCollide = false,
		}, folder)
	end

	-- Fence around three sides, leaving the arena-facing edge open.
	for i, seg in
		WorldBuilderMath.fenceSegments(
			b.center,
			half,
			detail.fenceHeight or 5,
			detail.fencePostSpacing or 14,
			{ x = openDir, y = 0, z = 0 }
		)
	do
		part({
			Name = "Fence" .. i,
			Size = v(seg.size),
			Position = v(seg.position),
			Material = materials.fence,
			Color = theme.palette.fence,
		}, folder)
	end

	-- Base torches with fire and light, flanking the arena-facing edge.
	for i, tz in { -1, 1 } do
		local torch = part({
			Name = "BaseTorch" .. i,
			Size = Vector3.new(1, 6, 1),
			Position = Vector3.new(b.center.x + openDir * (half - 3), 3, b.center.z + tz * 40),
			Material = materials.torch,
			Color = theme.palette.torchWood,
		}, folder)

		local fire = Instance.new("Fire")
		fire.Size = 6
		fire.Heat = 8
		fire.Parent = torch

		local light = Instance.new("PointLight")
		light.Range = 16
		light.Color = theme.palette.accent
		light.Parent = torch
	end

	-- Ambient fireflies and ground dust around the base.
	if theme.particles then
		local platform = folder:FindFirstChild("Platform") :: BasePart
		addSparkles(
			platform,
			theme.particles.firefly or "",
			Color3.fromRGB(210, 240, 120),
			detail.fireflyRate or 1.2,
			0.6
		)
		addSparkles(platform, theme.particles.dust or "", Color3.fromRGB(220, 210, 180), detail.dustRate or 0.8, 0.3)
	end

	if not terrainOk then
		local path = WorldBuilderMath.pathBetween(b.center, half, arena.radius, arena.center)
		if path then
			part({
				Name = "Path",
				Size = v(path.size),
				CFrame = CFrame.new(v(path.position)) * CFrame.Angles(0, path.yaw, 0),
				Material = materials.path,
				Color = theme.palette.path,
			}, folder)
		end
	end
end

local function buildArena(parent: Instance, arena: ArenaLayout, theme: Theme): ()
	local materials = theme.materials
	local detail: DetailTheme = theme.detail or {}
	local floorSize = WorldBuilderMath.arenaFloorSize(arena.radius)
	part({
		Name = "ArenaFloor",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1, floorSize, floorSize),
		CFrame = CFrame.new(arena.center.x, arena.center.y + 0.2, arena.center.z) * CFrame.Angles(0, 0, math.rad(90)),
		Material = materials.arena,
		Color = theme.palette.arena,
	}, parent)

	-- Painted center circle: a wide disc with a neon ring inset.
	part({
		Name = "CenterCircle",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, 34, 34),
		CFrame = CFrame.new(arena.center.x, arena.center.y + 0.75, arena.center.z) * CFrame.Angles(0, 0, math.rad(90)),
		Material = materials.arenaLine,
		Color = theme.palette.arenaLine,
		CanCollide = false,
	}, parent)

	part({
		Name = "CenterRing",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.24, 44, 44),
		CFrame = CFrame.new(arena.center.x, arena.center.y + 0.76, arena.center.z) * CFrame.Angles(0, 0, math.rad(90)),
		Material = materials.trim,
		Color = theme.palette.accent,
		CanCollide = false,
	}, parent)

	for i, cover in arena.covers do
		part({
			Name = "Cover" .. i,
			Size = v(cover.size),
			Position = v(cover.position),
			Material = materials.cover,
			Color = theme.palette.cover,
		}, parent)
	end

	-- Tiered bleachers around the arena, offset off the two base-to-arena paths.
	-- Each stand is Concrete steps with WoodPlanks seat tops, a Metal back rail,
	-- and thin Neon trim strips on the step lips (no glowing slab seats).
	local roleMaterials: { [string]: Enum.Material } = {
		step = materials.arena,
		seat = materials.shop,
		rail = materials.metal,
		trim = materials.trim,
	}
	local roleColors: { [string]: any } = {
		step = theme.palette.arena,
		seat = theme.palette.wood,
		rail = theme.palette.metal,
		trim = theme.palette.arenaLine,
	}
	for i, stand in
		WorldBuilderMath.standPlacements(
			arena.center,
			detail.standRadius or (arena.radius + 10),
			detail.standCount or 6
		)
	do
		local model = Instance.new("Model")
		model.Name = "Stand" .. i
		local baseCF = CFrame.new(stand.x, arena.center.y, stand.z) * CFrame.Angles(0, -(stand.angle + math.pi / 2), 0)
		for j, piece in WorldBuilderMath.bleacherPieces() do
			part({
				Name = string.upper(string.sub(piece.role, 1, 1)) .. string.sub(piece.role, 2) .. j,
				Size = v(piece.size),
				CFrame = baseCF * CFrame.new(v(piece.offset)),
				Material = roleMaterials[piece.role] or materials.arena,
				Color = roleColors[piece.role] or theme.palette.arena,
			}, model)
		end
		model.Parent = parent
	end

	for i, torchPos in arena.torches do
		local torch = part({
			Name = "Torch" .. i,
			Size = Vector3.new(1, 6, 1),
			Position = v(torchPos) + Vector3.new(0, 3, 0),
			Material = materials.torch,
			Color = theme.palette.torchWood,
		}, parent)

		local fire = Instance.new("Fire")
		fire.Size = 6
		fire.Heat = 8
		fire.Parent = torch

		local light = Instance.new("PointLight")
		light.Range = 16
		light.Color = theme.palette.accent
		light.Parent = torch
	end
end

local function buildDecorations(
	parent: Instance,
	decorations: { Decoration },
	theme: Theme,
	decorate: ((kind: string, cframe: CFrame, scale: Vector3, seed: number) -> Instance?)?
): ()
	for i, d in decorations do
		local position = v(d.position)
		local scale = v(d.scale)
		local cframe = CFrame.new(position)

		local placed: Instance? = nil
		if decorate then
			placed = decorate(d.kind, cframe, scale, d.seed)
		end
		if placed == nil then
			local simple = Instance.new("Part")
			simple.Anchored = true
			simple.TopSurface = Enum.SurfaceType.Smooth
			simple.BottomSurface = Enum.SurfaceType.Smooth
			simple.Size = scale
			simple.CFrame = cframe * CFrame.Angles(0, d.seed, 0)
			simple.Material = theme.materials.decoration
			simple.Color = theme.palette.decoration
			simple:SetAttribute("ProcKind", d.kind)
			simple:SetAttribute("ProcSeed", d.seed)
			simple:SetAttribute("ProcScale", scale)
			placed = simple
		end

		local instance = placed :: Instance
		instance.Name = d.kind .. tostring(i)
		instance.Parent = parent
	end
end

-- Flower patches: three tiny Ball parts per patch, laid out by the same pure
-- scatter helper. Server-built and static, so they cost no client work.
local function buildFlowers(parent: Instance, flowers: { Decoration }, theme: Theme): ()
	local palette = theme.palette.flowers
	if typeof(palette) ~= "table" or #palette == 0 then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "Flowers"
	folder.Parent = parent

	for i, flower in flowers do
		for j, petal in WorldBuilderMath.flowerPatch(flower.position, flower.scale.x, flower.seed) do
			part({
				Name = "Flower" .. i .. "Petal" .. j,
				Shape = Enum.PartType.Ball,
				Size = v(petal.size),
				Position = v(petal.position),
				Material = theme.materials.slot,
				Color = palette[(petal.tone - 1) % #palette + 1],
				CanCollide = false,
				CastShadow = false,
			}, folder)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Lighting

-- Reuses an existing effect of the same class/name instead of stacking one per build.
local function ensureIn(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

local function setupLighting(theme: Theme): ()
	local lighting = theme.lighting

	-- Game scripts do not hold the RobloxScript capability required by some Lighting
	-- properties (notably Technology), and a single denied write would otherwise abort
	-- World.build. Apply each property group under pcall, and set the lighting
	-- technology at build time from the place file instead of at runtime.
	local function group(name: string, apply: () -> ...any): ()
		local ok, err = pcall(apply)
		if not ok then
			warn(string.format("[WorldBuilder] lighting %s skipped: %s", name, tostring(err)))
		end
	end

	group("core", function()
		Lighting.GlobalShadows = lighting.globalShadows ~= false
		if lighting.shadowSoftness then
			Lighting.ShadowSoftness = lighting.shadowSoftness
		end
		if lighting.environmentDiffuseScale then
			Lighting.EnvironmentDiffuseScale = lighting.environmentDiffuseScale
		end
		if lighting.environmentSpecularScale then
			Lighting.EnvironmentSpecularScale = lighting.environmentSpecularScale
		end
		Lighting.ClockTime = lighting.clockTime
		Lighting.Brightness = lighting.brightness
		Lighting.Ambient = lighting.ambient
		Lighting.OutdoorAmbient = lighting.outdoorAmbient or lighting.ambient
		if lighting.fogEnd then
			Lighting.FogEnd = lighting.fogEnd
		end
	end)

	group("sky", function()
		local sky = ensureIn(Lighting, "Sky", "ForgeSky") :: Sky
		if lighting.sky then
			sky.CelestialBodiesShown = lighting.sky.celestialBodiesShown ~= false
			if lighting.sky.sunAngularSize then
				sky.SunAngularSize = lighting.sky.sunAngularSize
			end
			if lighting.sky.starCount then
				sky.StarCount = lighting.sky.starCount
			end
			-- Only explicit skybox ids from the theme are applied. There is no
			-- content probe: PreloadAsync yields, and build() must never yield.
			local skybox = lighting.sky.skybox
			if skybox then
				for key, id in skybox do
					if SKYBOX_KEYS[key] then
						(sky :: any)[key] = id
					end
				end
			end
		end
	end)

	group("clouds", function()
		local clouds = ensureIn(Terrain, "Clouds", "ForgeClouds") :: Clouds
		if lighting.clouds then
			if lighting.clouds.cover then
				clouds.Cover = lighting.clouds.cover
			end
			if lighting.clouds.density then
				clouds.Density = lighting.clouds.density
			end
			if lighting.clouds.color then
				clouds.Color = lighting.clouds.color
			end
		end
	end)

	group("atmosphere", function()
		local atmosphere = ensureIn(Lighting, "Atmosphere", "ForgeAtmosphere") :: Atmosphere
		if lighting.atmosphere then
			atmosphere.Density = lighting.atmosphere.density
			atmosphere.Haze = lighting.atmosphere.haze
			atmosphere.Color = lighting.atmosphere.color
			if lighting.atmosphere.decay then
				atmosphere.Decay = lighting.atmosphere.decay
			end
		end
	end)

	group("colorCorrection", function()
		local cc = ensureIn(Lighting, "ColorCorrectionEffect", "ForgeColorCorrection") :: ColorCorrectionEffect
		if lighting.colorCorrection then
			cc.Saturation = lighting.colorCorrection.saturation
			cc.Contrast = lighting.colorCorrection.contrast
		end
	end)

	group("bloom", function()
		local bloom = ensureIn(Lighting, "BloomEffect", "ForgeBloom") :: BloomEffect
		if lighting.bloom then
			bloom.Intensity = lighting.bloom.intensity
			bloom.Size = lighting.bloom.size
			bloom.Threshold = lighting.bloom.threshold
		end
	end)

	group("sunRays", function()
		local sunRays = ensureIn(Lighting, "SunRaysEffect", "ForgeSunRays") :: SunRaysEffect
		if lighting.sunRays then
			sunRays.Intensity = lighting.sunRays.intensity
		end
	end)

	group("depthOfField", function()
		local dof = ensureIn(Lighting, "DepthOfFieldEffect", "ForgeDepthOfField") :: DepthOfFieldEffect
		if lighting.depthOfField then
			if lighting.depthOfField.farIntensity then
				dof.FarIntensity = lighting.depthOfField.farIntensity
			end
			if lighting.depthOfField.focusDistance then
				dof.FocusDistance = lighting.depthOfField.focusDistance
			end
			if lighting.depthOfField.inFocusRadius then
				dof.InFocusRadius = lighting.depthOfField.inFocusRadius
			end
			if lighting.depthOfField.nearIntensity then
				dof.NearIntensity = lighting.depthOfField.nearIntensity
			end
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Assembly

local function countParts(root: Instance): number
	local count = 0
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

-- Builds the world root (a Folder named layout.name, default "World") and parents
-- it to `parent` (default workspace). Any previous root of the same name is removed.
function WorldBuilder.build(layout: Layout, theme: Theme, parent: Instance?, opts: BuildOpts?): Folder
	local host = parent or workspace
	local name = layout.name or "World"
	local existing = host:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end

	local world = Instance.new("Folder")
	world.Name = name

	local terrainOk = false
	if theme.terrain and theme.terrain.enabled ~= false then
		local ok, built = pcall(buildTerrain, theme.terrain, layout, theme)
		terrainOk = ok and built == true
		if not terrainOk then
			warn(string.format("[WorldBuilder] terrain build failed: %s", tostring(built)))
		end
	end
	if not terrainOk then
		buildGround(world, layout.ground, theme)
	end

	for _, base in layout.bases do
		buildBase(world, base, layout.arena, theme, terrainOk)
	end
	buildArena(world, layout.arena, theme)
	buildDecorations(world, layout.decorations or {}, theme, if opts then opts.decorate else nil)
	if layout.flowers then
		buildFlowers(world, layout.flowers, theme)
	end
	local lightingOk, lightingErr = pcall(function(): any
		setupLighting(theme)
		return nil
	end)
	if not lightingOk then
		warn(string.format("[WorldBuilder] lighting setup failed: %s", tostring(lightingErr)))
	end

	world.Parent = host

	local parts = countParts(world)
	local budget = if theme.budget then theme.budget.worldPartsMax else nil
	if budget then
		print(string.format("[WorldBuilder] %s: %d world parts (budget %d)", name, parts, budget))
		if parts > budget then
			warn(string.format("[WorldBuilder] %s exceeds its %d part budget with %d parts", name, budget, parts))
		end
	else
		print(string.format("[WorldBuilder] %s: %d world parts", name, parts))
	end

	return world
end

local function findBase(layout: Layout, team: string): BaseLayout?
	for _, base in layout.bases do
		if base.team == team then
			return base
		end
	end
	return nil
end

local function worldRoot(layout: Layout, parent: Instance?): Instance?
	local host = parent or workspace
	return host:FindFirstChild(layout.name or "World")
end

function WorldBuilder.incubator(layout: Layout, team: string, index: number, parent: Instance?): Model?
	local root = worldRoot(layout, parent)
	if not root then
		return nil
	end
	local base = root:FindFirstChild(team .. "Base")
	if not base then
		return nil
	end
	local inc = base:FindFirstChild("Incubator" .. index)
	return if inc and inc:IsA("Model") then inc else nil
end

function WorldBuilder.vault(layout: Layout, team: string, parent: Instance?): Model?
	local root = worldRoot(layout, parent)
	if not root then
		return nil
	end
	local base = root:FindFirstChild(team .. "Base")
	if not base then
		return nil
	end
	local vault = base:FindFirstChild(team .. "Vault")
	return if vault and vault:IsA("Model") then vault else nil
end

function WorldBuilder.spawn(layout: Layout, team: string, parent: Instance?): SpawnLocation?
	local root = worldRoot(layout, parent)
	if not root then
		return nil
	end
	local base = root:FindFirstChild(team .. "Base")
	if not base then
		return nil
	end
	local spawn = base:FindFirstChild(team .. "Spawn")
	return if spawn and spawn:IsA("SpawnLocation") then spawn else nil
end

function WorldBuilder.slot(layout: Layout, team: string, index: number, parent: Instance?): BasePart?
	local root = worldRoot(layout, parent)
	if not root then
		return nil
	end
	local base = root:FindFirstChild(team .. "Base")
	if not base then
		return nil
	end
	local baseLayout = findBase(layout, team)
	local prefix = if baseLayout then baseLayout.parade.name else "Slot"
	local slot = base:FindFirstChild(prefix .. index)
	return if slot and slot:IsA("BasePart") then slot else nil
end

return WorldBuilder
