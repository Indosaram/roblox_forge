--!strict
-- B3 mesh templates (asset-catalog sections 6-7): the six uploaded building packages are
-- loaded once per server through InsertService:LoadAsset and cloned in place of the primitive
-- Part kits. Callers keep their own gameplay part (tags, prompts, attributes) and only receive
-- a visual Model, so a failed load leaves the Part kits in place.
-- Template rows: ground-centred, 1 stud per unit. Mesh name suffixes (gen_buildings.py):
--   <key>__cut   roof/wall that fades indoors (ForgeCutaway, G24)
--   <key>__wall  house walls above the wainscot: fade indoors like __cut (G24)
--   <key>__lamp  warm window pane / door lantern (warm Neon + small PointLight)
--   <key>__ember fire anchor (Fire + PointLight)
--   <key>__glow  emissive glass / rift fissure
--   <key>__tag   cloth that later takes a clan colour
--   <key>__halo  rift shard halo
local M = {}

M.PACKAGES = {
	"mesh-bld-atlas-a",
	"mesh-bld-atlas-b",
	"mesh-bld-atlas-c",
	"mesh-bld-hero",
	"mesh-town-kit",
	"mesh-town-life",
	"mesh-town-square",
}

-- content.yml structures[].id -> catalog row key.
M.STRUCTURES = {
	campfire = "bld.campfire",
	workbench = "bld.workbench.t1",
	["workbench-t2"] = "bld.workbench.t2",
	["workbench-t3"] = "bld.workbench.t3",
	kiln = "bld.kiln.t1",
	["kiln-t2"] = "bld.kiln.t2",
	["kiln-t3"] = "bld.kiln.t3",
	["mud-kiln"] = "bld.mud-kiln",
	["tanning-frame"] = "bld.tanning-frame",
	["joiner-bench"] = "bld.joiner-bench",
	["mason-bench"] = "bld.mason-bench",
	refrigerator = "bld.refrigerator",
	tent = "bld.tent",
	bed = "bld.bed",
	well = "bld.well",
	["signal-relay"] = "bld.signal-relay",
	laboratory = "bld.laboratory",
	["clan-hall"] = "bld.clan-hall",
	["animal-pen"] = "bld.animal-pen",
	storage = "bld.storage",
	floor = "bld.timber.floor",
	["timber-wall"] = "bld.timber.wall",
	wall = "bld.timber.wall",
	["timber-roof"] = "bld.timber.roof",
	roof = "bld.timber.roof",
	door = "bld.timber.door",
	stairs = "bld.timber.stairs",
	pillar = "bld.timber.pillar",
	["stone-floor"] = "bld.stone.floor",
	["stone-wall"] = "bld.stone.wall",
	["stone-roof"] = "bld.stone.roof",
	["brick-floor"] = "bld.brick.floor",
	["brick-wall"] = "bld.brick.wall",
	["brick-roof"] = "bld.brick.roof",
	["volcanic-wall"] = "bld.volcanic-wall",
}

-- WorldDressing kit kinds -> catalog row key. Every kit kind WorldDressing.plan and .home emit
-- has a row (world-dressing-census.spec); vegetation and rocks come from the B1 biome kits instead.
-- Until the L5 town house rows exist, the cottage borrows the thatched clan hall and the open
-- workshop shed the roofed tier-3 bench.
M.DRESSING = {
	shelter = "bld.tent",
	campfire = "bld.campfire",
	chest = "bld.storage",
	fence = "town.fence-rail",
	workbench = "bld.workbench.t1",
	["drying-rack"] = "bld.tanning-frame",
	dock = "town.drift-camp-walkway",
	beacon = "town.road-sign",
	market = "town.market-stall",
	["quest-board"] = "town.notice-board",
	-- L5 town house rows; RoleWorld picks the cottage variant per house (M.house).
	house = "town.house.cottage-a",
	workshop = "town.house.workshop",
	farm = "town.flower-bed",
}

-- Harbor facility anchors that get a town-kit visual: { row, x offset from the anchor }.
M.FACILITIES = {
	["visitor-portal"] = { row = "town.rift-ring", dx = 10 },
	["rescue-beacon"] = { row = "town.rescue-bell", dx = 0 },
	objective = { row = "town.trading-post", dx = 0 },
	["practice-seedbed"] = { row = "town.flower-bed", dx = 0 },
	["practice-fiber-stitch"] = { row = "bld.tanning-frame", dx = 0 },
	-- Hazard briefing post and the resource-yard drop point.
	hazard = { row = "town.road-sign", dx = 0 },
	resources = { row = "town.crate-stack", dx = 0 },
}

-- Saltmeadow house variants (L5): regular lots take one of the cottages, `lot = "large"` the
-- longhouse. The pick is seeded per house id, so one server seed always dresses the same town.
M.COTTAGES = { "town.house.cottage-a", "town.house.cottage-b", "town.house.cottage-c" }
M.LONGHOUSE = "town.house.longhouse"

--- The house row for one WorldDressing.TOWN house: `pick` is a seeded number in [0, 1).
function M.house(lot: string?, pick: number): string
	if lot == "large" then
		return M.LONGHOUSE
	end
	return M.COTTAGES[math.clamp(math.floor(pick * #M.COTTAGES) + 1, 1, #M.COTTAGES)]
end

-- Rows whose `__glow` is a lantern (warm), not the teal rift/mirror glass.
local WARM_GLOW = { ["town.lamp-post"] = true, ["town.dock"] = true }
M.WARM = { 255, 170, 90 }

-- Role set pieces placed by RoleWorld: { layout, row, x, z, yaw degrees }. Positions sit beside the
-- authored anchors (content.yml) and never on a path or node approach; all are decor only.
M.SET_PIECES = {
	{ layout = "rw.onboarding", row = "town.balloon-wreck", x = 44, z = 70, yaw = 20 },
	{ layout = "rw.onboarding", row = "town.beacon-tower", x = 22, z = -76, yaw = 0 },
	{ layout = "rw.harbor", row = "town.dock", x = 0, z = 156, yaw = 0 },
	{ layout = "rw.harbor", row = "town.boat", x = 22, z = 166, yaw = 0 },
	{ layout = "rw.harbor", row = "town.market-stall", x = 84, z = 0, yaw = 90 },
	{ layout = "rw.harbor", row = "town.npc-booth", x = -84, z = 0, yaw = -90 },
	{ layout = "rw.harbor", row = "town.chart-table", x = 14, z = 120, yaw = 0 },
	{ layout = "rw.harbor", row = "town.crate-stack", x = -16, z = 118, yaw = 30 },
	{ layout = "rw.harbor", row = "bld.well", x = -40, z = 24, yaw = 0 },
	{ layout = "rw.harbor", row = "town.lamp-post", x = 10, z = 100, yaw = 0 },
	{ layout = "rw.harbor", row = "town.lamp-post", x = -10, z = 60, yaw = 180 },
	{ layout = "rw.harbor", row = "town.banner-pole", x = 72, z = 92, yaw = 0 },
	-- Saltmeadow (C5a, town-layout.md): dock south, plaza buildings, rift north, tribe banners.
	{ layout = "rw.town", row = "town.dock", x = 0, z = 600, yaw = 0 },
	{ layout = "rw.town", row = "town.boat", x = 28, z = 640, yaw = 0 },
	{ layout = "rw.town", row = "town.trading-post", x = 0, z = 128, yaw = 0 },
	{ layout = "rw.town", row = "bld.clan-hall", x = 224, z = 208, yaw = -90 },
	{ layout = "rw.town", row = "bld.well", x = -208, z = 256, yaw = 0 },
	{ layout = "rw.town", row = "town.rift-ring", x = 24, z = -608, yaw = 0 },
	{ layout = "rw.town", row = "town.npc-booth", x = -80, z = 576, yaw = 0 },
	{ layout = "rw.town", row = "town.chart-table", x = 80, z = 576, yaw = 0 },
	{ layout = "rw.town", row = "town.npc-booth", x = -176, z = 208, yaw = 90 },
	{ layout = "rw.town", row = "town.npc-booth", x = 192, z = 304, yaw = -90 },
	{ layout = "rw.town", row = "town.market-stall", x = -40, z = 384, yaw = -90 },
	{ layout = "rw.town", row = "town.market-stall", x = 40, z = 356, yaw = 90 },
	{ layout = "rw.town", row = "town.notice-board", x = -40, z = 96, yaw = 0 },
	{ layout = "rw.town", row = "town.shipwright-yard", x = 176, z = 360, yaw = 0 },
	{ layout = "rw.town", row = "town.banner-pole", x = 176, z = 160, yaw = 0 },
	{ layout = "rw.town", row = "town.banner-pole", x = 272, z = 160, yaw = 0 },
	{ layout = "rw.town", row = "town.banner-pole", x = -32, z = 352, yaw = 0 },
	{ layout = "rw.town", row = "town.banner-pole", x = 32, z = 352, yaw = 0 },
	{ layout = "rw.town", row = "town.lamp-post", x = 15, z = 494, yaw = 0 },
	{ layout = "rw.town", row = "town.lamp-post", x = -15, z = 362, yaw = 180 },
	{ layout = "rw.town", row = "town.lamp-post", x = 20, z = -96, yaw = 0 },
	{ layout = "rw.town", row = "town.lamp-post", x = -20, z = -320, yaw = 180 },
	{ layout = "rw.town", row = "town.road-sign", x = -288, z = 48, yaw = 90 },
	{ layout = "rw.town", row = "town.road-sign", x = 288, z = 48, yaw = -90 },
	{ layout = "rw.town", row = "town.road-sign", x = 20, z = -352, yaw = 0 },
	{ layout = "rw.town", row = "town.flower-bed", x = -56, z = 240, yaw = 0 },
	{ layout = "rw.town", row = "town.flower-bed", x = 56, z = 240, yaw = 0 },
	{ layout = "rw.town", row = "town.barrel", x = 112, z = 112, yaw = 0 },
	{ layout = "rw.town", row = "town.crate-stack", x = -112, z = 112, yaw = 30 },
	{ layout = "rw.town", row = "town.post-box", x = 48, z = 96, yaw = 0 },
}

-- Rows a player stands on or walks against keep collision; everything else is visual only.
local SOLID = {
	["bld.timber.floor"] = true,
	["bld.stone.floor"] = true,
	["bld.brick.floor"] = true,
	["bld.timber.wall"] = true,
	["bld.stone.wall"] = true,
	["bld.brick.wall"] = true,
	["bld.volcanic-wall"] = true,
	["bld.timber.stairs"] = true,
	["bld.timber.pillar"] = true,
}

local templates: { [string]: Model }? = nil

--- Test seam: specs inject fake row templates instead of InsertService.
function M.setTemplates(value: { [string]: Model }?)
	templates = value
end

--- Loads every package once (in parallel); later calls return the cached table. Returns an
--- empty table when InsertService is unavailable (headless fixtures) or every load fails.
function M.load(): { [string]: Model }
	if templates then
		return templates
	end
	local loaded: { [string]: Model } = {}
	templates = loaded
	local insert = game:GetService("InsertService")
	if not insert then
		return loaded
	end
	local ok, assets = pcall(function()
		return require(game:GetService("ReplicatedStorage").Forge.games["robango-island"].src.shared.Assets)
	end)
	if not ok then
		return loaded
	end
	local MeshTexture =
		require(game:GetService("ReplicatedStorage").Forge.games["robango-island"].src.shared.MeshTexture)
	local storage = Instance.new("Folder")
	storage.Name, storage.Parent = "ForgeMeshTemplates", game:GetService("ServerStorage")
	local pending = #M.PACKAGES
	local done = Instance.new("BindableEvent")
	for _, key in M.PACKAGES do
		task.spawn(function()
			local id = tonumber(string.match(assets[key] or "", "%d+$"))
			local success, result = pcall(function()
				return insert:LoadAsset(assert(id, "MESH_PACKAGE_UNPUBLISHED:" .. key))
			end)
			if success then
				MeshTexture.bake(result)
				for _, row in result:GetDescendants() do
					if row:IsA("Model") and row:FindFirstChildWhichIsA("MeshPart") then
						local name = string.gsub(row.Name, "%.%d%d%d$", "")
						row.Name, row.WorldPivot, row.Parent = name, CFrame.new(), storage
						loaded[name] = row
					end
				end
				result:Destroy()
			else
				warn("StructureMeshes: " .. key .. " not loaded, primitive kits stay: " .. tostring(result))
			end
			pending -= 1
			if pending == 0 then
				done:Fire()
			end
		end)
	end
	if pending > 0 then
		done.Event:Wait()
	end
	done:Destroy()
	return loaded
end

--- A placed copy of row `key` (nil if the template is missing). The Model pivot is the row's
--- ground centre. options.decor makes every part non-colliding and non-queryable.
function M.clone(key: string?, options: { decor: boolean? }?): Model?
	local template = if key and templates then templates[key] else nil
	if not template then
		return nil
	end
	local model = template:Clone()
	model.Name = "ForgeMeshVisual"
	model:SetAttribute("ForgeMeshRow", key)
	local solid = SOLID[key :: string] == true and not (options and options.decor)
	for _, part in model:GetDescendants() do
		if not part:IsA("MeshPart") then
			continue
		end
		local suffix = string.match(part.Name, "__(%a+)$")
		part.Anchored, part.CanTouch = true, false
		part.CanCollide = solid and suffix ~= "tag" and not (key == "bld.timber.door" and suffix == "cut")
		part.CanQuery = part.CanCollide
		if suffix == "cut" or suffix == "wall" then
			part:SetAttribute("ForgeCutaway", true)
			game:GetService("CollectionService"):AddTag(part, "ForgeCutaway")
		elseif suffix == "lamp" or (suffix == "glow" and WARM_GLOW[key :: string]) then
			-- Warm window or lantern: cheap Neon plus one small unshadowed light.
			-- Plain Neon: no baked atlas texture (MeshTexture.bake) over the glow.
			part.TextureID = ""
			local warm = Color3.fromRGB(table.unpack(M.WARM))
			part.Material, part.Color, part.CastShadow = Enum.Material.Neon, warm, false
			local light = Instance.new("PointLight")
			light.Color, light.Range, light.Brightness = warm, 8, 0.6
			light.Shadows, light.Parent = false, part
		elseif suffix == "ember" or suffix == "glow" then
			-- Plain Neon: no baked atlas texture (MeshTexture.bake) over the glow.
			part.TextureID = ""
			part.Material, part.CastShadow = Enum.Material.Neon, false
			part.Color = if suffix == "ember" then Color3.fromRGB(255, 122, 40) else Color3.fromRGB(150, 236, 220)
			local light = Instance.new("PointLight")
			light.Color, light.Range, light.Brightness = part.Color, if suffix == "ember" then 10 else 12, 0.8
			light.Shadows, light.Parent = false, part
			if suffix == "ember" then
				local fire = Instance.new("Fire")
				fire.Size, fire.Heat, fire.Parent = 2, 4, part
			end
		end
	end
	return model
end

--- Swaps a ForgeStructureKits template's primitive Parts for the mesh row, scaled down only when
--- it would overhang the footprint by more than 1 stud. Returns true when swapped.
function M.structureKit(kit: Model, definition: any, cellStuds: number): boolean
	local visual = M.clone(M.STRUCTURES[definition.id])
	if not visual then
		return false
	end
	-- Rows are exported unrotated, so the axis-aligned extent of their parts is the footprint.
	local low, high = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, part in visual:GetDescendants() do
		if part:IsA("BasePart") then
			low = low:Min(part.Position - part.Size / 2)
			high = high:Max(part.Position + part.Size / 2)
		end
	end
	local size = high - low
	local scale =
		math.min(1, (definition.footprintX * cellStuds + 2) / size.X, (definition.footprintZ * cellStuds + 2) / size.Z)
	if scale < 1 then
		visual:ScaleTo(scale)
	end
	for _, child in kit:GetChildren() do
		child:Destroy()
	end
	for _, part in visual:GetChildren() do
		part.Parent = kit
	end
	visual:Destroy()
	kit.WorldPivot = CFrame.new()
	kit:SetAttribute("ForgeMeshRow", M.STRUCTURES[definition.id])
	return true
end

--- Hangs the row visual under a gameplay part (station, home structure, harbor facility) and
--- hides the part itself; the part keeps every tag, prompt and attribute. `ground` is the world
--- CFrame of the row's ground centre. Re-calling only re-pivots the existing visual.
function M.dress(target: BasePart, key: string?, ground: CFrame): Model?
	local visual = target:FindFirstChild("ForgeMeshVisual") :: Model?
	if not visual then
		visual = M.clone(key, { decor = true })
		if not visual then
			return nil
		end
		visual.Parent = target
	end
	(visual :: Model):PivotTo(ground)
	target.Transparency = 1
	return visual
end

--- A free-standing decor copy of row `key` at `ground` under `parent` (nil if no template).
function M.place(key: string?, ground: CFrame, parent: Instance, name: string): Model?
	local visual = M.clone(key, { decor = true })
	if not visual then
		return nil
	end
	visual.Name = name
	visual:PivotTo(ground)
	visual.Parent = parent
	return visual
end

return M
