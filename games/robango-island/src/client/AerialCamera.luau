--!strict
-- Roblox-shaped camera and controls are injected so no foreground APIs are needed.
local M = {}
M.AERIAL_DENSITY = 0.02
-- The overview used to inherit the 30-degree quarter-view lens, so fitting a 768-stud archipelago
-- island put the camera 1700-3700 studs out (y 1508 in p2/p83). That is past the engine's draw
-- distance once automatic graphics quality drops: p83 saw only the skybox, not even the sea below.
-- Widen the lens instead, so the camera stays near MAX_DISTANCE from the island centre.
M.MAX_DISTANCE = 900
M.MAX_FIELD_OF_VIEW = 110
-- Bottom band kept free for the Roblox touch thumbstick (bottom-left) and jump (bottom-right).
M.TOUCH_RESERVE = 150
M.CONTROL_MIN = 44

type Point = { x: number, y: number, z: number }

--- Vertical field of view that frames the bounds (AerialView's 1.1 sphere margin) within
--- MAX_DISTANCE, never narrower than the current lens and never wider than MAX_FIELD_OF_VIEW.
function M.fieldOfView(minimum: Point, maximum: Point, aspect: number, fov: number): number
	local radius = math.sqrt((maximum.x - minimum.x) ^ 2 + (maximum.y - minimum.y) ^ 2 + (maximum.z - minimum.z) ^ 2)
		/ 2
	local need = radius * 1.1 / M.MAX_DISTANCE
	if need >= 1 then
		return math.max(fov, M.MAX_FIELD_OF_VIEW)
	end
	local angle = math.asin(need)
	local vertical = if aspect >= 1 then angle else math.atan(math.tan(angle) / aspect)
	return math.max(fov, math.min(math.deg(vertical) * 2, M.MAX_FIELD_OF_VIEW))
end

local function partBounds(root: any): (Point?, Point?)
	local minimum: Point?, maximum: Point? = nil, nil
	for _, part in root:GetDescendants() do
		if part:IsA("BasePart") then
			local cf, half = part.CFrame, part.Size / 2
			for _, x in { -1, 1 } do
				for _, y in { -1, 1 } do
					for _, z in { -1, 1 } do
						local p = cf.Position
							+ cf.RightVector * (x * half.X)
							+ cf.UpVector * (y * half.Y)
							- cf.LookVector * (z * half.Z)
						local lo: Point = minimum or { x = p.X, y = p.Y, z = p.Z }
						local hi: Point = maximum or { x = p.X, y = p.Y, z = p.Z }
						minimum = { x = math.min(lo.x, p.X), y = math.min(lo.y, p.Y), z = math.min(lo.z, p.Z) }
						maximum = { x = math.max(hi.x, p.X), y = math.max(hi.y, p.Y), z = math.max(hi.z, p.Z) }
					end
				end
			end
		end
	end
	return minimum, maximum
end

local function union(a: Point?, b: Point?, pick: (number, number) -> number): Point?
	if a == nil or b == nil then
		return a or b
	end
	return { x = pick(a.x, b.x), y = pick(a.y, b.y), z = pick(a.z, b.z) }
end

--- Island bounds for every world a player can stand on: a role world (its catalog layout
--- bounds, which cover the generated terrain, joined with its parts), the Studio preview
--- island (its parts joined with the preview terrain extents), else a box around `focus`.
--- Returns nil only when there is no world and no focus.
function M.worldBounds(workspace: any, layouts: { any }, preview: { min: Point, max: Point }, focus: Point?): (any, any)
	local minimum: Point?, maximum: Point? = nil, nil
	local role = workspace:FindFirstChild("ForgeRoleWorld")
	if role then
		local id = role:GetAttribute("ForgeLayoutId")
		for _, layout in layouts do
			if layout.id == id then
				minimum, maximum = table.clone(layout.bounds.min), table.clone(layout.bounds.max)
			end
		end
		local lo, hi = partBounds(role)
		minimum, maximum = union(minimum, lo, math.min), union(maximum, hi, math.max)
	else
		local island = workspace:FindFirstChild("DevelopmentIsland")
		if island then
			local lo, hi = partBounds(island)
			minimum, maximum = union(preview.min, lo, math.min), union(preview.max, hi, math.max)
		end
	end
	if minimum == nil and focus then
		minimum = { x = focus.x - 96, y = focus.y - 16, z = focus.z - 96 }
		maximum = { x = focus.x + 96, y = focus.y + 16, z = focus.z + 96 }
	end
	return minimum, maximum
end

--- Photo-control layout in GUI pixels. Every control is at least CONTROL_MIN square; on touch
--- the panel sits above the TOUCH_RESERVE band so the thumbstick and jump stay clear.
function M.controlsLayout(viewport: { X: number, Y: number }, touch: boolean): any
	local width = math.max(math.min(520, viewport.X - 24), 2 * M.CONTROL_MIN + 18)
	local columns = if (width - 18) / 3 >= 88 then 3 else 2
	return {
		width = width,
		bottom = if touch then M.TOUCH_RESERVE else 16,
		columns = columns,
		cellHeight = M.CONTROL_MIN,
		gap = 6,
		padding = 6,
		textSize = 14,
	}
end

function M.new(ctx: any): any
	local Aerial = ctx.aerial
	ctx.controls.Visible = false
	local active: any = nil
	local camera: any = nil
	local saved: any = nil
	local connections = {}
	local api = {}
	function api.close()
		if active then
			active.close()
			active = nil
		end
	end
	function api.toggle()
		if active then
			api.close()
			return
		end
		camera = ctx.workspace.CurrentCamera
		local minimum, maximum = ctx.bounds()
		if minimum == nil or maximum == nil then
			return
		end
		local aspect = camera.ViewportSize.X / camera.ViewportSize.Y
		active = Aerial.start({
			read = function()
				local visibility = {}
				for _, gui in ctx.guis do
					visibility[gui] = gui.Enabled
					if gui.Name == "ForgeSurvivalHUD" or gui.Name == "ForgePanelDock" then
						gui.Enabled = false
					end
				end
				saved = {
					CameraType = camera.CameraType,
					CameraSubject = camera.CameraSubject,
					CFrame = camera.CFrame,
					Focus = camera.Focus,
					FieldOfView = camera.FieldOfView,
					visibility = visibility,
					controlsVisible = ctx.controls.Visible,
				}
				ctx.quarterView.suspend(true)
				ctx.controls.Visible = true
				-- Biome haze is tuned for the ~60-stud play camera; across the aerial distance (hundreds
				-- of studs on archipelago islands) it paints a flat fog sheet over the island. Thin it
				-- locally while the overview owns the camera.
				local atmosphere = if ctx.atmosphere then ctx.atmosphere() else nil
				if atmosphere then
					saved.atmosphere = { atmosphere, atmosphere.Density, atmosphere.Haze }
					atmosphere.Density, atmosphere.Haze = math.min(atmosphere.Density, M.AERIAL_DENSITY), 0
				end
				return saved
			end,
			apply = function(frame)
				camera.CameraType = ctx.scriptable
				camera.CFrame = ctx.qaCamera and ctx.qaCamera() or ctx.lookAt(frame.position, frame.focus)
				camera.Focus = ctx.focusAt(frame.focus)
				camera.FieldOfView = frame.fieldOfView
			end,
			hideUI = function(hidden)
				for gui, enabled in saved.visibility do
					gui.Enabled = not hidden
						and enabled
						and gui.Name ~= "ForgeSurvivalHUD"
						and gui.Name ~= "ForgePanelDock"
				end
			end,
			captureLocal = ctx.captureLocal,
			restore = function(value)
				camera.CameraType = value.CameraType
				camera.CameraSubject = value.CameraSubject
				camera.CFrame = value.CFrame
				camera.Focus = value.Focus
				camera.FieldOfView = value.FieldOfView
				for gui, enabled in value.visibility do
					gui.Enabled = enabled
				end
				ctx.controls.Visible = value.controlsVisible
				if value.atmosphere then
					value.atmosphere[1].Density, value.atmosphere[1].Haze = value.atmosphere[2], value.atmosphere[3]
				end
				ctx.quarterView.suspend(false)
			end,
		}, minimum, maximum, aspect, M.fieldOfView(minimum, maximum, aspect, camera.FieldOfView))
	end
	for name, callback in
		{
			Return = api.close,
			Toggle = api.toggle,
			OrbitLeft = function()
				if active then
					active.orbit(-math.pi / 8)
				end
			end,
			OrbitRight = function()
				if active then
					active.orbit(math.pi / 8)
				end
			end,
			HideUI = function()
				if active then
					active.hideUI(true)
				end
			end,
			ShowUI = function()
				if active then
					active.hideUI(false)
				end
			end,
			Capture = function()
				if active then
					ctx.captureResult(active.capture())
				end
			end,
		}
	do
		table.insert(connections, ctx.buttons[name].Activated:Connect(callback))
	end
	function api.zoom(distance: number)
		if active then
			active.zoom(distance)
		end
	end
	function api.destroy()
		api.close()
		for _, connection in connections do
			connection:Disconnect()
		end
	end
	return api
end

return M
