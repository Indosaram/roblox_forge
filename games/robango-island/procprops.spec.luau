--!strict
-- L2 (asset-audit G10): role worlds build no procedural props; B1 mesh kits and B3 rows dress
-- them. ProcProps keeps only the seating helpers the Studio dev-island meshes use.
local ProcProps = require("./src/shared/ProcProps")
local ProcAssets = require("./src/shared/ProcAssets")
local Prop = require("../../core/domain/procgen/Prop")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")

local UPRIGHT_DEGREES = 25

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
	["role worlds build no procedural props and procgen keeps no role-decor keys"] = function()
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(not string.find(client, "ForgeProcProps", 1, true), "client still builds role-world ProcProps decor")
		assert(not string.find(client, "ProcProps.plan", 1, true), "client still plans role-world props")
		assert((ProcProps :: any).plan == nil, "ProcProps no longer plans role decor")
		local keys = {}
		for key in ProcAssets :: any do
			table.insert(keys, key)
		end
		table.sort(keys)
		-- Dev-island meshes (client), the genre starter prop and the two procedural creatures only.
		local expected = {
			"robango-amber-hunter",
			"robango-crest-grazer",
			"robango-flint-crystal",
			"robango-forest-tree",
			"survival-coop-starter-prop",
		}
		assert(table.concat(keys, ",") == table.concat(expected, ","), "procgen keys: " .. table.concat(keys, ","))
	end,
	["every remaining generated prop builds an upright Part fallback"] = function()
		for key, entry in ProcAssets :: any do
			if entry.kind ~= "prop" then
				continue
			end
			local parts, model = fallback(key)
			assert(#parts > 0, key .. " builds no fallback parts")
			local pivot = pivotOf(model)
			assert(
				pivot.UpVector.Y > 0.999 and pivot.RightVector.X > 0.999,
				key .. " fallback pivot is rotated, so PivotTo would tip the prop over"
			)
			if entry.archetype == "tree" then
				local degrees = tilt(parts[1].CFrame.RightVector)
				assert(
					degrees <= UPRIGHT_DEGREES,
					string.format("%s trunk lies %.1f degrees off vertical", key, degrees)
				)
			end
		end
	end,
	["props seat their bounding-box bottom on the ground"] = function()
		local CFrame, Vector3 = roblox.CFrame, roblox.Vector3
		for _, key in { "survival-coop-starter-prop", "robango-flint-crystal", "robango-forest-tree" } do
			local parts, model = fallback(key)
			local ground = 3.09
			-- The client pivots the model onto the terrain hit, then applies the seat offset.
			local place = CFrame.new(10, ground, -4) * CFrame.Angles(0, math.rad(37), 0)
			pivotTo(model, parts, place)
			if key == "robango-forest-tree" then
				local degrees = tilt(parts[1].CFrame.RightVector)
				assert(
					degrees <= UPRIGHT_DEGREES,
					string.format("tree trunk lies %.1f degrees off vertical after PivotTo", degrees)
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
		for _, key in { "robango-forest-tree", "survival-coop-starter-prop", "robango-flint-crystal" } do
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
}
