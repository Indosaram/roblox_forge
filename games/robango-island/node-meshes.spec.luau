--!strict
-- L1 node meshes: every gather node item kind maps to an uploaded B1 node row (nodes-a, nodes-b,
-- robango-nodes-b1b), the row names match what the generators export, and a built role shows no
-- primitive gather node: each tagged node part is an invisible handle (tag, prompt, collision
-- kept) with its full/depleted mesh under it, swapped by ForgeNodeDepleted, and no per-node
-- primitive family kit remains.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local B1b = require("./src/shared/BiomeKitsB1b")
local TapRouter = require("./src/client/TapRouter")
local roblox: any = require("@lune/roblox")

local document = serde.decode("yaml", fs.readFile("games/robango-island/content.yml"))

local cases = {}

local function nodeMeshes(engine: any): any
	return engine.forge.games["robango-island"].src.shared.NodeMeshes
end

cases["every gather node item kind maps to an uploaded node row"] = function()
	local NodeMeshes = nodeMeshes(Engine.new())
	local kinds, count = {}, 0
	for _, layout in document.layouts do
		for _, node in layout.resourceNodes or {} do
			if not kinds[node.item] then
				kinds[node.item] = true
				count += 1
			end
		end
	end
	assert(count >= 53, "content has " .. count .. " node item kinds")
	for item in kinds do
		local row = NodeMeshes.row(item)
		assert(row, item .. " has no node mesh row")
		assert(NodeMeshes.PACKAGES[row.package], item .. " row package is not a node package")
	end
end

cases["node rows name the MeshParts the generators export"] = function()
	local NodeMeshes = nodeMeshes(Engine.new())
	local source = fs.readFile("games/robango-island/assets/blender/gen_nodes.py")
	local exported = {}
	for pkg, block in string.gmatch(source, '"(%u)": (%b[])') do
		for key in string.gmatch(block, '"(node%.[%w%-]+)"') do
			exported[key] = if pkg == "A" then "nodes-a" else "nodes-b"
		end
	end
	for _, node in B1b.nodes do
		exported[node.key] = "nodes-b1b"
		local row = assert(NodeMeshes.ROWS[node.key], node.key .. " missing")
		assert(row.full == node.full and row.depleted == node.depleted, node.key .. " B1b names")
	end
	local rows = 0
	for key, row in NodeMeshes.ROWS do
		rows += 1
		assert(exported[key] == row.package, key .. " is not exported by " .. row.package)
		if row.package ~= "nodes-b1b" then
			assert(row.full == key and row.depleted == key .. ".depleted", key .. " gen_nodes names")
		end
	end
	assert(rows == 37, "37 node rows, got " .. rows)
	for _, key in NodeMeshes.ITEMS do
		assert(NodeMeshes.ROWS[key], "item maps to unknown row " .. key)
	end
	-- The manifest keys the loader resolves exist in Assets (generated from the manifest).
	local assets = fs.readFile("games/robango-island/src/shared/Assets.luau")
	for _, key in NodeMeshes.PACKAGES do
		assert(string.find(assets, '["' .. key .. '"]=', 1, true), key .. " not in Assets.luau")
	end
end

-- Fake MeshPart templates named like the uploaded package parts.
local function templates(engine: any): { [string]: any }
	local rows = {}
	for _, row in nodeMeshes(engine).ROWS do
		for _, name in { row.full, row.depleted } do
			local mesh = engine.newInstance("MeshPart")
			mesh.Name, mesh.Size = name, roblox.Vector3.new(4, 3, 4)
			rows[name] = mesh
		end
	end
	return rows
end

cases["built roles show no primitive gather node and swap full/depleted"] = function()
	for _, id in { "rw.onboarding", "rw.explore10", "rw.a2.s2" } do
		local engine = Engine.new()
		local NodeMeshes = nodeMeshes(engine)
		NodeMeshes.setTemplates(templates(engine))
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, id, 1776)
		local root = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld")
		local tags = engine.game:GetService("CollectionService")
		local ids, nodes, visible = {}, 0, 0
		for _, part in tags:GetTagged("ForgeSurvivalNode") do
			if not part:IsDescendantOf(root) then
				continue
			end
			nodes += 1
			ids[part.Name] = true
			if part.Transparency ~= 1 then
				visible += 1
			end
			-- The handle keeps collision and the gameplay attributes.
			assert(part.CanCollide ~= false and part:GetAttribute("ForgeNodeItem"), part.Name .. " handle")
			local full = assert(part:FindFirstChild("ForgeNodeMeshFull"), part.Name .. " has no full mesh")
			local depleted = assert(part:FindFirstChild("ForgeNodeMeshDepleted"), part.Name .. " depleted mesh")
			assert(full.ClassName == "MeshPart" and not full.CanCollide and not full.CanTouch, "decor mesh")
			assert(full.Transparency == 0 and full.CanQuery and depleted.Transparency == 1, "full shows")
			-- Tap routing: a ray hit on the visible mesh walks up to the tagged node part.
			assert(full.Parent == part and tags:HasTag(full.Parent, "ForgeSurvivalNode"), "mesh under node")
			part:SetAttribute("ForgeNodeDepleted", true)
			assert(full.Transparency == 1 and not full.CanQuery, part.Name .. " full hides when depleted")
			assert(depleted.Transparency == 0 and depleted.CanQuery, part.Name .. " depleted shows")
			part:SetAttribute("ForgeNodeDepleted", false)
			assert(full.Transparency == 0 and depleted.Transparency == 1, part.Name .. " regrows")
		end
		assert(nodes > 0, id .. " has gather nodes")
		assert(visible == 0, id .. ": " .. visible .. " primitive gather nodes visible")
		-- No per-node primitive family kit: nothing in the role world is owned by a node through
		-- the `<nodeId>.kit` naming TapRouter.kitOwner resolves.
		for _, child in root:GetDescendants() do
			local owner = TapRouter.kitOwner(child.Name)
			assert(not (owner and ids[owner]), id .. ": primitive node kit " .. child.Name)
		end
		NodeMeshes.setTemplates(nil)
		world.destroy()
	end
end

cases["small node rows scale up to the readable footprint and cutout rows restore their base"] = function()
	local engine = Engine.new()
	local NodeMeshes = nodeMeshes(engine)
	local function sized(x: number, z: number): any
		local mesh = engine.newInstance("MeshPart")
		mesh.Size = roblox.Vector3.new(x, 1, z)
		return mesh
	end
	assert(NodeMeshes.scaleFor(sized(6, 3)) == 1, "a wide row keeps its size")
	assert(NodeMeshes.scaleFor(sized(2.5, 1)) == NodeMeshes.MIN_FOOTPRINT / 2.5, "a small row reaches the footprint")
	assert(NodeMeshes.scaleFor(sized(1, 1)) == NodeMeshes.MAX_SCALE, "scale is capped")
	-- A baked cutout template (MeshTexture.bake) is shown at its base transparency, never 0.
	local rows = templates(engine)
	for _, mesh in rows do
		mesh.Transparency = 0.02
		mesh:SetAttribute("ForgeBaseTransparency", 0.02)
	end
	NodeMeshes.setTemplates(rows)
	local world = engine.role.build(Content, Source, Policy, function()
		return 0
	end, "rw.onboarding", 1776)
	local checked = 0
	for _, part in engine.game:GetService("CollectionService"):GetTagged("ForgeSurvivalNode") do
		local full = part:FindFirstChild("ForgeNodeMeshFull")
		local depleted = part:FindFirstChild("ForgeNodeMeshDepleted")
		if full and depleted then
			checked += 1
			assert(full.Transparency == 0.02 and depleted.Transparency == 1, part.Name .. " full at base")
			part:SetAttribute("ForgeNodeDepleted", true)
			assert(full.Transparency == 1 and depleted.Transparency == 0.02, part.Name .. " depleted at base")
			part:SetAttribute("ForgeNodeDepleted", false)
			assert(full.Transparency == 0.02, part.Name .. " regrows at base")
		end
	end
	assert(checked > 0, "onboarding nodes dressed")
	NodeMeshes.setTemplates(nil)
	world.destroy()
end

cases["a missing template keeps the primitive handle visible"] = function()
	local engine = Engine.new()
	local NodeMeshes = nodeMeshes(engine)
	NodeMeshes.setTemplates({})
	local world = engine.role.build(Content, Source, Policy, function()
		return 0
	end, "rw.onboarding", 1776)
	local shown = 0
	for _, part in engine.game:GetService("CollectionService"):GetTagged("ForgeSurvivalNode") do
		if part:GetAttribute("ForgeNodeItem") then
			assert(part.Transparency ~= 1 and not part:FindFirstChild("ForgeNodeMeshFull"), "fallback")
			shown += 1
		end
	end
	assert(shown > 0, "onboarding nodes")
	NodeMeshes.setTemplates(nil)
	world.destroy()
end

return cases
