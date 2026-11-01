--!strict
-- Waypoint: one objective marker toward a world point (C1 dead end 2: the ridge-camp leg had no
-- on-screen direction, at night, p134 c1). Three parts, created once and reused for every target:
-- (a) a screen arrow with the distance (on the target when in view, clamped to the screen edge and
-- turned toward it when not), (b) a pin on the HUD minimap (on its rim when the target is beyond
-- the map window), (c) a tall soft neon beam at the target, visible at night. Everything hides
-- within HIDE_STUDS of the target or with no target. Generic: the opening drives it per step, and a
-- guide can drive it the same way. No connection of its own: the owner calls `step` per frame.
-- Distances read as the HUD's other trackers do ('채집: %s (%dm)'): one stud shows as one metre.
local HudShell = require("../../../../genres/survival-coop/module/HudShell")
local M = {}

M.HIDE_STUDS = 8
M.EDGE_MARGIN = 36 -- px from the gui edge for the clamped arrow
M.BEAM_HEIGHT, M.BEAM_WIDTH = 90, 2.5
M.MARKER_LIFT = 7 -- studs above the ground where the on-screen marker points

--- Position of `id` in a content layout: an anchor, else a resource node (the bone heap, the fiber
--- bush, the flint scree are nodes). nil when the layout has neither.
function M.resolve(layout: any, id: string): Vector3?
	if type(layout) ~= "table" then
		return nil
	end
	for _, list in { layout.anchors or {}, layout.resourceNodes or {} } :: { { any } } do
		for _, entry in list do
			if entry.id == id and entry.position then
				return Vector3.new(entry.position.x, entry.position.y, entry.position.z)
			end
		end
	end
	return nil
end

--- The content layout `layoutId`, or nil.
function M.layout(content: any, layoutId: string?): any?
	for _, layout in (if type(content) == "table" then content.layouts or {} else {}) :: { any } do
		if layout.id == layoutId then
			return layout
		end
	end
	return nil
end

--- Flat (x, z) distance in studs.
function M.distance(a: Vector3, b: Vector3): number
	return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
end

--- Whole metres shown for a stud distance.
function M.meters(studs: number): number
	return math.max(0, math.floor(studs + 0.5))
end

--- Whether the marker shows for a player at `root` and a target at `target`.
function M.shown(root: Vector3?, target: Vector3?): boolean
	return root ~= nil and target ~= nil and M.distance(root, target) > M.HIDE_STUDS
end

--- Screen arrow placement in a `width` x `height` gui for a projected point (`x`, `y`) with camera
--- depth `depth` (negative = behind the camera). Returns the arrow centre, its rotation in degrees
--- (0 points up) and whether the point itself is on screen (then the arrow sits on it, pointing down).
function M.edge(
	x: number,
	y: number,
	depth: number,
	width: number,
	height: number,
	margin: number?
): (number, number, number, boolean)
	local m = margin or M.EDGE_MARGIN
	local inside = depth > 0 and x >= m and x <= width - m and y >= m and y <= height - m
	if inside then
		return x, y, 180, true
	end
	local cx, cy = width / 2, height / 2
	local dx, dy = x - cx, y - cy
	if depth <= 0 then
		-- Behind the camera the projection mirrors through the centre.
		dx, dy = -dx, -dy
	end
	if math.abs(dx) < 1e-6 and math.abs(dy) < 1e-6 then
		dy = 1 -- straight behind: point down (toward the player's back)
	end
	local hx, hy = math.max(cx - m, 1), math.max(cy - m, 1)
	local k = math.min(hx / math.max(math.abs(dx), 1e-6), hy / math.max(math.abs(dy), 1e-6))
	return cx + dx * k, cy + dy * k, math.deg(math.atan2(dx, -dy)), false
end

--- Minimap pin for a world offset (`dx`, `dz`) on a round map `side` px wide, turned like the HUD
--- map (HudShell.mapPoint). Beyond the map window the pin sits on the rim toward the target;
--- returns the pin centre and whether it is on the rim.
function M.pin(dx: number, dz: number, side: number, lookX: number?, lookZ: number?): (number, number, boolean)
	local radius = side / 2
	local rim = math.max(radius - 6, 1)
	local x, y = HudShell.mapPoint(dx, dz, side, nil, lookX, lookZ)
	if x and y and (x - radius) ^ 2 + (y - radius) ^ 2 <= rim * rim then
		return x, y, false
	end
	-- Direction only: map the offset with a window wide enough to hold it, then push it to the rim.
	local far = 2 * math.max(math.abs(dx), math.abs(dz)) + 2
	local fx, fy = HudShell.mapPoint(dx, dz, side, far, lookX, lookZ)
	local ux, uy = (fx or radius) - radius, (fy or radius) - radius
	local length = math.sqrt(ux * ux + uy * uy)
	if length < 1e-6 then
		return radius, radius, false
	end
	return radius + ux / length * rim, radius + uy / length * rim, true
end

export type Options = {
	playerGui: Instance, -- the arrow gets its own inset-free ScreenGui here (gui px = viewport px)
	stage: Instance, -- world folder for the beam
	camera: () -> any?,
	minimap: () -> any?, -- the HUD minimap Frame (PlayerGui "Minimap"), or nil
	label: (meters: number) -> string,
	ground: ((Vector3) -> number?)?,
	color: Color3?,
}

function M.start(options: Options): any
	local tint = options.color or Color3.fromRGB(255, 204, 92)
	-- (c) Beam: a neon core and a wider faint halo, both non-physical.
	local function column(name: string, width: number, transparency: number): Part
		local part = Instance.new("Part")
		part.Name, part.Shape, part.Material = name, Enum.PartType.Cylinder, Enum.Material.Neon
		part.Size, part.Color, part.Transparency = Vector3.new(M.BEAM_HEIGHT, width, width), tint, transparency
		part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch, part.CastShadow = true, false, false, false, false
		return part
	end
	local beam = column("WaypointBeam", M.BEAM_WIDTH, 0.55)
	local halo = column("Halo", M.BEAM_WIDTH * 3, 0.85)
	halo.Parent = beam
	-- (a) Arrow: a glyph turned toward the target and the distance under it.
	local arrow = Instance.new("TextButton")
	arrow.Name, arrow.BackgroundTransparency, arrow.AnchorPoint = "WaypointArrow", 1, Vector2.new(0.5, 0.5)
	arrow.Size, arrow.Visible, arrow.ZIndex = UDim2.fromOffset(56, 64), false, 5
	arrow.Text, arrow.AutoButtonColor = "", false
	local glyph = Instance.new("TextLabel")
	glyph.Name, glyph.BackgroundTransparency, glyph.Text = "Glyph", 1, "\u{25B2}"
	glyph.AnchorPoint, glyph.Position, glyph.Size =
		Vector2.new(0.5, 0.5), UDim2.fromOffset(28, 20), UDim2.fromOffset(32, 32)
	glyph.TextColor3, glyph.TextSize, glyph.Font = tint, 30, Enum.Font.BuilderSansBold
	glyph.TextStrokeColor3, glyph.TextStrokeTransparency, glyph.ZIndex = Color3.new(0, 0, 0), 0.2, 5
	glyph.Parent = arrow
	local distance = Instance.new("TextLabel")
	distance.Name, distance.BackgroundColor3, distance.BackgroundTransparency = "Distance", Color3.new(0, 0, 0), 0.45
	distance.AnchorPoint, distance.Position, distance.Size =
		Vector2.new(0.5, 0), UDim2.fromOffset(28, 40), UDim2.fromOffset(56, 20)
	distance.TextColor3, distance.TextSize, distance.Font = Color3.new(1, 1, 1), 14, Enum.Font.BuilderSansBold
	distance.Text, distance.ZIndex, distance.Parent = "", 5, arrow
	local round = Instance.new("UICorner")
	round.CornerRadius, round.Parent = UDim.new(0.5, 0), distance
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "ForgeWaypoint", false, 30
	gui.IgnoreGuiInset, gui.ScreenInsets = true, Enum.ScreenInsets.None
	gui.Parent = options.playerGui
	arrow.Parent = gui
	-- (b) Minimap pin.
	local pin = Instance.new("Frame")
	pin.Name, pin.BorderSizePixel, pin.AnchorPoint = "WaypointPin", 0, Vector2.new(0.5, 0.5)
	pin.Size, pin.BackgroundColor3, pin.ZIndex, pin.Visible = UDim2.fromOffset(10, 10), tint, 4, false
	local pinRound = Instance.new("UICorner")
	pinRound.CornerRadius, pinRound.Parent = UDim.new(0.5, 0), pin
	local pinRim = Instance.new("UIStroke")
	pinRim.Color, pinRim.Thickness, pinRim.Parent = Color3.new(0, 0, 0), 1.5, pin

	local placedAt: Vector3? = nil
	local floor = 0
	local api: any = { beam = beam, arrow = arrow, pin = pin, gui = gui }
	local function hide()
		arrow.Visible, pin.Visible = false, false
		if beam.Parent ~= nil then
			beam.Parent = nil
		end
	end
	--- Per frame: the player's root position and the current target (nil hides everything).
	function api.step(root: Vector3?, target: Vector3?)
		if not root or not target or not M.shown(root, target) then
			hide()
			return
		end
		local at = target :: Vector3
		if placedAt ~= at then
			-- One ground ray per target, not per frame.
			placedAt = at
			floor = (if options.ground then options.ground(at) else nil) or at.Y
			beam.CFrame = CFrame.new(at.X, floor + M.BEAM_HEIGHT / 2, at.Z) * CFrame.Angles(0, 0, math.rad(90))
			halo.CFrame = beam.CFrame
		end
		if beam.Parent ~= options.stage then
			beam.Parent = options.stage
		end
		local meters = M.meters(M.distance(root, at))
		distance.Text = options.label(meters)
		local camera = options.camera()
		if camera then
			local size = camera.ViewportSize
			local point = camera:WorldToViewportPoint(Vector3.new(at.X, floor + M.MARKER_LIFT, at.Z))
			local x, y, rotation = M.edge(point.X, point.Y, point.Z, size.X, size.Y, M.EDGE_MARGIN)
			arrow.Position, glyph.Rotation, arrow.Visible = UDim2.fromOffset(x, y), rotation, true
		else
			arrow.Visible = false
		end
		local map = options.minimap()
		if map then
			if pin.Parent ~= map then
				pin.Parent = map
			end
			local look = if camera then camera.CFrame.LookVector else Vector3.new(0, 0, -1)
			local px, py = M.pin(at.X - root.X, at.Z - root.Z, map.AbsoluteSize.X, look.X, look.Z)
			pin.Position, pin.Visible = UDim2.fromOffset(px, py), true
		else
			pin.Visible = false
		end
	end
	function api.destroy()
		beam:Destroy()
		gui:Destroy()
		pin:Destroy()
	end
	return api
end

return M
