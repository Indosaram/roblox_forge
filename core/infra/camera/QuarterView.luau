--!strict
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")

export type Config = {
	yaw: number?,
	pitch: number?,
	fieldOfView: number?,
	distance: number?,
	minDistance: number?,
	maxDistance: number?,
	focusHeight: number?,
	occluderTag: string?,
	roofTag: string?,
	zoom: Zoom?,
	touchRotate: boolean?,
	-- Pitch and focus height at minDistance; both ease linearly to `pitch` / `focusHeight` at
	-- maxDistance, so a close zoom looks over the shoulder instead of down on the head.
	closePitch: number?,
	closeFocusHeight: number?,
	-- Opt-in raw-touch pinch: two world touches (InputBegan/Changed/Ended, the events tap-to-move
	-- already relies on) zoom by their spread. A touch starting where this returns true (UI) never
	-- joins a pinch. Phones deliver world touches with gameProcessed=true, so it is not consulted.
	pinchBlocked: ((x: number, y: number) -> boolean)?,
}
-- `characterDepth` (studs, optional): the character's front-to-back extent. A steep pitch shows
-- the top of the body too, so the on-screen height is h*cos(pitch) + depth*sin(pitch).
export type Zoom = {
	characterHeight: number,
	characterDepth: number?,
	share: number,
	minShare: number,
	maxShare: number,
}

local M = {}
-- On-screen character extent / short screen axis; self-inverse (share <-> distance).
function M.screenShare(d: number, h: number, pitch: number, fov: number, aspect: number?, depth: number?): number
	local p = math.rad(pitch)
	return (h * math.cos(p) + (depth or 0) * math.sin(p))
		/ (2 * d * math.tan(math.rad(fov) / 2) * math.min(aspect or 1, 1))
end
M.distanceForShare = M.screenShare
function M.start(config: Config?)
	assert(RunService:IsClient(), "QuarterView requires a client")
	local options: Config = config or {}
	local yaw, pitch = options.yaw or 45, options.pitch or 55
	local fov = options.fieldOfView or 30
	local minimum, maximum = options.minDistance or 60, options.maxDistance or 110
	local height = options.focusHeight or 2.5
	local function finite(value: number): boolean
		return value == value and math.abs(value) < math.huge
	end
	assert(finite(minimum) and finite(maximum) and minimum > 0 and maximum >= minimum, "invalid zoom bounds")
	assert(finite(yaw) and finite(pitch) and pitch > 0 and pitch < 90, "invalid camera angles")
	assert(finite(fov) and fov >= 1 and fov <= 120 and finite(height), "invalid camera projection")
	local distance = options.distance or 85
	assert(finite(distance), "invalid camera distance")
	distance = math.clamp(distance, minimum, maximum)
	local zoom = options.zoom
	local closePitch, closeHeight = options.closePitch, options.closeFocusHeight or height
	assert(
		closePitch == nil or (finite(closePitch) and closePitch > 0 and closePitch < 90 and not zoom),
		"invalid close pitch"
	)
	assert(finite(closeHeight), "invalid close focus height")
	local pinchBlocked = options.pinchBlocked
	local share = 0
	if zoom then
		local h, lo, hi = zoom.characterHeight, zoom.minShare, zoom.maxShare
		local depth = zoom.characterDepth or 0
		assert(finite(h) and h > 0 and lo > 0 and finite(hi) and hi >= lo and finite(zoom.share), "invalid zoom")
		assert(finite(depth) and depth >= 0, "invalid zoom depth")
		share = math.clamp(zoom.share, zoom.minShare, zoom.maxShare)
	end
	local function aspectOf(current: Camera): number
		local size = current.ViewportSize
		return if size and size.Y > 0 then size.X / size.Y else 1
	end
	local player = Players.LocalPlayer
	local connections: { RBXScriptConnection } = {}
	local faded: { [BasePart]: number } = {}
	local camera: Camera? = nil
	local saved: { cameraType: Enum.CameraType, subject: (BasePart | Humanoid)?, cf: CFrame, focus: CFrame, fov: number }? =
		nil
	local stopped = false
	local suspended = false
	local pinchDistance: number? = nil
	local rotateOrigin: number? = nil
	-- Raw pinch: world touches by InputObject, and the spread/zoom when the second finger landed.
	local touches: { [any]: { x: number, y: number } } = {}
	local pinchBase: { gap: number, value: number }? = nil
	local function gapOf(): number?
		local a = next(touches)
		local b = a ~= nil and next(touches, a) or nil
		if a == nil or b == nil or next(touches, b) ~= nil then
			return nil
		end
		local p, q = touches[a], touches[b]
		local gap = math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2)
		return if gap > 0 then gap else nil
	end
	local function rebase()
		local gap = gapOf()
		pinchBase = if gap then { gap = gap, value = if zoom then share else distance } else nil
	end
	local function forgetTouches()
		table.clear(touches)
		pinchBase = nil
	end
	-- Pitch and focus height for the current arm length (closePitch eases in toward minDistance).
	local function framing(): (number, number)
		if closePitch == nil then
			return pitch, height
		end
		local t = if maximum > minimum then math.clamp((distance - minimum) / (maximum - minimum), 0, 1) else 1
		return closePitch + (pitch - closePitch) * t, closeHeight + (height - closeHeight) * t
	end
	local function clear()
		for part, original in faded do
			part.LocalTransparencyModifier = original
		end
		table.clear(faded)
	end
	local function releaseCamera()
		local current, original = camera, saved
		if current and original then
			current.CameraType, current.CameraSubject = original.cameraType, original.subject
			current.CFrame, current.Focus, current.FieldOfView = original.cf, original.focus, original.fov
		end
		camera, saved = nil, nil
	end
	local function tagged(part: Instance): boolean
		local ancestor: Instance? = part
		while ancestor and ancestor ~= Workspace do
			if
				CollectionService:HasTag(ancestor, options.occluderTag or "ForgeCameraOccluder")
				or CollectionService:HasTag(ancestor, options.roofTag or "ForgeCameraRoof")
			then
				return true
			end
			ancestor = ancestor.Parent
		end
		return false
	end
	local function render()
		if stopped or suspended then
			return
		end
		local current = Workspace.CurrentCamera
		if current ~= camera then
			clear()
			releaseCamera()
			camera = current
			if current then
				saved = {
					cameraType = current.CameraType,
					subject = current.CameraSubject,
					cf = current.CFrame,
					focus = current.Focus,
					fov = current.FieldOfView,
				}
			end
		end
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if not current or not character or not root or not root:IsA("BasePart") then
			clear()
			return
		end
		if zoom then
			distance =
				M.distanceForShare(share, zoom.characterHeight, pitch, fov, aspectOf(current), zoom.characterDepth)
		end
		local viewPitch, focusHeight = framing()
		local focus = root.Position + Vector3.new(0, focusHeight, 0)
		local y, p = math.rad(yaw), math.rad(viewPitch)
		local offset = Vector3.new(math.sin(y) * math.cos(p), math.sin(p), math.cos(y) * math.cos(p)) * distance
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character }
		-- Never ignore faded geometry for collision or interaction raycasts.
		params.RespectCanCollide = true
		local hit = Workspace:Spherecast(focus, 0.75, offset, params)
		if hit and (not hit.Instance or not tagged(hit.Instance)) then
			offset = offset.Unit * math.max(0.05, hit.Distance - 0.25)
		end
		current.CameraType = Enum.CameraType.Scriptable
		current.FieldOfView = fov
		current.CFrame, current.Focus = CFrame.lookAt(focus + offset, focus), CFrame.new(focus)
		local visible: { [BasePart]: boolean } = {}
		for _, part in current:GetPartsObscuringTarget({ root.Position, focus }, { character }) do
			if part:IsA("BasePart") and not part:IsDescendantOf(character) and tagged(part) then
				visible[part] = true
				if faded[part] == nil then
					faded[part] = part.LocalTransparencyModifier
				end
				part.LocalTransparencyModifier = math.max(faded[part], 0.7)
			end
		end
		for part, original in faded do
			if not visible[part] then
				part.LocalTransparencyModifier = original
				faded[part] = nil
			end
		end
	end
	table.insert(connections, RunService.RenderStepped:Connect(render))
	table.insert(
		connections,
		player.CharacterRemoving:Connect(function()
			clear()
			pinchDistance = nil
			rotateOrigin = nil
			forgetTouches()
		end)
	)
	table.insert(
		connections,
		player.CharacterAdded:Connect(function()
			clear()
			pinchDistance = nil
			rotateOrigin = nil
			forgetTouches()
		end)
	)
	table.insert(
		connections,
		UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
			if pinchBlocked and input.UserInputType == Enum.UserInputType.Touch then
				local tracked = touches[input]
				if tracked then
					tracked.x, tracked.y = input.Position.X, input.Position.Y
					local base, gap = pinchBase, gapOf()
					if base and gap and not suspended then
						if zoom then
							share = math.clamp(base.value * gap / base.gap, zoom.minShare, zoom.maxShare)
						else
							distance = math.clamp(base.value * base.gap / gap, minimum, maximum)
						end
					end
				end
			elseif not processed and input.UserInputType == Enum.UserInputType.MouseWheel then
				distance = math.clamp(distance - input.Position.Z * 5, minimum, maximum)
				if zoom then
					share = math.clamp(share * 1.1 ^ input.Position.Z, zoom.minShare, zoom.maxShare)
				end
			elseif
				not processed
				and input.UserInputType == Enum.UserInputType.MouseMovement
				and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
			then
				yaw = (yaw - input.Delta.X * 0.35) % 360
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if pinchBlocked and input.UserInputType == Enum.UserInputType.Touch then
				-- A finger whose end never reached us (chat, console, menu) is no longer down.
				for other in touches do
					local state = other.UserInputState
					if state ~= Enum.UserInputState.Begin and state ~= Enum.UserInputState.Change then
						touches[other] = nil
					end
				end
				if not pinchBlocked(input.Position.X, input.Position.Y) then
					touches[input] = { x = input.Position.X, y = input.Position.Y }
				end
				rebase()
				return
			end
			if processed or UserInputService:GetFocusedTextBox() then
				return
			end
			if input.KeyCode == Enum.KeyCode.LeftBracket then
				yaw = (yaw - 45) % 360
			elseif input.KeyCode == Enum.KeyCode.RightBracket then
				yaw = (yaw + 45) % 360
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if pinchBlocked and touches[input] then
				touches[input] = nil
				rebase()
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.TouchRotate:Connect(function(positions, rotation, _velocity, state, processed)
			if options.touchRotate == false then
				rotateOrigin = nil
				return
			end
			local safe = GuiService:GetInsetArea(Enum.ScreenInsets.CoreUISafeInsets)
			for _, position in positions do
				if
					position.X < safe.Min.X
					or position.Y < safe.Min.Y
					or position.X > safe.Max.X
					or position.Y > safe.Max.Y
				then
					processed = true
				end
			end
			if processed or state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
				rotateOrigin = nil
				return
			end
			if state == Enum.UserInputState.Begin then
				rotateOrigin = yaw
			end
			if rotateOrigin and finite(rotation) then
				yaw = (rotateOrigin - math.deg(rotation)) % 360
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.TouchPinch:Connect(function(positions, scale, _velocity, state, processed)
			if pinchBlocked then
				return -- raw-touch pinch owns zoom
			end
			if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
				pinchDistance = nil
				return
			end
			local safe = GuiService:GetInsetArea(Enum.ScreenInsets.CoreUISafeInsets)
			for _, position in positions do
				if
					position.X < safe.Min.X
					or position.Y < safe.Min.Y
					or position.X > safe.Max.X
					or position.Y > safe.Max.Y
				then
					processed = true
				end
			end
			if processed then
				pinchDistance = nil
				return
			end
			if state == Enum.UserInputState.Begin then
				pinchDistance = if zoom then share else distance
			end
			if pinchDistance and finite(scale) and scale > 0 then
				if zoom then
					share = math.clamp(pinchDistance * scale, zoom.minShare, zoom.maxShare)
				else
					distance = math.clamp(pinchDistance / scale, minimum, maximum)
				end
			end
		end)
	)
	local api = {}
	function api.suspend(value: boolean)
		assert(not stopped, "camera stopped")
		suspended = value
		if value then
			clear()
		end
	end
	function api.setView(newYaw: number, newPitch: number, newDistance: number)
		assert(not stopped, "camera stopped")
		assert(
			finite(newYaw) and finite(newPitch) and newPitch > 0 and newPitch < 90 and finite(newDistance),
			"invalid view"
		)
		yaw, pitch, distance = newYaw, newPitch, math.clamp(newDistance, minimum, maximum)
		if zoom then
			local current = camera or Workspace.CurrentCamera
			local s = M.screenShare(
				newDistance,
				zoom.characterHeight,
				pitch,
				fov,
				current and aspectOf(current),
				zoom.characterDepth
			)
			share = math.clamp(s, zoom.minShare, zoom.maxShare)
		end
	end
	-- Arm length request (the same clamp as wheel and pinch); Studio QA uses it for zoom captures.
	function api.zoomTo(newDistance: number)
		assert(not stopped and finite(newDistance) and not zoom, "invalid zoom request")
		distance = math.clamp(newDistance, minimum, maximum)
	end
	function api.share(): number?
		return if zoom then share else nil
	end
	function api.stop()
		if stopped then
			return
		end
		stopped = true
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		clear()
		releaseCamera()
	end
	return api
end
return M
