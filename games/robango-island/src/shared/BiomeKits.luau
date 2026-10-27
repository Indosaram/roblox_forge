--!strict
-- B1a biome kits: which mesh kit each role loads, a deterministic scatter plan (pure: Lune runs
-- it), and the Roblox adapters (server template loading + placement, client distance LOD).
-- Rows and per-screen targets come from the asset catalog (robango-durango-specs/asset-catalog.md
-- sections 2-3). Heights come from the shared terrain columns (ArchipelagoTerrain.columns), never
-- from a raycast, so placement works before the area streams in.
local M = {}
local runtime: any, load: any = getfenv(), require
local Rng = load(
	if runtime.game
		then runtime.game:GetService("ReplicatedStorage"):WaitForChild("Forge").core.domain.random.Rng
		else "../../../../core/domain/random/Rng"
)

-- Default-zoom landscape screen on the reference phone (catalog section 0): ~100 x 220 studs.
M.SCREEN_AREA = 100 * 220
-- Land rule: column tops at or below this are shore/sea (sea level is -4, beach top 2).
M.LAND_TOP = 0.5
-- Cliff rule: a column more than this above/below a neighbour (per stud) is a cliff face.
M.CLIFF_SLOPE = 0.3

-- Manifest keys of the uploaded packages (assets/manifest.yml -> Assets.luau).
M.packages = {
	beach = "kit-beach",
	jungle = "kit-jungle",
	grassland = "kit-grassland",
	savanna = "kit-savanna",
	lake = "kit-lake",
}

export type Row = {
	key: string,
	family: string,
	perScreen: number,
	scale: { number },
	mask: string?,
}

-- family -> client hide distance (studs) and whether it may cast a shadow (catalog LOD columns).
M.lod = {
	tree = { hide = 512, shadow = 200 },
	rock = { hide = 512, shadow = 200 },
	shrub = { hide = 384, shadow = 0 },
	fern = { hide = 256, shadow = 0 },
	grass = { hide = 160, shadow = 0 },
	clutter = { hide = 140, shadow = 0 },
}
-- Low profile (RenderBudget "low"): catalog lever 1 (grass 160 -> 120) and an instance cap.
M.lowProfile = { grassHide = 120, maxShown = 700 }

local function row(key: string, family: string, perScreen: number, lo: number, hi: number, mask: string?): Row
	return { key = key, family = family, perScreen = perScreen, scale = { lo, hi }, mask = mask }
end

-- perScreen = catalog midpoint. Masks: "band" grass bands, "edge" band borders, "open" off-band.
M.kits = {
	beach = {
		row("veg.beach.palm-tall", "tree", 4, 0.9, 1.1),
		row("veg.beach.palm-lean", "tree", 2, 0.9, 1.1),
		row("veg.beach.seagrape", "shrub", 6, 0.8, 1.2, "edge"),
		row("veg.beach.vine-mat", "fern", 6, 0.8, 1.2, "open"),
		row("veg.beach.dune-grass-a", "grass", 30, 0.8, 1.2, "band"),
		row("veg.beach.dune-grass-b", "grass", 15, 0.8, 1.2, "band"),
		row("rock.beach.tide-boulder", "rock", 3, 0.7, 1.2),
		row("rock.beach.pebble-scatter", "rock", 3, 0.8, 1.2, "open"),
		row("clutter.beach.leaf-litter", "clutter", 6, 0.8, 1.2),
		row("clutter.beach.gravel", "clutter", 6, 0.8, 1.2),
	},
	jungle = {
		row("veg.jungle.fan-palm", "tree", 3, 0.85, 1.15),
		row("veg.jungle.buttress-giant", "tree", 1.5, 0.9, 1.1, "open"),
		row("veg.jungle.strangler", "tree", 1.5, 0.9, 1.1),
		row("veg.jungle.understory-broadleaf", "shrub", 8, 0.8, 1.2, "edge"),
		row("veg.jungle.red-ginger", "shrub", 4.5, 0.8, 1.2, "edge"),
		row("veg.jungle.tree-fern", "fern", 4.5, 0.8, 1.2),
		row("veg.jungle.ground-fern", "fern", 11, 0.8, 1.3, "edge"),
		row("veg.jungle.jungle-tall", "grass", 37, 0.85, 1.15, "band"),
		row("veg.jungle.elephant-grass", "grass", 15, 0.85, 1.15, "band"),
		row("rock.jungle.mossy-boulder", "rock", 3, 0.7, 1.2),
		row("rock.jungle.red-bank", "rock", 2, 0.8, 1.2),
		row("clutter.jungle.leaf-litter", "clutter", 10, 0.8, 1.2),
		row("clutter.jungle.gravel", "clutter", 4, 0.8, 1.2),
	},
	grassland = {
		row("veg.grassland.oak", "tree", 2, 0.85, 1.15, "open"),
		row("veg.grassland.birch", "tree", 2, 0.85, 1.15),
		row("veg.grassland.hazel", "shrub", 6, 0.8, 1.2, "edge"),
		row("veg.grassland.bramble", "shrub", 6, 0.8, 1.2, "edge"),
		row("veg.grassland.bracken", "fern", 9, 0.8, 1.3, "edge"),
		row("veg.grassland.meadow", "grass", 45, 0.8, 1.2, "band"),
		row("veg.grassland.flower-patch", "grass", 15, 0.8, 1.2, "open"),
		row("rock.grassland.grey-boulder", "rock", 4, 0.7, 1.3),
		row("rock.grassland.boulder-cluster", "rock", 1.5, 0.9, 1.1, "open"),
		row("clutter.grassland.leaf-litter", "clutter", 6, 0.8, 1.2),
		row("clutter.grassland.gravel", "clutter", 6, 0.8, 1.2),
	},
	savanna = {
		row("veg.savanna.flat-top", "tree", 2, 0.85, 1.15, "open"),
		row("veg.savanna.bottle-trunk", "tree", 0.5, 0.9, 1.1, "open"),
		row("veg.savanna.thornbush", "shrub", 9, 0.8, 1.2, "edge"),
		row("veg.savanna.termite-mound", "shrub", 2, 0.8, 1.2, "open"),
		row("veg.savanna.dry-tuft", "fern", 9, 0.8, 1.3),
		row("veg.savanna.gold-tall", "grass", 45, 0.85, 1.15, "band"),
		row("veg.savanna.gold-short", "grass", 30, 0.8, 1.2, "open"),
		row("rock.savanna.kopje-slab", "rock", 1.5, 0.9, 1.1, "open"),
		row("rock.savanna.sun-boulder", "rock", 3, 0.8, 1.3),
		row("clutter.savanna.leaf-litter", "clutter", 4, 0.8, 1.2),
		row("clutter.savanna.gravel", "clutter", 8, 0.8, 1.2),
	},
	lake = {
		row("veg.lake.willow", "tree", 1.5, 0.9, 1.1),
		row("veg.lake.alder", "tree", 2, 0.85, 1.15),
		row("veg.lake.sedge-clump", "shrub", 9, 0.8, 1.2, "edge"),
		row("veg.lake.reed-card", "grass", 30, 0.85, 1.15, "band"),
		row("veg.lake.cattail-card", "grass", 15, 0.85, 1.15, "band"),
		row("rock.lake.river-stones", "rock", 3, 0.8, 1.2),
		row("clutter.lake.leaf-litter", "clutter", 6, 0.8, 1.2),
		row("clutter.lake.gravel", "clutter", 6, 0.8, 1.2),
	},
} :: { [string]: { Row } }

-- Catalog section 2 kit map. Beach coves (sand-edged land columns) use the beach kit on every
-- role that loads it. B1b owns swamp/desert/snow/volcano; those roles get no B1a kit inland.
function M.kitsFor(layout: any): { string }
	local id = layout.id
	if id == "rw.onboarding" then
		return { "grassland", "jungle", "beach" }
	elseif id == "rw.harbor" then
		return { "beach" }
	elseif id == "rw.a1.s3" or id == "rw.explore20" then
		return { "savanna", "beach" }
	elseif id == "rw.a1.s2" then
		return { "lake", "grassland", "beach" }
	end
	local first = layout.biomes[1]
	if first == "tropical" then
		return { "jungle", "beach" }
	elseif first == "grassland" or first == "forest" or first == "beach" then
		return { "grassland", "beach" }
	end
	return { "beach" }
end

-- Shared terrain height lookup over ArchipelagoTerrain.columns.
export type Ground = {
	top: (x: number, z: number) -> number?,
	slope: (x: number, z: number) -> number,
	beach: (x: number, z: number) -> boolean,
}
function M.ground(columns: { any }): Ground
	local cell = if columns[1] then columns[1].cell else 32
	local byKey: { [string]: any } = {}
	for _, column in columns do
		byKey[column.x .. "," .. column.z] = column
	end
	local function at(x: number, z: number): (any, number, number)
		local ox, oz = columns[1] and columns[1].x or 0, columns[1] and columns[1].z or 0
		local cx = ox + math.floor((x - ox) / cell + 0.5) * cell
		local cz = oz + math.floor((z - oz) / cell + 0.5) * cell
		return byKey[cx .. "," .. cz], cx, cz
	end
	local ground = {}
	function ground.top(x: number, z: number): number?
		local column = at(x, z)
		return if column then column.top else nil
	end
	function ground.slope(x: number, z: number): number
		local column, cx, cz = at(x, z)
		if not column then
			return math.huge
		end
		local worst = 0
		for dx = -1, 1 do
			for dz = -1, 1 do
				local other = byKey[cx + dx * cell .. "," .. cz + dz * cell]
				local top = if other then other.top else -12
				local distance = cell * math.sqrt(dx * dx + dz * dz)
				if distance > 0 then
					worst = math.max(worst, math.abs(top - column.top) / distance)
				end
			end
		end
		return worst
	end
	function ground.beach(x: number, z: number): boolean
		local column = at(x, z)
		return column ~= nil and (column.beach == true or column.material == "Sand")
	end
	return ground
end

export type Placement = {
	key: string,
	kit: string,
	family: string,
	x: number,
	y: number,
	z: number,
	yaw: number,
	scale: number,
}

-- Value noise from the seeded stream (no math.noise: Lune and Roblox must agree bit for bit).
local function lattice(rng: any, size: number): (number, number) -> number
	local values = {}
	for i = 1, size * size do
		values[i] = rng:nextNumber()
	end
	return function(u: number, v: number): number
		local x, z = u % size, v % size
		local x0, z0 = math.floor(x), math.floor(z)
		local fx, fz = x - x0, z - z0
		fx, fz = fx * fx * (3 - 2 * fx), fz * fz * (3 - 2 * fz)
		local function g(a: number, b: number): number
			return values[(a % size) * size + (b % size) + 1]
		end
		local top = g(x0, z0) + (g(x0 + 1, z0) - g(x0, z0)) * fx
		local bottom = g(x0, z0 + 1) + (g(x0 + 1, z0 + 1) - g(x0, z0 + 1)) * fx
		return top + (bottom - top) * fz
	end
end

--- Whether (x, z) may hold a kit instance: dry land, not a cliff, off the walkable path ribbon,
--- spawn circles and anchors, and clear of gather nodes. Kits use their own narrow clearance, not
--- ArchipelagoTerrain.protected (its 80-stud spawn reserve was sized for primitive props and
--- leaves the onboarding island bare); tall grass may flank a path as in R03-3.
function M.allowed(layout: any, terrain: any, ground: Ground, x: number, z: number, clearance: number): boolean
	local top = ground.top(x, z)
	if top == nil or top <= M.LAND_TOP then
		return false
	end
	if ground.slope(x, z) > M.CLIFF_SLOPE then
		return false
	end
	for _, path in layout.paths do
		for i = 2, #path.points do
			if terrain.distance(x, z, path.points[i - 1], path.points[i]) <= path.width / 2 + 2 + clearance then
				return false
			end
		end
	end
	for _, spawn in layout.spawns do
		if (x - spawn.position.x) ^ 2 + (z - spawn.position.z) ^ 2 <= (spawn.radius + clearance) ^ 2 then
			return false
		end
	end
	for _, anchor in layout.anchors do
		local radius = if anchor.id == "objective" then 24 else 12
		if (x - anchor.position.x) ^ 2 + (z - anchor.position.z) ^ 2 <= (radius + clearance) ^ 2 then
			return false
		end
	end
	for _, node in layout.resourceNodes do
		if (x - node.position.x) ^ 2 + (z - node.position.z) ^ 2 < (6 + clearance) ^ 2 then
			return false
		end
	end
	return true
end

--- Deterministic scatter for one role: same layout + columns + seed -> same placements.
function M.plan(layout: any, columns: { any }, seed: number, terrain: any): { Placement }
	local ground = M.ground(columns)
	local result: { Placement } = {}
	if #columns == 0 then
		return result
	end
	local low, high = layout.bounds.min, layout.bounds.max
	local grow = columns[1].cell * 2
	local x0, x1, z0, z1 = low.x - grow, high.x + grow, low.z - grow, high.z + grow
	local landArea = 0
	for _, column in columns do
		if column.top > M.LAND_TOP then
			landArea += column.cell * column.cell
		end
	end
	local stream = Rng.new(seed):fork("biome-kits:" .. layout.id)
	local bands = lattice(stream:fork("bands"), 16)
	local kits = M.kitsFor(layout)
	for kitIndex, kit in kits do
		-- Beach is a rim kit unless it is the role's only kit (harbor), where it dresses all land.
		local beachKit = kit == "beach" and #kits > 1
		local share = if beachKit
			then 1
			else 1 / math.max(1, #kits - (if #kits > 1 and table.find(kits, "beach") then 1 else 0))
		local rng = stream:fork(kit)
		for _, entry in M.kits[kit] do
			local wanted = math.floor(entry.perScreen * landArea / M.SCREEN_AREA * share + 0.5)
			if beachKit then
				-- Coves are a thin rim: scale the beach kit by the rim's share of the land.
				wanted = math.floor(wanted * 0.15 + 0.5)
			end
			local placed, tries = 0, 0
			local clearance = if entry.family == "tree" then 4 else if entry.family == "grass" then 1 else 2
			while placed < wanted and tries < wanted * 8 do
				tries += 1
				local x = x0 + rng:nextNumber() * (x1 - x0)
				local z = z0 + rng:nextNumber() * (z1 - z0)
				local yaw = rng:nextNumber() * 360
				local scale = entry.scale[1] + rng:nextNumber() * (entry.scale[2] - entry.scale[1])
				if not M.allowed(layout, terrain, ground, x, z, clearance) then
					continue
				end
				if #kits > 1 and ground.beach(x, z) ~= beachKit then
					continue
				end
				-- Multi-kit roles split the island into seeded kit regions (onboarding/lake roles).
				if not beachKit and #kits > 2 then
					local span = math.min(160, (x1 - x0) / 3)
					local region = lattice(stream:fork("regions"), 4)((x - x0) / span, (z - z0) / span)
					local inland = #kits - 1
					if math.min(inland, math.floor(region * inland) + 1) ~= kitIndex then
						continue
					end
				end
				local band = bands(x / 48, z / 48)
				if entry.mask == "band" and band < 0.45 then
					continue
				elseif entry.mask == "edge" and math.abs(band - 0.45) > 0.12 then
					continue
				elseif entry.mask == "open" and band >= 0.45 then
					continue
				end
				placed += 1
				table.insert(result, {
					key = entry.key,
					kit = kit,
					family = entry.family,
					x = x,
					y = ground.top(x, z) :: number,
					z = z,
					yaw = yaw,
					scale = scale,
				})
			end
		end
	end
	return result
end

--- Client LOD verdict for one instance at `distance` from the camera focus.
function M.visible(family: string, distance: number, low: boolean): boolean
	local hide = M.lod[family].hide
	if low and family == "grass" then
		hide = M.lowProfile.grassHide
	end
	return distance <= hide
end

-- ------------------------------------------------------------------ Roblox adapters
local templates: { [string]: any } = {}
local loading: { [string]: boolean } = {}

-- Every kit this module can place; the server preloads all of them at start.
M.allKits = { "beach", "jungle", "grassland", "savanna", "lake" }

--- Server: loads each needed package once (InsertService, owned by the universe creator) and
--- returns key -> template. A failed load leaves that kit out; the world still builds.
function M.load(kits: { string }, assets: { [string]: string }): { [string]: any }
	local insert = runtime.game:GetService("InsertService")
	for _, kit in kits do
		local id = tonumber(string.match(assets[M.packages[kit]] or "", "%d+$") or "")
		-- A load already in flight (server-start preload) finishes before a role world reads it.
		while loading[kit] do
			task.wait(0.1)
		end
		if id and not templates["@" .. kit] then
			loading[kit] = true
			local ok, model = pcall(insert.LoadAsset, insert, id)
			loading[kit] = nil
			if ok and model then
				templates["@" .. kit] = model
				for _, child in model:GetDescendants() do
					if child:IsA("BasePart") then
						templates[child.Name] = child
					end
				end
			else
				warn("BiomeKits: package " .. kit .. " did not load: " .. tostring(model))
			end
		end
	end
	return templates
end

--- Server: clones templates for every placement under `parent` (a Folder named ForgeBiomeKits).
function M.place(parent: any, placements: { Placement }, loaded: { [string]: any }): number
	local count = 0
	for index, p in placements do
		local template = loaded[p.key]
		if not template then
			continue
		end
		local part = template:Clone()
		part.Anchored, part.CanCollide, part.CanTouch = true, false, false
		part.CanQuery = p.family == "tree" or p.family == "rock"
		part.CastShadow = p.family == "tree" or p.family == "rock"
		part.Size = template.Size * p.scale
		-- Sink 0.3 studs so card bases and rock skirts never float on the voxel surface.
		part.CFrame = CFrame.new(p.x, p.y + part.Size.Y / 2 - 0.3, p.z) * CFrame.Angles(0, math.rad(p.yaw), 0)
		part.Name = p.key
		part:SetAttribute("ForgeKitFamily", p.family)
		part:SetAttribute("ForgeKitIndex", index)
		part.Parent = parent
		count += 1
	end
	return count
end

--- Client: distance LOD + low-profile cap over the replicated ForgeBiomeKits folder. Hidden
--- instances move to a client-only holder; nothing is destroyed, so re-showing is free.
function M.runLod(folder: any, low: boolean)
	local holder = Instance.new("Folder")
	holder.Name = "ForgeBiomeKitsHidden"
	local all: { any } = {}
	local function track(child: any)
		if child:IsA("BasePart") and child:GetAttribute("ForgeKitFamily") then
			table.insert(all, child)
		end
	end
	for _, child in folder:GetChildren() do
		track(child)
	end
	folder.ChildAdded:Connect(track)
	task.spawn(function()
		while folder.Parent do
			local camera = runtime.workspace.CurrentCamera
			local focus = camera and camera.Focus.Position or Vector3.zero
			local shown = 0
			for _, part in all do
				local family = part:GetAttribute("ForgeKitFamily")
				local distance = (part.Position - focus).Magnitude
				local keep = M.visible(family, distance, low) and (not low or shown < M.lowProfile.maxShown)
				if keep then
					shown += 1
				end
				local target = if keep then folder else holder
				if part.Parent ~= target then
					part.Parent = target
				end
				part.CastShadow = not low and distance <= M.lod[family].shadow
			end
			task.wait(0.5)
		end
		holder:Destroy()
	end)
end

return M
