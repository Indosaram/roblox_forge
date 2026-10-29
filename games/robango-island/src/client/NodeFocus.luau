--!strict
-- L10 gather-node focus (R05-1: the node the player is about to gather reads at a glance). One
-- client ground marker marks a single node: the node whose gather fan is open, else the node under
-- the mouse (PC hover), else the nearest harvestable node within reach of the character. It is
-- sized to the shown mesh state (the handle part is invisible, NodeMeshes). A Highlight did not
-- draw in Studio captures.
-- L10b (phone v54: the node ring could not be told apart from the player's own ring): the marker is
-- a ring of M.DASHES amber dashes (BoxHandleAdornments, wider than the player ring line), never the
-- player's solid thin teal circle (HudShell.RING, PALETTE.teal).
local M = {}

M.REACH = 10
M.STEP_SECONDS = 0.1
M.COLOR = { 255, 184, 56 }
M.MIN_RADIUS = 2.6
M.WIDTH = 0.5
M.HEIGHT = 0.3
M.DASHES = 8
-- Share of each dash slot the dash fills (the rest is the gap that makes it read as dashed).
M.DASH_FILL = 0.55

export type Candidate = { part: any, distance: number, harvestable: boolean }

--- The focused node: open fan > hover > nearest harvestable in reach (ties break on name).
function M.choose(open: any?, hover: any?, candidates: { Candidate }, reach: number?): any?
	if open then
		return open
	end
	if hover then
		return hover
	end
	local best: Candidate? = nil
	for _, entry in candidates do
		if entry.harvestable and entry.distance <= (reach or M.REACH) then
			if
				not best
				or entry.distance < best.distance
				or entry.distance == best.distance and entry.part.Name < best.part.Name
			then
				best = entry
			end
		end
	end
	return if best then best.part else nil
end

--- Ring radius around a node's shown mesh footprint.
function M.radius(visual: any): number
	return math.max(M.MIN_RADIUS, math.max(visual.Size.X, visual.Size.Z) / 2 + 0.6)
end

--- Dash layout around the node centre: per dash its angle, length (along the ring tangent) and
--- flat offset, on the centre line of a `radius` ring M.WIDTH wide.
function M.dashes(radius: number): { { angle: number, length: number, x: number, z: number } }
	local out = {}
	local mid = radius - M.WIDTH / 2
	local length = 2 * math.pi * mid / M.DASHES * M.DASH_FILL
	for index = 0, M.DASHES - 1 do
		local angle = index * 2 * math.pi / M.DASHES
		table.insert(out, { angle = angle, length = length, x = math.cos(angle) * mid, z = math.sin(angle) * mid })
	end
	return out
end

--- The mesh the ring sits under on a dressed node (the shown state), else the part itself.
function M.visual(part: any): any
	local depleted = part:GetAttribute("ForgeNodeDepleted") == true
	local name = if depleted then "ForgeNodeMeshDepleted" else "ForgeNodeMeshFull"
	return part:FindFirstChild(name) or part:FindFirstChild("ForgeNodeMeshFull") or part
end

--- Client: runs the focus ring until the returned stop is called.
--- `open` returns the node whose fan is open (or nil); `hidden` hides the ring under sheets.
function M.start(options: { open: () -> any?, hidden: () -> boolean }): () -> ()
	local players = game:GetService("Players")
	local tags = game:GetService("CollectionService")
	local input = game:GetService("UserInputService")
	local run = game:GetService("RunService")
	local player = players.LocalPlayer
	local holder = Instance.new("Folder")
	holder.Name = "ForgeNodeFocus"
	local dashes: { any } = {}
	for index = 1, M.DASHES do
		local dash = Instance.new("BoxHandleAdornment")
		dash.Name, dash.Transparency = "Dash", 0.05
		dash.Color3 = Color3.fromRGB(M.COLOR[1], M.COLOR[2], M.COLOR[3])
		-- Depth-tested (AlwaysOnTop hid the adornment in Studio captures): the marker sits on the highest
		-- ground sampled around its rim so a slope or sand mound does not swallow half of it.
		dash.AlwaysOnTop, dash.Visible = false, false
		dash.Adornee = workspace.Terrain
		dash.Parent = holder
		dashes[index] = dash
	end
	holder.Parent = player:WaitForChild("PlayerGui")
	local terrainOnly = RaycastParams.new()
	terrainOnly.FilterType = Enum.RaycastFilterType.Include
	terrainOnly.FilterDescendantsInstances = { workspace.Terrain }
	local function show(focus: any?)
		if not focus then
			for _, dash in dashes do
				dash.Visible = false
			end
			return
		end
		local visual = M.visual(focus)
		local r = M.radius(visual)
		local ground = visual.Position.Y - visual.Size.Y / 2
		for step = 0, 7 do
			local angle = step * math.pi / 4
			local at = visual.Position + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
			local hit = workspace:Raycast(at + Vector3.new(0, 12, 0), Vector3.new(0, -30, 0), terrainOnly)
			if hit then
				ground = math.max(ground, hit.Position.Y)
			end
		end
		local centre = Vector3.new(visual.Position.X, ground + 0.2, visual.Position.Z)
		for index, layout in M.dashes(r) do
			local dash = dashes[index]
			dash.Size = Vector3.new(M.WIDTH, M.HEIGHT, layout.length)
			-- Long axis (local Z) along the tangent of the ring at this angle.
			dash.CFrame = CFrame.new(centre + Vector3.new(layout.x, 0, layout.z)) * CFrame.Angles(0, -layout.angle, 0)
			dash.Visible = true
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local function hovered(): any?
		if input.TouchEnabled and not input.MouseEnabled then
			return nil
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return nil
		end
		local at = input:GetMouseLocation()
		local ray = camera:ViewportPointToRay(at.X, at.Y)
		params.FilterDescendantsInstances = if player.Character then { player.Character } else {}
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 600, params)
		local node: Instance? = hit and hit.Instance
		while node and node ~= workspace do
			if node:IsA("BasePart") and tags:HasTag(node, "ForgeSurvivalNode") then
				return node
			end
			node = node.Parent
		end
		return nil
	end
	local elapsed = M.STEP_SECONDS
	local connection = run.RenderStepped:Connect(function(dt: number)
		elapsed += dt
		if elapsed < M.STEP_SECONDS then
			return
		end
		elapsed = 0
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if options.hidden() or not root or not root:IsA("BasePart") then
			show(nil)
			return
		end
		local candidates: { Candidate } = {}
		for _, part in tags:GetTagged("ForgeSurvivalNode") do
			if part:IsA("BasePart") and part:IsDescendantOf(workspace) then
				local flat = Vector3.new(part.Position.X - root.Position.X, 0, part.Position.Z - root.Position.Z)
				table.insert(candidates, {
					part = part,
					distance = flat.Magnitude,
					harvestable = part:GetAttribute("ForgeNodeDepleted") == false,
				})
			end
		end
		local focus = M.choose(options.open(), hovered(), candidates)
		show(focus)
	end)
	return function()
		connection:Disconnect()
		holder:Destroy()
	end
end

return M
