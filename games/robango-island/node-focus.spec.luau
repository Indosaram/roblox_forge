--!strict
-- L10 gather-node focus: the ring marks the node whose gather fan is open, else the hovered node,
-- else the nearest harvestable node within reach; it sizes to the shown mesh state.
local roblox: any = require("@lune/roblox")
local NodeFocus = require("./src/client/NodeFocus")

local function node(name: string, depleted: boolean?): any
	local part = roblox.Instance.new("Part")
	part.Name = name
	part:SetAttribute("ForgeNodeDepleted", depleted == true)
	for _, state in { "ForgeNodeMeshFull", "ForgeNodeMeshDepleted" } do
		local mesh = roblox.Instance.new("MeshPart")
		mesh.Name = state
		mesh.Size = if state == "ForgeNodeMeshFull" then roblox.Vector3.new(6, 3, 2) else roblox.Vector3.new(2, 1, 2)
		mesh.Parent = part
	end
	return part
end

local cases = {}

cases["focus prefers the open fan, then hover, then the nearest harvestable node in reach"] = function()
	local a, b, c, d = node("a"), node("b"), node("c", true), node("d")
	local candidates = {
		{ part = a, distance = 6, harvestable = true },
		{ part = b, distance = 4, harvestable = true },
		{ part = c, distance = 1, harvestable = false },
		{ part = d, distance = 12, harvestable = true },
	}
	assert(NodeFocus.choose(d, a, candidates) == d, "open fan wins")
	assert(NodeFocus.choose(nil, a, candidates) == a, "hover beats proximity")
	assert(NodeFocus.choose(nil, nil, candidates) == b, "nearest harvestable, depleted skipped")
	assert(NodeFocus.choose(nil, nil, { candidates[4] }) == nil, "nothing beyond reach")
	assert(NodeFocus.choose(nil, nil, { candidates[4] }, 20) == d, "reach is configurable")
	local e = node("e")
	local tie = { { part = e, distance = 4, harvestable = true }, { part = b, distance = 4, harvestable = true } }
	assert(NodeFocus.choose(nil, nil, tie) == b, "ties break on name")
end

cases["the ring follows the shown mesh state and never shrinks below its minimum"] = function()
	local full, empty = node("f"), node("g", true)
	assert(NodeFocus.visual(full).Name == "ForgeNodeMeshFull", "full state")
	assert(NodeFocus.visual(empty).Name == "ForgeNodeMeshDepleted", "depleted state")
	local bare = roblox.Instance.new("Part")
	assert(NodeFocus.visual(bare) == bare, "an undressed node is its own visual")
	assert(NodeFocus.radius(NodeFocus.visual(full)) == 3 + 0.6, "radius wraps the widest extent")
	assert(NodeFocus.radius(NodeFocus.visual(empty)) == NodeFocus.MIN_RADIUS, "small mesh keeps the minimum")
end

return cases
