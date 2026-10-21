--!strict
local fs = require("@lune/fs")
local Model = require("./SurvivalHUDModel")
local Locale = require("./SurvivalHUDLocale")

local function signal(): any
	local callbacks: { (...any) -> () } = {}
	return {
		Connect = function(_self, callback)
			table.insert(callbacks, callback)
			return { Disconnect = function() end }
		end,
		fire = function(_self, ...)
			for _, callback in callbacks do
				callback(...)
			end
		end,
	}
end

return {
	["contextual menu pointer reaches every tile and survives the next frame"] = function()
		for _, size in { { 1920, 1080 }, { 360, 640 } } do
			local width, height = size[1], size[2] - 56
			local nodes, attributes = {}, {}
			local dimension = {
				new = function(xs, xo, ys, yo)
					return { xs or 0, xo or 0, ys or 0, yo or 0 }
				end,
				fromOffset = function(x, y)
					return { 0, x, 0, y }
				end,
				fromScale = function(x, y)
					return { x, 0, y, 0 }
				end,
			}
			local function node(class): any
				local item: any = {
					ClassName = class,
					Visible = true,
					Enabled = true,
					Active = class == "TextButton" or class == "ScrollingFrame",
					Interactable = true,
					ZIndex = 1,
					DisplayOrder = 0,
					Position = dimension.fromOffset(0, 0),
					Size = dimension.fromOffset(100, 100),
					AnchorPoint = { X = 0, Y = 0 },
					AbsoluteSize = { X = width, Y = height },
					AbsoluteContentSize = { X = 0, Y = 0 },
					GetPropertyChangedSignal = signal,
				}
				for _, name in
					{
						"InputBegan",
						"MouseButton1Down",
						"MouseButton1Up",
						"MouseButton1Click",
						"Activated",
						"MouseEnter",
						"MouseLeave",
					}
				do
					item[name] = signal()
				end
				function item:IsA(kind)
					return self.ClassName == kind
						or (
							kind == "GuiObject"
							and table.find(
									{ "Frame", "ScrollingFrame", "TextButton", "TextLabel", "ImageLabel" },
									self.ClassName
								)
								~= nil
						)
				end
				function item:Destroy()
					self.Parent, self.Visible = nil, false
				end
				function item:FindFirstAncestorWhichIsA(kind)
					local current = self.Parent
					while current do
						if current:IsA(kind) then
							return current
						end
						current = current.Parent
					end
				end
				table.insert(nodes, item)
				return item
			end
			local playerGui = node("PlayerGui")
			function playerGui:FindFirstChild(name)
				for _, item in nodes do
					if item.Parent == self and item.Name == name then
						return item
					end
				end
			end
			local player = { PlayerGui = playerGui }
			function player:WaitForChild()
				return playerGui
			end
			function player:GetAttribute(key)
				return attributes[key]
			end
			function player:SetAttribute(key, value)
				attributes[key] = value
			end
			local heartbeat = signal()
			local services = {
				Players = { LocalPlayer = player },
				ReplicatedStorage = {
					WaitForChild = function()
						return { OnClientEvent = signal() }
					end,
				},
				HttpService = {},
				UserInputService = { TouchEnabled = width < 700 },
				RunService = { Heartbeat = heartbeat },
				ProximityPromptService = { PromptTriggered = signal() },
				TweenService = {},
			}
			local enum = setmetatable({}, {
				__index = function(_self, key: string)
					return setmetatable({}, {
						__index = function(_group, value: string)
							return key .. "." .. value
						end,
					})
				end,
			})
			local color: any = {
				r = 40,
				g = 76,
				b = 66,
				Lerp = function(self)
					return self
				end,
			}
			local environment: any = table.clone(getfenv())
			environment.game = {
				GetService = function(_self, name)
					return services[name]
				end,
			}
			environment.Instance, environment.Enum = { new = node }, enum
			environment.UDim, environment.UDim2 = dimension, dimension
			environment.Vector2 = {
				new = function(x, y)
					return { X = x, Y = y }
				end,
				zero = { X = 0, Y = 0 },
			}
			environment.Color3 = {
				new = function()
					return color
				end,
				fromRGB = function()
					return color
				end,
			}
			environment.ColorSequence = { new = function() end }
			local function load(path)
				local chunk = assert(loadstring(fs.readFile(path)))
				setfenv(chunk, environment)
				return chunk()
			end
			-- Use the shipped button signal wiring, not a direct onClick substitute.
			local components = load("core/ui-kit/Components.luau")
			environment.require = function(path): any
				if path == "./SurvivalHUDModel" then
					return Model
				elseif path == "./SurvivalHUDLocale" then
					return Locale
				elseif path == "../../../core/ui-kit/Layout" then
					return require("../../../core/ui-kit/Layout")
				end
				return { factory = function() end }
			end
			local panels = load("genres/survival-coop/module/ExtensionPanels.luau")
			local visible, launchers, factories = {}, {}, {}
			local ids = {
				"bag",
				"craft",
				"build",
				"skills",
				"contracts",
				"taming",
				"camp",
				"market",
				"shop",
				"death-zone",
				"clan",
				"outpost",
				"journal",
				"music",
				"audio",
				"explore",
			}
			for index, id in ids do
				visible[id] = false
				if table.find({ "bag", "craft", "build", "skills", "explore" }, id) then
					table.insert(launchers, {
						id = id,
						label = id,
						open = function()
							visible[id] = true
						end,
					})
				else
					table.insert(factories, function(ctx)
						ctx.dock({
							id = id,
							label = id,
							order = index,
							setOpen = function(open)
								visible[id] = open
							end,
							isOpen = function()
								return visible[id]
							end,
						})
					end)
				end
			end
			panels.start({
				contextual = true,
				locale = "ko-kr",
				launchers = launchers,
				factories = factories,
				ui = {
					components = components,
					theme = {
						default = {},
						merge = function()
							return {
								colors = { accent = color, onAccent = color, bg = color, text = color },
								font = "Gotham",
								textSizes = { body = 14 },
								corner = 8,
							}
						end,
					},
				},
			})
			local dock = assert(playerGui:FindFirstChild("ForgePanelDock"))
			local toggle, menu
			for _, item in nodes do
				if item.Name == "MenuToggle" then
					toggle = item
				end
				if item.Name == "Menu" then
					menu = item
				end
			end
			-- Other shipped HUD roots are below the dock; the equal-order photo
			-- controls are hidden on first play, and must not intercept input.
			local descriptors: { { any } } =
				{ { "ForgeSurvivalHUD", 15, true }, { "ForgeClanInput", 25, false }, { "ForgeAerial", 30, false } }
			for _, descriptor in descriptors do
				local gui = node("ScreenGui")
				gui.Name, gui.DisplayOrder, gui.Parent = descriptor[1], descriptor[2], playerGui
				local overlay = node("Frame")
				overlay.Active, overlay.Visible, overlay.Parent = true, descriptor[3], gui
				overlay.Size = dimension.fromScale(1, 1)
			end
			local function bounds(item: any): any
				if item == playerGui or item.ClassName == "ScreenGui" then
					return { x = 0, y = 0, w = width, h = height }
				end
				local parent = bounds(item.Parent)
				local s, p, a = item.Size, item.Position, item.AnchorPoint
				local w, h = s[1] * parent.w + s[2], s[3] * parent.h + s[4]
				local x, y = parent.x + p[1] * parent.w + p[2] - a.X * w, parent.y + p[3] * parent.h + p[4] - a.Y * h
				if item.Parent == menu then
					local tiles = {}
					for _, child in nodes do
						if child.Parent == menu and child.ClassName == "TextButton" then
							table.insert(tiles, child)
						end
					end
					table.sort(tiles, function(left, right)
						return left.LayoutOrder < right.LayoutOrder
					end)
					local _, columns, tileHeight = panels.menuBounds(width, height)
					local index = assert(table.find(tiles, item)) - 1
					w, h = math.floor((parent.w - (columns - 1) * 6) / columns), tileHeight
					x, y = parent.x + (index % columns) * (w + 6), parent.y + math.floor(index / columns) * (h + 6)
				end
				return { x = x, y = y, w = w, h = h }
			end
			local function contains(rect: any, x: number, y: number)
				return x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h
			end
			local function hit(x, y)
				local winner, bestOrder, bestZ = nil, -1, -1
				for _, item in nodes do
					if not item:IsA("GuiObject") or not item.Active or not item.Parent then
						continue
					end
					local current, shown, order = item, true, 0
					while current and current ~= playerGui do
						if current.Visible == false or current.Enabled == false then
							shown = false
						end
						if current.ClipsDescendants and not contains(bounds(current), x, y) then
							shown = false
						end
						if current.ClassName == "ScreenGui" then
							order = current.DisplayOrder
						end
						current = current.Parent
					end
					if current ~= playerGui then
						shown = false
					end
					if
						shown
						and contains(bounds(item), x, y)
						and (order > bestOrder or (order == bestOrder and item.ZIndex >= bestZ))
					then
						winner, bestOrder, bestZ = item, order, item.ZIndex
					end
				end
				return winner
			end
			local function click(button)
				local rect = bounds(button)
				local x, y = rect.x + rect.w / 2, rect.y + rect.h / 2
				assert(hit(x, y) == button, "pointer intercepted: " .. button.Name)
				assert(button.Interactable, "button disabled")
				button.InputBegan:fire({})
				button.MouseButton1Down:fire(x, y)
				heartbeat:fire()
				assert(hit(x, y) == button, "target changed during press")
				button.MouseButton1Up:fire(x, y)
				button.MouseButton1Click:fire()
				button.Activated:fire({}, 1)
			end
			assert(dock.DisplayOrder == 30 and not menu.Visible, "closed first-play menu")
			assert(
				toggle.Parent.AutomaticSize == enum.AutomaticSize.None and bounds(toggle.Parent).h >= 44,
				"fixed hit ancestry"
			)
			for _, id in ids do
				click(toggle)
				assert(menu.Visible, "one click opens menu")
				heartbeat:fire()
				assert(menu.Visible, "menu stays open next frame")
				local tile
				for _, item in nodes do
					if item.Name == "Dock-" .. id then
						tile = item
					end
				end
				assert(tile, "launcher exists: " .. id)
				click(tile)
				assert(not menu.Visible and visible[id], "tile opens sheet: " .. id)
				heartbeat:fire()
				assert(visible[id], "sheet stays open next frame: " .. id)
				visible[id] = false
			end
		end
	end,
}
