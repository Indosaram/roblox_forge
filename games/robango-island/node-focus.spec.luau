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

-- L10b (phone v54): the node marker could not be told apart from the player's own teal ring. The
-- marker is a dashed amber ring, a different colour and a different shape from HudShell.RING.
cases["the node focus marker is dashed amber, unlike the player's solid teal ring"] = function()
	local Shell = require("../../genres/survival-coop/module/HudShell")
	local teal = Shell.PALETTE.teal
	local r, g, b = NodeFocus.COLOR[1], NodeFocus.COLOR[2], NodeFocus.COLOR[3]
	local distance = math.sqrt((r - teal.r) ^ 2 + (g - teal.g) ^ 2 + (b - teal.b) ^ 2)
	assert(distance > 150, "marker colour far from the player teal, distance " .. distance)
	assert(r > b + 100, "warm (amber) marker")
	assert(NodeFocus.DASHES and NodeFocus.DASHES >= 6, "the marker is dashed")
	local dashes = NodeFocus.dashes(3.6)
	assert(#dashes == NodeFocus.DASHES, "one dash per slot")
	local mid = 3.6 - NodeFocus.WIDTH / 2
	local slot = 2 * math.pi * mid / NodeFocus.DASHES
	for _, dash in dashes do
		assert(math.abs(math.sqrt(dash.x ^ 2 + dash.z ^ 2) - mid) < 1e-6, "dash on the ring line")
		assert(dash.length < slot * 0.8, "visible gap between dashes")
	end
	assert(NodeFocus.WIDTH > 0.22 * 1.5, "marker line clearly wider than the player ring line")
	local source = require("@lune/fs").readFile("games/robango-island/src/client/NodeFocus.luau")
	assert(not string.find(source, "CylinderHandleAdornment", 1, true), "no solid cylinder ring like the player's")
	assert(string.find(source, "BoxHandleAdornment", 1, true), "dash adornments")
end

-- L10b: floating node labels carry a small level / tool line under the name (R05-1 "돌멩이 Lv 1").
cases["node label hint shows the level and the tool, wired into the HUD shell"] = function()
	local GatherOffer = require("./src/client/GatherOffer")
	local lines = { hand = "By hand", tool = "Needs %s", level = "Lv %d" }
	local function text(key: string): string?
		return lines[key]
	end
	local function tag(name: string): string
		return if name == "cutting" then "Knife" else name
	end
	local rows = {
		{ id = "rw.onboarding.fiber", level = 1 },
		{ id = "rw.a1.s1.ore", level = 3, requiredToolTag = "cutting" },
		{ id = "fiber-bush-01" },
	}
	local a, b, c, gone = node("a"), node("b"), node("c"), node("d", true)
	a:SetAttribute("ForgeNodeId", "rw.onboarding.fiber")
	b:SetAttribute("ForgeNodeId", "rw.a1.s1.ore")
	c:SetAttribute("ForgeNodeId", "fiber-bush-01")
	gone:SetAttribute("ForgeNodeId", "rw.onboarding.fiber")
	assert(GatherOffer.hint(a, rows, text, tag) == "Lv 1 - By hand", "hand node")
	assert(GatherOffer.hint(b, rows, text, tag) == "Lv 3 - Needs Knife", "tool node")
	assert(GatherOffer.hint(c, rows, text, tag) == "By hand", "no level authored")
	assert(GatherOffer.hint(gone, rows, text, tag) == nil, "a depleted node shows its name only")
	local fs = require("@lune/fs")
	local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
	assert(string.find(client, "GatherOffer.hint(part, nodeRows()", 1, true), "client passes the hint to the shell")
	local hud = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
	assert(string.find(hud, "hint = shellOptions.hint", 1, true), "SurvivalHUD forwards the hint to the overlays")
	local csv = fs.readFile("games/robango-island/locale/strings.csv")
	assert(string.find(csv, "\ncli.gather.hand,", 1, true), "hand hint row")
	assert(string.find(csv, "\ncli.gather.tool,", 1, true), "tool hint row")
end

return cases
