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
		for _, viewport in { { X = 360, Y = 640 }, { X = 640, Y = 360 }, { X = 1280, Y = 720 }, { X = 1920, Y = 1080 } } do
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
			local controls = { Visible = true }
			local hud = { Name = "ForgeSurvivalHUD", Enabled = true }
			local dock = { Name = "ForgePanelDock", Enabled = true }
			local suspended = false
			local captured = false
			local controller = Camera.new({
				aerial = require("../../../../genres/survival-coop/module/AerialView"),
				workspace = { CurrentCamera = camera },
				guis = { visible, hidden, hud, dock },
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
			assert(not controls.Visible, "photo controls hidden by default even if supplied visible")
			callbacks.Toggle()
			assert(not hud.Enabled and not dock.Enabled, "photo controls replace HUD rather than overlapping it")
			assert(suspended and controls.Visible and camera.CameraType == "Scriptable", "aerial owns camera")
			callbacks.HideUI()
			assert(not visible.Enabled and not hidden.Enabled, "hide all requested UI")
			callbacks.ShowUI()
			assert(visible.Enabled and not hidden.Enabled, "show preserves previously hidden UI")
			assert(not hud.Enabled and not dock.Enabled, "show keeps conflicting HUD hidden during photo mode")
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
			assert(hud.Enabled and dock.Enabled, "HUD restored on return")
			controller.destroy()
		end
		assert(disconnected == 28, "all controls disconnected")
	end,
	["a Studio QA camera pin wins over the aerial frame"] = function()
		local button = {
			Activated = {
				Connect = function(_self, callback)
					return { Disconnect = function() end, callback = callback }
				end,
			},
		}
		local toggle: any
		local buttons = setmetatable({}, {
			__index = function(_, name)
				return if name == "Toggle"
					then {
						Activated = {
							Connect = function(_self, callback)
								toggle = callback
								return { Disconnect = function() end }
							end,
						},
					}
					else button
			end,
		})
		local camera: any =
			{ CameraType = "Custom", CFrame = "original", FieldOfView = 70, ViewportSize = { X = 1920, Y = 1080 } }
		local pinned: any = "qa-pin"
		Camera.new({
			aerial = require("../../../../genres/survival-coop/module/AerialView"),
			workspace = { CurrentCamera = camera },
			guis = {},
			buttons = buttons,
			controls = { Visible = false },
			quarterView = { suspend = function() end },
			bounds = function()
				return { x = -100, y = 0, z = -100 }, { x = 100, y = 20, z = 100 }
			end,
			scriptable = "Scriptable",
			qaCamera = function()
				return pinned
			end,
			lookAt = function()
				return "aerial"
			end,
			focusAt = function(point)
				return point
			end,
		})
		toggle()
		assert(camera.CFrame == "qa-pin", "pinned CFrame kept: " .. tostring(camera.CFrame))
	end,
	["p77 the aerial overview thins the biome haze and restores it on return"] = function()
		local callbacks = {}
		local buttons = setmetatable({}, {
			__index = function(_, name)
				return {
					Activated = {
						Connect = function(_self, callback)
							callbacks[name] = callback
							return { Disconnect = function() end }
						end,
					},
				}
			end,
		})
		local atmosphere = { Density = 0.26, Haze = 1.1 }
		local camera: any =
			{ CameraType = "Custom", CFrame = "original", FieldOfView = 70, ViewportSize = { X = 1280, Y = 720 } }
		Camera.new({
			aerial = require("../../../../genres/survival-coop/module/AerialView"),
			workspace = { CurrentCamera = camera },
			guis = {},
			buttons = buttons,
			controls = { Visible = false },
			quarterView = { suspend = function() end },
			atmosphere = function()
				return atmosphere
			end,
			-- rw.a1.s1 bounds: the aerial camera sits ~1000 studs out, where density 0.26 is opaque.
			bounds = function()
				return { x = -384, y = 0, z = -320 }, { x = 384, y = 20, z = 320 }
			end,
			scriptable = "Scriptable",
			lookAt = function()
				return "aerial"
			end,
			focusAt = function(point)
				return point
			end,
		})
		callbacks.Toggle()
		assert(atmosphere.Density <= Camera.AERIAL_DENSITY and atmosphere.Haze == 0, "haze thinned in the overview")
		callbacks.Return()
		assert(atmosphere.Density == 0.26 and atmosphere.Haze == 1.1, "play haze restored")
	end,
	["p83 island view frames the Studio preview island that has no ForgeRoleWorld"] = function()
		local Engine = require("../../../../cli/forge/fixtures/production-worlds/engine")
		local Content = require("../shared/SurvivalContent")
		local Source = require("../shared/SurvivalWorldConfig")
		local IslandTerrain = require("../shared/IslandTerrain")
		local engine = Engine.new()
		engine.preview(Content, Source, nil, nil, "onboarding", true)
		local workspace = engine.game:GetService("Workspace")
		assert(workspace:FindFirstChild("ForgeRoleWorld") == nil, "preview island has no role world")
		local preview = {
			min = { x = -IslandTerrain.HALF_X, y = IslandTerrain.BOTTOM, z = -IslandTerrain.HALF_Z },
			max = { x = IslandTerrain.HALF_X, y = 12, z = IslandTerrain.HALF_Z },
		}
		local minimum, maximum = Camera.worldBounds(workspace, Content.layouts, preview, nil)
		assert(minimum and maximum, "preview bounds")
		assert(minimum.x <= -IslandTerrain.HALF_X and maximum.z >= IslandTerrain.HALF_Z, "covers the terrain")
		-- The live onboarding role keeps its catalog layout bounds.
		local role = Engine.new()
		role.role.build(Content, Source, require("../shared/WildlifePolicy"), function()
			return 0
		end, "rw.onboarding", 79)
		local lo, hi = Camera.worldBounds(role.game:GetService("Workspace"), Content.layouts, preview, nil)
		assert(lo and hi and lo.x <= -112 and hi.x >= 112 and lo.z <= -96 and hi.z >= 96, "role layout bounds")
		-- No world at all: frame the ground around the character instead of throwing.
		local empty = {
			FindFirstChild = function()
				return nil
			end,
		}
		local a, b = Camera.worldBounds(empty, Content.layouts, preview, { x = 10, y = 4, z = -3 })
		assert(a and b and a.x < 10 and b.x > 10, "character fallback")
		local client = require("@lune/fs").readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(not string.find(client, "AERIAL_WORLD_REQUIRED", 1, true), "client no longer asserts a role world")
		assert(string.find(client, "AerialCamera.worldBounds(", 1, true), "client uses worldBounds")
	end,
	["p83 the a1.s1 overview stays within draw distance at phone and desktop sizes"] = function()
		local Content = require("../shared/SurvivalContent")
		local layout: any = nil
		for _, candidate in Content.layouts do
			if candidate.id == "rw.a1.s1" then
				layout = candidate
			end
		end
		local Aerial = require("../../../../genres/survival-coop/module/AerialView")
		for _, viewport in { { X = 360, Y = 640 }, { X = 640, Y = 360 }, { X = 1280, Y = 720 } } do
			local applied: any = nil
			local toggle: any = nil
			local buttons = setmetatable({}, {
				__index = function(_, name)
					return {
						Activated = {
							Connect = function(_self, callback)
								if name == "Toggle" then
									toggle = callback
								end
								return { Disconnect = function() end }
							end,
						},
					}
				end,
			})
			-- The quarter-view lens is 30 degrees; the overview used to inherit it.
			local camera: any = { CameraType = "Custom", CFrame = "c", FieldOfView = 30, ViewportSize = viewport }
			Camera.new({
				aerial = Aerial,
				workspace = { CurrentCamera = camera },
				guis = {},
				buttons = buttons,
				controls = { Visible = false },
				quarterView = { suspend = function() end },
				-- 3072-stud relief islands: the overview frames the REGION around the player (worldBounds).
				bounds = function()
					return Camera.region(layout.bounds.min, layout.bounds.max, nil)
				end,
				scriptable = "Scriptable",
				lookAt = function(position, focus)
					applied = { position = position, focus = focus }
					return applied
				end,
				focusAt = function(point)
					return point
				end,
			})
			toggle()
			local p, f = applied.position, applied.focus
			local distance = math.sqrt((p.x - f.x) ^ 2 + (p.y - f.y) ^ 2 + (p.z - f.z) ^ 2)
			local label = viewport.X .. "x" .. viewport.Y
			assert(distance <= Camera.MAX_DISTANCE + 0.01, label .. " camera " .. distance .. " studs out")
			assert(camera.FieldOfView <= 120 and camera.FieldOfView >= 30, label .. " lens " .. camera.FieldOfView)
			-- The whole island still fits: AerialView's sphere test at the applied lens.
			local vertical = math.rad(camera.FieldOfView) / 2
			local half = math.min(vertical, math.atan(math.tan(vertical) * viewport.X / viewport.Y))
			local rlo, rhi = Camera.region(layout.bounds.min, layout.bounds.max, nil)
			local b = { min = rlo, max = rhi }
			local radius = math.sqrt((b.max.x - b.min.x) ^ 2 + (b.max.y - b.min.y) ^ 2 + (b.max.z - b.min.z) ^ 2) / 2
			assert(distance * math.sin(half) >= radius * 1.0999, label .. " island fits")
		end
	end,
	["p83 phone island-view controls are 44x44 and clear of the thumbstick and jump"] = function()
		for _, case in
			{ { { X = 360, Y = 640 }, true }, { { X = 640, Y = 360 }, true }, { { X = 1280, Y = 720 }, false } }
		do
			local viewport, touch = case[1], case[2]
			local layout = Camera.controlsLayout(viewport, touch)
			local cellWidth = layout.width / layout.columns - layout.gap
			local label = viewport.X .. "x" .. viewport.Y
			assert(
				cellWidth >= 44 and layout.cellHeight >= 44,
				label .. " cell " .. cellWidth .. "x" .. layout.cellHeight
			)
			assert(layout.width <= viewport.X, label .. " fits the width")
			-- Six visible controls (Toggle is hidden) in rows of layout.columns.
			local rows = math.ceil(6 / layout.columns)
			local height = layout.padding * 2 + rows * layout.cellHeight + (rows - 1) * 4
			local top = viewport.Y - layout.bottom - height
			assert(top >= 0, label .. " panel on screen")
			if touch then
				-- Roblox touch thumbstick and jump occupy the bottom ~120 px on phones.
				assert(layout.bottom >= 120, label .. " panel sits above the thumbstick and jump")
			end
		end
		local client = require("@lune/fs").readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(client, "AerialCamera.controlsLayout(", 1, true), "client places controls by controlsLayout")
		assert(not string.find(client, "GothamMedium, 12", 1, true), "no 12 px control labels")
	end,
}
