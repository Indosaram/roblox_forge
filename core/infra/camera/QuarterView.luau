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
}

local M = {}
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
	local player = Players.LocalPlayer
	local connections: { RBXScriptConnection } = {}
	local faded: { [BasePart]: number } = {}
	local camera: Camera? = nil
	local saved: { cameraType: Enum.CameraType, subject: (BasePart | Humanoid)?, cf: CFrame, focus: CFrame, fov: number }? =
		nil
	local stopped = false
	local pinchDistance: number? = nil
	local rotateOrigin: number? = nil
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
		if stopped then
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
		local focus = root.Position + Vector3.new(0, height, 0)
		local y, p = math.rad(yaw), math.rad(pitch)
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
		end)
	)
	table.insert(
		connections,
		player.CharacterAdded:Connect(function()
			clear()
			pinchDistance = nil
			rotateOrigin = nil
		end)
	)
	table.insert(
		connections,
		UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
			if not processed and input.UserInputType == Enum.UserInputType.MouseWheel then
				distance = math.clamp(distance - input.Position.Z * 5, minimum, maximum)
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
		UserInputService.TouchRotate:Connect(function(positions, rotation, _velocity, state, processed)
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
				pinchDistance = distance
			end
			if pinchDistance and finite(scale) and scale > 0 then
				distance = math.clamp(pinchDistance / scale, minimum, maximum)
			end
		end)
	)
	local api = {}
	function api.setView(newYaw: number, newPitch: number, newDistance: number)
		assert(not stopped, "camera stopped")
		assert(
			finite(newYaw) and finite(newPitch) and newPitch > 0 and newPitch < 90 and finite(newDistance),
			"invalid view"
		)
		yaw, pitch, distance = newYaw, newPitch, math.clamp(newDistance, minimum, maximum)
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
