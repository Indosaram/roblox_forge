--!strict
-- Generated ProcAssets props dress every organic role (harbor + 20 stages) and the home.
local Content = require("./src/shared/SurvivalContent")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local ProcProps = require("./src/shared/ProcProps")
local ProcAssets = require("./src/shared/ProcAssets")
local RenderBudget = require("./src/shared/RenderBudget")
local Dressing = require("./src/server/WorldDressing")
local Prop = require("../../core/domain/procgen/Prop")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local serde = require("@lune/serde")

local MIN_PROPS = 12
local MIN_HOME_PROPS = 6
local SEED = 79

local function roles(): { any }
	local list = {}
	for _, layout in Content.layouts :: any do
		if Terrain.organic(layout) or layout.id == "rw.home" then
			table.insert(list, layout)
		end
	end
	return list
end

local HOME_DESIGNED = 8
local PROMPT_CLEARANCE = 14
local UPRIGHT_DEGREES = 25

local function plan(layout: any, seed: number): { ProcProps.Placement }
	local columns = if layout.id == "rw.home" then {} else Terrain.columns(layout, seed, 32)
	return ProcProps.plan(layout, columns, seed, (Content :: any).homePolicy)
end

local function layoutOf(id: string): any
	for _, layout in Content.layouts :: any do
		if layout.id == id then
			return layout
		end
	end
	error("missing layout " .. id)
end

-- The real MeshAdapter, loaded with Lune's Roblox datatypes as a server (no EditableMesh),
-- so every prop takes the Part-fallback path the client builds when the mesh budget is spent.
local function adapter(): any
	local environment = setmetatable({
		Instance = roblox.Instance,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		Enum = roblox.Enum,
		game = {
			GetService = function()
				return {
					IsClient = function()
						return false
					end,
				}
			end,
		},
	}, { __index = { setmetatable = setmetatable, math = math, string = string, table = table, warn = print } })
	return luau.load(fs.readFile("core/infra/render/MeshAdapter.luau"), { environment = environment })()
end

local function fallback(key: string): ({ any }, any)
	local entry = (ProcAssets :: any)[key]
	local mesh = Prop.generate(entry.archetype, entry.spec, entry.seed)
	local model = adapter().toInstance(mesh, key, { forceParts = true })
	local parts = {}
	for _, part in model:GetChildren() do
		table.insert(parts, part)
	end
	return parts, model
end

-- Studio's Model:GetPivot() once a PrimaryPart is set: PrimaryPart.CFrame * PrimaryPart.PivotOffset
-- (Model.WorldPivot is ignored, measured in p41). Lune has no GetPivot, so compose it here.
local function pivotOf(model: any): any
	local primary = model.PrimaryPart
	assert(primary, model.Name .. " has no PrimaryPart")
	return primary.CFrame * primary.PivotOffset
end

-- Studio's Model:PivotTo(target): every part keeps its offset from the current pivot.
local function pivotTo(model: any, parts: { any }, target: any)
	local pivot = pivotOf(model)
	for _, part in parts do
		part.CFrame = target * pivot:ToObjectSpace(part.CFrame)
	end
end

local function tilt(axis: any): number
	return math.deg(math.acos(math.clamp(math.abs(axis.Unit.Y), 0, 1)))
end

return {
	["every organic role and the home get biome-correct procedural props"] = function()
		local list = roles()
		assert(#list == 22, "harbor + 20 stages + home, got " .. #list)
		for _, layout in list do
			local placements = plan(layout, SEED)
			local floor = if layout.id == "rw.home" then MIN_HOME_PROPS else MIN_PROPS
			assert(#placements >= floor, layout.id .. " has only " .. #placements .. " procedural props")
			assert(#placements <= ProcProps.MAX_PER_ROLE, layout.id .. " exceeds the per-role cap")
			local allowed = ProcProps.allowed(layout)
			local keys: { [string]: boolean } = {}
			for _, item in placements do
				assert(table.find(allowed, item.biome), layout.id .. " used off-biome set " .. item.biome)
				assert(table.find(ProcProps.SETS[item.biome], item.key), item.key .. " is not in " .. item.biome)
				local entry = (ProcAssets :: any)[item.key]
				assert(entry and entry.kind == "prop", item.key .. " is not a generated prop")
				keys[item.key] = true
			end
			local distinct = 0
			for _ in keys do
				distinct += 1
			end
			assert(distinct >= 3, layout.id .. " repeats one prop (" .. distinct .. " distinct)")
			-- The role's primary biome is represented (not only shore or camp fill).
			local primary = layout.biomes[1]
			if ProcProps.SETS[primary] and layout.id ~= "rw.home" then
				local found = false
				for _, item in placements do
					found = found or item.biome == primary
				end
				assert(found, layout.id .. " has no " .. primary .. " props")
			end
		end
	end,
	["every biome set has 2-4 distinct generated props"] = function()
		for name, set in ProcProps.SETS do
			assert(#set >= 2 and #set <= 4, name .. " set size")
			for _, key in set do
				assert((ProcAssets :: any)[key] and (ProcAssets :: any)[key].kind == "prop", key .. " missing")
			end
		end
	end,
	["home builds at most the designed eight props"] = function()
		local home = layoutOf("rw.home")
		assert(ProcProps.HOME_MAX == HOME_DESIGNED, "home cap is the designed " .. HOME_DESIGNED)
		for seed = 1, 40 do
			local placements = plan(home, seed)
			assert(#placements <= HOME_DESIGNED, "home seed " .. seed .. " builds " .. #placements .. " props")
			assert(#placements >= MIN_HOME_PROPS, "home seed " .. seed .. " builds only " .. #placements .. " props")
		end
	end,
	["home props keep 14 studs from every prompt, interactable and camp kit"] = function()
		local home = layoutOf("rw.home")
		local policy = (Content :: any).homePolicy
		local targets: { any } = {}
		for _, list in { home.anchors, home.resourceNodes } do
			for _, item in list do
				table.insert(targets, { id = item.id, x = item.position.x, z = item.position.z })
			end
		end
		table.insert(targets, { id = "dock", x = policy.dock.x, z = policy.dock.z })
		table.insert(targets, { id = "farm-plot", x = policy.starterFarmPlot.x, z = policy.starterFarmPlot.z })
		-- Camp kit footprints straight from the server dressing, independent of HOME_CAMP.
		local parts = {}
		Dressing.home(parts, { dock = policy.dock, landRank = 1 }, { landSizes = { policy.tiers[1].sideStuds } })
		local kits: { [string]: { x: number, z: number, n: number } } = {}
		for _, part in parts do
			local kit = string.match(part.id, "^home%.(%a+)")
			if kit and kit ~= "fence" and kit ~= "path" and kit ~= "tree" and kit ~= "dock" then
				local sum = kits[kit] or { x = 0, z = 0, n = 0 }
				sum.x += part.position.x
				sum.z += part.position.z
				sum.n += 1
				kits[kit] = sum
			end
		end
		for kit, sum in kits do
			table.insert(targets, { id = "kit:" .. kit, x = sum.x / sum.n, z = sum.z / sum.n })
		end
		assert(#targets >= #home.anchors + #home.resourceNodes + 8, "camp kits recovered")
		for seed = 1, 40 do
			for _, item in plan(home, seed) do
				for _, target in targets do
					local d = math.sqrt((item.position.x - target.x) ^ 2 + (item.position.z - target.z) ^ 2)
					assert(
						d >= PROMPT_CLEARANCE - 0.5,
						string.format("home seed %d %s is %.1f studs from %s", seed, item.name, d, target.id)
					)
				end
			end
		end
	end,
	["the coast palm and every Part-fallback trunk stand upright"] = function()
		-- Generated geometry: the palm trunk runs from the root to the fronds crown.
		local palm = (ProcAssets :: any)["robango-coast-palm"]
		assert(palm.archetype == "palm", "coast palm uses the palm generator")
		local mesh = Prop.generate(palm.archetype, palm.spec, palm.seed)
		local first, last
		for _, prim in mesh.primitives do
			if prim.kind == "capsule" then
				first = first or prim.a
				last = prim.b
			end
		end
		assert(first and last, "palm has a trunk")
		local axis = roblox.Vector3.new(last.x - first.x, last.y - first.y, last.z - first.z)
		assert(tilt(axis) <= UPRIGHT_DEGREES, string.format("palm trunk leans %.1f degrees", tilt(axis)))
		local frondsAbove = 0
		for _, prim in mesh.primitives do
			if prim.kind == "cone" and prim.base.y >= last.y - 0.1 then
				frondsAbove += 1
			end
		end
		assert(frondsAbove >= 4, "palm fronds crown the trunk top")
		-- Every prop's Part fallback: finite orientations, trunks along the vertical.
		for key, entry in ProcAssets :: any do
			if entry.kind ~= "prop" then
				continue
			end
			local parts, model = fallback(key)
			assert(#parts > 0, key .. " builds no fallback parts")
			-- Studio p40: the client places props with model:PivotTo(cf). A pivot that inherits the
			-- trunk part's rotated frame laid the palm on its side, so the pivot must be axis-aligned.
			local pivot = pivotOf(model)
			assert(
				pivot.UpVector.Y > 0.999 and pivot.RightVector.X > 0.999,
				key .. " fallback pivot is rotated, so PivotTo would tip the prop over"
			)
			for _, part in parts do
				local right = part.CFrame.RightVector
				assert(
					right.X == right.X and right.Y == right.Y and right.Z == right.Z,
					key .. " has a NaN orientation"
				)
			end
			if entry.archetype == "tree" or entry.archetype == "palm" then
				local trunk = parts[1]
				assert(trunk.Shape == roblox.Enum.PartType.Cylinder, key .. " trunk is a cylinder")
				local degrees = tilt(trunk.CFrame.RightVector)
				assert(
					degrees <= UPRIGHT_DEGREES,
					string.format("%s trunk lies %.1f degrees off vertical", key, degrees)
				)
				local trunkTop, crownY = trunk.CFrame.Position.Y, -math.huge
				for _, part in parts do
					crownY = math.max(crownY, part.CFrame.Position.Y)
				end
				assert(crownY > trunkTop + 0.5, key .. " crown sits above the trunk")
			end
		end
	end,
	["props seat their bounding-box bottom on the ground"] = function()
		local CFrame, Vector3 = roblox.CFrame, roblox.Vector3
		for _, key in { "robango-camp-egg-cache", "robango-supply-crate", "robango-harbor-cargo", "robango-coast-palm" } do
			local parts, model = fallback(key)
			local ground = 3.09
			-- The client pivots the model onto the terrain hit, then applies the seat offset.
			local place = CFrame.new(10, ground, -4) * CFrame.Angles(0, math.rad(37), 0)
			pivotTo(model, parts, place)
			if key == "robango-coast-palm" then
				local degrees = tilt(parts[1].CFrame.RightVector)
				assert(
					degrees <= UPRIGHT_DEGREES,
					string.format("palm trunk lies %.1f degrees off vertical after PivotTo", degrees)
				)
			end
			local sunk = ground - ProcProps.bottom(parts)
			local offset = ProcProps.seat(ground, ProcProps.bottom(parts))
			assert(math.abs(offset - sunk) < 1e-9, key .. " seat offset matches the sink")
			for _, part in parts do
				part.CFrame = part.CFrame + Vector3.new(0, offset, 0)
			end
			local bottom = ProcProps.bottom(parts)
			assert(
				math.abs(bottom - ground) < 0.05,
				string.format("%s bottom %.2f vs ground %.2f", key, bottom, ground)
			)
		end
		-- MeshAdapter MeshParts (Studio p42): CFrame is the mesh origin and Size spans the mesh
		-- bounds, so the visible geometry runs from CFrame.Y + min.Y * k to CFrame.Y + max.Y * k.
		for _, key in { "robango-jungle-tree", "robango-jungle-mossrock", "robango-coast-palm" } do
			local entry = (ProcAssets :: any)[key]
			local mesh = Prop.generate(entry.archetype, entry.spec, entry.seed)
			local lo, hi = mesh.bounds.min, mesh.bounds.max
			local k = 2.7
			local attributes = {
				ForgeMeshMin = Vector3.new(lo.x, lo.y, lo.z),
				ForgeMeshMax = Vector3.new(hi.x, hi.y, hi.z),
			}
			local part = {
				CFrame = CFrame.new(5, 20, -3) * CFrame.Angles(0, math.rad(41), 0),
				Size = Vector3.new(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z) * k,
				GetAttribute = function(_, name: string): any
					return attributes[name]
				end,
			}
			local geometryBottom = math.huge
			for _, v in mesh.vertices do
				geometryBottom = math.min(geometryBottom, (part.CFrame * (Vector3.new(v.x, v.y, v.z) * k)).Y)
			end
			local ground = 7.25
			part.CFrame = part.CFrame + Vector3.new(0, ProcProps.seat(ground, ProcProps.bottom({ part })), 0)
			geometryBottom += part.CFrame.Position.Y - 20
			assert(
				math.abs(geometryBottom - ground) < 0.05,
				string.format("%s visible mesh bottom %.2f vs ground %.2f", key, geometryBottom, ground)
			)
		end
		-- A tilted block's oriented bottom, not its centre minus half height.
		local part = { CFrame = CFrame.new(0, 5, 0) * CFrame.Angles(0, 0, math.rad(90)), Size = Vector3.new(4, 1, 1) }
		assert(math.abs(ProcProps.bottom({ part }) - 3) < 1e-6, "oriented box bottom")
	end,
	["props scale with the layout terrain relief"] = function()
		local home = layoutOf("rw.home")
		local a1, a3 = layoutOf("rw.a1.s1"), layoutOf("rw.a3.s3")
		local s1 = ProcProps.roleScale(a1, Terrain.columns(a1, SEED, 32))
		local s3 = ProcProps.roleScale(a3, Terrain.columns(a3, SEED, 32))
		assert(ProcProps.roleScale(home, {}) == 1, "home keeps camp scale")
		assert(s3 > s1 and s3 >= 2, string.format("a3.s3 scale %.2f vs a1.s1 %.2f", s3, s1))
		for _, layout in roles() do
			for _, item in plan(layout, SEED) do
				assert(item.scale <= ProcProps.SCALE_MAX * 1.25, layout.id .. " prop scale beyond the cap")
			end
		end
		for _, item in plan(a3, SEED) do
			if item.biome ~= "camp" then
				assert(item.scale >= 1.6, string.format("a3.s3 %s scale %.2f is too small", item.name, item.scale))
			end
		end
	end,
	["procedural prop plan is deterministic and seed-dependent"] = function()
		local changed = false
		for _, layout in roles() do
			local a = serde.encode("json", plan(layout, SEED))
			assert(a == serde.encode("json", plan(layout, SEED)), layout.id .. " plan is not deterministic")
			changed = changed or a ~= serde.encode("json", plan(layout, SEED + 1))
		end
		assert(changed, "seed must drive the plan")
	end,
	["procedural props keep clear of objectives paths spawns and nodes"] = function()
		for _, layout in roles() do
			local home = layout.id == "rw.home"
			for _, item in plan(layout, SEED) do
				local p = item.position
				if not home then
					assert(not Terrain.protected(layout, p.x, p.z, ProcProps.MARGIN), layout.id .. " blocks navigation")
				end
				local radius = if home then PROMPT_CLEARANCE else ProcProps.NODE_CLEARANCE
				for _, node in layout.resourceNodes do
					assert(
						(p.x - node.position.x) ^ 2 + (p.z - node.position.z) ^ 2 >= radius ^ 2,
						layout.id .. " prop inside node " .. node.id
					)
				end
				for _, anchor in layout.anchors do
					local r = if home then PROMPT_CLEARANCE elseif anchor.id == "objective" then 40 else 24
					assert(
						(p.x - anchor.position.x) ^ 2 + (p.z - anchor.position.z) ^ 2 >= r ^ 2,
						layout.id .. " prop inside anchor " .. anchor.id
					)
				end
				for _, path in layout.paths do
					for i = 2, #path.points do
						assert(
							Terrain.distance(p.x, p.z, path.points[i - 1], path.points[i]) >= path.width / 2,
							layout.id .. " prop on path " .. path.id
						)
					end
				end
				if home then
					assert(math.sqrt(p.x ^ 2 + p.z ^ 2) >= ProcProps.HOME_RING[1], "prop inside the camp core")
				end
			end
			-- Negative mutation: the predicate rejects an objective-centred prop.
			for _, anchor in layout.anchors do
				if anchor.id == "objective" then
					assert(not ProcProps.clear(layout, anchor.position.x, anchor.position.z), "objective clearance")
				end
			end
		end
	end,
	["low profile caps procedural prop builds and high stays within the role cap"] = function()
		local low, high = RenderBudget.profiles.low, RenderBudget.profiles.high
		for _, layout in roles() do
			local placements = plan(layout, SEED)
			local lowKept = ProcProps.limit(placements, low)
			assert(#lowKept == math.min(#placements, low.meshBuildsMax), layout.id .. " low cap")
			assert(#lowKept <= 2, "low profile builds at most two props")
			assert(#ProcProps.limit(placements, high) <= ProcProps.MAX_PER_ROLE, layout.id .. " high cap")
			for index, item in lowKept do
				assert(item == placements[index], "low keeps the nearest-first prefix")
			end
		end
	end,
}
