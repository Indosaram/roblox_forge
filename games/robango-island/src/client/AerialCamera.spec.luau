--!strict
local Camera = require("./AerialCamera")
return {
	["aerial owns camera only until return and restores exact hidden UI state"] = function()
		local callbacks = {}
		local disconnected = 0
		local buttons = {}
		for _, name in { "Return", "Toggle", "OrbitLeft", "OrbitRight", "HideUI", "ShowUI", "Capture" } do
			buttons[name] = {
				Activated = {
					Connect = function(_self, callback)
						callbacks[name] = callback
						return {
							Disconnect = function()
								disconnected += 1
							end,
						}
					end,
				},
			}
		end
		for _, viewport in { { X = 360, Y = 780 }, { X = 1280, Y = 720 } } do
			local subject = {}
			local camera: any = {
				CameraType = "Custom",
				CameraSubject = subject,
				CFrame = "original",
				Focus = "focus",
				FieldOfView = 70,
				ViewportSize = viewport,
			}
			local visible, hidden = { Enabled = true }, { Enabled = false }
			local controls = { Visible = false }
			local suspended = false
			local captured = false
			local controller = Camera.new({
				aerial = require("../../../../genres/survival-coop/module/AerialView"),
				workspace = { CurrentCamera = camera },
				guis = { visible, hidden },
				buttons = buttons,
				controls = controls,
				quarterView = {
					suspend = function(value)
						suspended = value
					end,
				},
				bounds = function()
					return { x = -100, y = 0, z = -100 }, { x = 100, y = 20, z = 100 }
				end,
				scriptable = "Scriptable",
				lookAt = function(position, focus)
					return { position = position, focus = focus }
				end,
				focusAt = function(point)
					return point
				end,
				captureLocal = function()
					return { ok = true }
				end,
				captureResult = function(result)
					captured = result.ok
				end,
			})
			callbacks.Toggle()
			assert(suspended and controls.Visible and camera.CameraType == "Scriptable", "aerial owns camera")
			callbacks.HideUI()
			assert(not visible.Enabled and not hidden.Enabled, "hide all requested UI")
			callbacks.ShowUI()
			assert(visible.Enabled and not hidden.Enabled, "show preserves previously hidden UI")
			callbacks.OrbitLeft()
			controller.zoom(0)
			callbacks.Capture()
			assert(captured, "local capture result delivered")
			callbacks.Return()
			assert(not suspended and not controls.Visible, "quarter view resumes")
			assert(
				tostring(camera.CameraType) == "Custom"
					and camera.CameraSubject == subject
					and camera.CFrame == "original"
					and camera.Focus == "focus"
					and camera.FieldOfView == 70,
				"exact camera restored"
			)
			assert(visible.Enabled and not hidden.Enabled, "exact UI restored")
			controller.destroy()
		end
		assert(disconnected == 14, "all controls disconnected")
	end,
}
