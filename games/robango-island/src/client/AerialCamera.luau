--!strict
-- Roblox-shaped camera and controls are injected so no foreground APIs are needed.
local Aerial = require("../../../../genres/survival-coop/module/AerialView")
local M = {}

function M.new(ctx: any): any
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
		active = Aerial.start({
			read = function()
				local visibility = {}
				for _, gui in ctx.guis do
					visibility[gui] = gui.Enabled
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
				return saved
			end,
			apply = function(frame)
				camera.CameraType = ctx.scriptable
				camera.CFrame = ctx.lookAt(frame.position, frame.focus)
				camera.Focus = ctx.focusAt(frame.focus)
				camera.FieldOfView = frame.fieldOfView
			end,
			hideUI = function(hidden)
				for gui, enabled in saved.visibility do
					gui.Enabled = not hidden and enabled
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
				ctx.quarterView.suspend(false)
			end,
		}, minimum, maximum, camera.ViewportSize.X / camera.ViewportSize.Y, camera.FieldOfView)
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
