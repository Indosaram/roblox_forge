--!strict
-- L1: gather nodes render their uploaded B1 node meshes (asset catalog section 5) instead of
-- primitive Balls and Cylinders. Three packages hold the rows: `nodes-a` and `nodes-b`
-- (gen_nodes.py: MeshParts `<key>` and `<key>.depleted`) and `robango-nodes-b1b`
-- (gen_nodes_b1b.py: `<key_underscored>_full` / `_depleted`). BiomeKits.load is the one loader:
-- this module registers the three node packages as extra kits and reads the shared template
-- table. The node part stays the gameplay handle (tag, prompt, attributes, collision) and turns
-- invisible once its mesh is placed; a failed load leaves the primitive handle visible.
local M = {}

export type Row = { package: string, full: string, depleted: string }

-- BiomeKits kit name -> manifest key (assets/manifest.yml -> Assets.luau).
M.PACKAGES = {
	["nodes-a"] = "nodes-a",
	["nodes-b"] = "nodes-b",
	["nodes-b1b"] = "robango-nodes-b1b",
}
M.KITS = { "nodes-a", "nodes-b", "nodes-b1b" }

local A = {
	"node.branch-pile",
	"node.fallen-tree",
	"node.driftwood-line",
	"node.fiber-bush",
	"node.berry-bush",
	"node.birch-stand",
	"node.chanterelle-log",
	"node.hazel-thicket",
	"node.leaf-litter",
	"node.flax-patch",
	"node.wild-crop",
	"node.fruit-tree",
	"node.seed-pod",
}
local B = {
	"node.stone-pile",
	"node.flint-outcrop",
	"node.flint-scree",
	"node.boulder-field",
	"node.clam-bed",
	"node.meat-cache",
	"node.carcass",
	"node.water-spring",
	"node.fish-school",
	"node.relief-crate",
	"node.survey-cairn",
	"node.signal-shard",
	"node.rescue-marker",
	"node.journal-cache",
}
local B1B = {
	"node.cattail-stand",
	"node.clay-bank",
	"node.cordgrass-tussock",
	"node.reed-bed",
	"node.samphire-flat",
	"node.iron-vein",
	"node.copper-vein",
	"node.basalt-face",
	"node.volcanic-vent",
	"node.charcoal-pit",
}

-- Row key -> package kit and the MeshPart names of its two states.
M.ROWS = {} :: { [string]: Row }
for _, key in A do
	M.ROWS[key] = { package = "nodes-a", full = key, depleted = key .. ".depleted" }
end
for _, key in B do
	M.ROWS[key] = { package = "nodes-b", full = key, depleted = key .. ".depleted" }
end
for _, key in B1B do
	local base = string.gsub(string.gsub(key, "%.", "_"), "%-", "_")
	M.ROWS[key] = { package = "nodes-b1b", full = base .. "_full", depleted = base .. "_depleted" }
end

-- content.yml resourceNodes[].item -> node row (catalog section 5 "content" column).
M.ITEMS = {
	branch = "node.branch-pile",
	wood = "node.fallen-tree",
	fiber = "node.fiber-bush",
	berry = "node.berry-bush",
	["birch-bark"] = "node.birch-stand",
	chanterelle = "node.chanterelle-log",
	hazelnut = "node.hazel-thicket",
	leaves = "node.leaf-litter",
	flax = "node.flax-patch",
	["flax-seed"] = "node.flax-patch",
	flaxseed = "node.flax-patch",
	potato = "node.wild-crop",
	onion = "node.wild-crop",
	corn = "node.wild-crop",
	wheat = "node.wild-crop",
	banana = "node.fruit-tree",
	fig = "node.fruit-tree",
	apple = "node.fruit-tree",
	["potato-seed"] = "node.seed-pod",
	["onion-seed"] = "node.seed-pod",
	["corn-seed"] = "node.seed-pod",
	["wheat-seed"] = "node.seed-pod",
	["banana-seed"] = "node.seed-pod",
	["fig-seed"] = "node.seed-pod",
	["apple-seed"] = "node.seed-pod",
	stone = "node.stone-pile",
	flint = "node.flint-outcrop",
	fieldstone = "node.boulder-field",
	granite = "node.boulder-field",
	clam = "node.clam-bed",
	["shell-fragment"] = "node.clam-bed",
	meat = "node.meat-cache",
	bone = "node.carcass",
	hide = "node.carcass",
	water = "node.water-spring",
	fish = "node.fish-school",
	["relief-unit"] = "node.relief-crate",
	["survey-sample"] = "node.survey-cairn",
	["signal-fragment"] = "node.signal-shard",
	fragment = "node.signal-shard",
	["rescue-marker"] = "node.rescue-marker",
	chapter = "node.journal-cache",
	["cattail-root"] = "node.cattail-stand",
	clay = "node.clay-bank",
	["marsh-clay"] = "node.clay-bank",
	reed = "node.reed-bed",
	samphire = "node.samphire-flat",
	["iron-ore"] = "node.iron-vein",
	["copper-ore"] = "node.copper-vein",
	basalt = "node.basalt-face",
	["volcanic-ore"] = "node.volcanic-vent",
	["volcanic-ash"] = "node.volcanic-vent",
	charcoal = "node.charcoal-pit",
} :: { [string]: string }

--- The node row an item kind renders with (nil for an unmapped item).
function M.row(item: string): Row?
	local key = M.ITEMS[item]
	return if key then M.ROWS[key] else nil
end

local injected: { [string]: any }? = nil

--- Test seam: specs inject fake MeshPart templates (name -> part) instead of InsertService.
function M.setTemplates(value: { [string]: any }?)
	injected = value
end

--- Server: loads the three node packages once through BiomeKits.load (yields) and returns the
--- shared name -> MeshPart template table. Headless engines get an empty table.
function M.load(kits: any, assets: any): { [string]: any }
	if injected then
		return injected
	end
	for kit, key in M.PACKAGES do
		kits.packages[kit] = key
	end
	return kits.load(M.KITS, assets)
end

local STATES = { full = "ForgeNodeMeshFull", depleted = "ForgeNodeMeshDepleted" }

M.MIN_FOOTPRINT = 4
M.MAX_SCALE = 1.8

--- Uniform scale that brings a row's widest horizontal extent up to MIN_FOOTPRINT (never shrinks).
function M.scaleFor(template: any): number
	local wide = math.max(template.Size.X, template.Size.Z)
	if wide <= 0 or wide >= M.MIN_FOOTPRINT then
		return 1
	end
	return math.min(M.MIN_FOOTPRINT / wide, M.MAX_SCALE)
end

local function show(target: any)
	-- Without a depleted row the full mesh stays up while the node regrows.
	local depleted = target:GetAttribute("ForgeNodeDepleted") == true and target:FindFirstChild(STATES.depleted) ~= nil
	for state, name in STATES do
		local mesh = target:FindFirstChild(name)
		if mesh then
			local on = (state == "depleted") == depleted
			-- A baked cutout card is shown at its base transparency (MeshTexture.bake), never 0.
			local base = mesh:GetAttribute("ForgeBaseTransparency")
			mesh.Transparency = if on then (if type(base) == "number" then base else 0) else 1
			mesh.CanQuery = on
		end
	end
end

--- Hangs the full and depleted mesh of `row` under the node part `target`, seated on the part's
--- ground (its bottom face), and hides the part. The part keeps every tag, prompt, attribute and
--- its collision; the meshes never collide and are queryable only while shown, so a tap on the
--- visible mesh walks up to the tagged node. ForgeNodeDepleted swaps the two states. Returns false
--- (the primitive part stays visible) when the full template is missing.
function M.dress(target: any, row: Row?, templates: { [string]: any }, yaw: number): boolean
	local full = row and templates[row.full]
	if not row or not full then
		return false
	end
	local bottom = target.Position - Vector3.new(0, target.Size.Y / 2, 0)
	for state, name in STATES do
		local template = if state == "full" then full else templates[row.depleted]
		if not template then
			continue
		end
		local mesh = template:Clone()
		mesh.Name = name
		mesh.Anchored, mesh.CanCollide, mesh.CanTouch = true, false, false
		-- L10 (p134 v49: nodes read as props): small rows (stone pile, seed pod, carcass) grow to a
		-- MIN_FOOTPRINT-stud footprint so they read at the 95-stud play camera; both states share the
		-- full row's factor so the swap never jumps in size.
		mesh.Size *= M.scaleFor(full)
		-- Sink below the handle's 0.25-stud lift so the mesh skirt meets the voxel surface; flat rows
		-- (fish school, signal shard) ride just above it instead (BiomeKits.place uses the same rule).
		local sink = if mesh.Size.Y < 0.6 then 0.2 else 0.45
		mesh.CFrame = CFrame.new(bottom.X, bottom.Y - sink + mesh.Size.Y / 2, bottom.Z)
			* CFrame.Angles(0, math.rad(yaw), 0)
		mesh.Position = mesh.CFrame.Position
		mesh:SetAttribute("ForgeNodeMeshRow", row.full)
		mesh.Parent = target
	end
	target.Transparency = 1
	target:SetAttribute("ForgeNodeMesh", true)
	show(target)
	target.AttributeChanged:Connect(function(attribute: string)
		if attribute == "ForgeNodeDepleted" then
			show(target)
		end
	end)
	return true
end

return M
