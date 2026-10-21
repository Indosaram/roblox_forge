--!strict
local Panels = require("./ExtensionPanels")
local Model = require("./SurvivalHUDModel")
local fs = require("@lune/fs")

local function signal(): any
	local callbacks: { () -> () } = {}
	return {
		Connect = function(_self, callback)
			table.insert(callbacks, callback)
			return { Disconnect = function() end }
		end,
		fire = function()
			for _, callback in callbacks do
				callback()
			end
		end,
	}
end

local function overlaps(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

return {
	["sheet close and build action surfaces stay separate at all target sizes"] = function()
		for _, size in { { 360, 640 }, { 640, 360 }, { 1280, 720 }, { 1920, 1080 } } do
			local width, height = size[1], size[2] - 56
			local w, h, top, right = Model.contextSheetBounds(width, height, width < 700)
			local close = { x = width - right - 50, y = top, width = 44, height = 44 }
			local bar = { x = (width - 328) / 2, y = height - 72, width = 328, height = 48 }
			local toast = { x = 12, y = height - 184, width = width - 24, height = 52 }
			assert(w <= 720 and h >= 44 and top >= 0, "sheet bounded and header visible")
			assert(close.x >= 0 and close.x + close.width <= width, "44 pixel close within viewport")
			assert(not overlaps(close, bar) and not overlaps(close, toast), "close clears actions and toast")
			assert(not overlaps(bar, toast), "shortage toast clears bottom actions")
		end
	end,
	["every registered menu activation opens exactly its sheet at phone and desktop sizes"] = function()
		local registered = {}
		local sources = { "games/robango-island/src/client/RobangoIslandClient.client.luau" }
		for _, name in
			{
				"ContractsPanel",
				"TamingPanel",
				"CampPanel",
				"ShopPanel",
				"CrossServerMarketPanel",
				"DeathZonePanel",
				"BrawlPanel",
				"ScoreEditorPanel",
			}
		do
			table.insert(sources, "genres/survival-coop/module/" .. name .. ".luau")
		end
		for _, path in sources do
			for id in fs.readFile(path):gmatch('id = "([%w%-]+)",%s*label =') do
				registered[id] = true
			end
		end
		-- Clan.mount shares a dynamic ID with Outpost.factory.
		registered.clan, registered.outpost = true, true
		for _, viewport in { { 360, 640 }, { 1920, 1080 } } do
			local buttons, visibility, entries = {}, {}, {}
			local launchers = {}
			local function node(): any
				return {
					AbsoluteSize = { X = viewport[1], Y = viewport[2] },
					AbsoluteContentSize = { X = 0, Y = 0 },
					GetPropertyChangedSignal = signal,
					Destroy = function() end,
				}
			end
			local player: any =
				{ WaitForChild = node, PlayerGui = {
					FindFirstChild = function()
						return nil
					end,
				} }
			local storage = {
				WaitForChild = function(_self, name)
					return if name == "ForgeState" then { OnClientEvent = signal() } else {}
				end,
			}
			local services = {
				ReplicatedStorage = storage,
				HttpService = {},
				Players = { LocalPlayer = player },
				UserInputService = { TouchEnabled = false },
				RunService = { Heartbeat = signal() },
				ProximityPromptService = { PromptTriggered = signal() },
			}
			local enum = setmetatable({}, {
				__index = function()
					return {}
				end,
			})
			local dimension = {
				new = function(...)
					return { ... }
				end,
				fromOffset = function(...)
					return { ... }
				end,
				fromScale = function(...)
					return { ... }
				end,
			}
			local chunk = assert(loadstring(fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")))
			local environment: any = table.clone(getfenv())
			environment.game = {
				GetService = function(_self, name)
					return services[name]
				end,
			}
			environment.Instance, environment.Enum = { new = node }, enum
			environment.UDim, environment.UDim2, environment.Vector2 = dimension, dimension, dimension
			environment.require = function(path): any
				if path == "../../../core/ui-kit/Layout" then
					return require("../../../core/ui-kit/Layout")
				elseif path == "./SurvivalHUDModel" then
					return Model
				end
				return { factory = function() end }
			end
			setfenv(chunk, environment)
			local runtime = chunk()
			local factories = {}
			for id in registered do
				if table.find({ "bag", "craft", "build", "skills", "explore" }, id) then
					visibility[id] = false
					table.insert(launchers, {
						id = id,
						label = id,
						open = function()
							for other in visibility do
								visibility[other] = other == id
							end
						end,
					})
					continue
				end
				table.insert(factories, function(ctx)
					visibility[id] = false
					local entry = {
						id = id,
						label = id,
						order = 1,
						setOpen = function(open)
							visibility[id] = open
						end,
						isOpen = function()
							return visibility[id]
						end,
					}
					entries[id] = entry
					ctx.dock(entry)
					return { destroy = function() end }
				end)
			end
			local started = runtime.start({
				locale = "ko-kr",
				factories = factories,
				launchers = launchers,
				onOpen = function()
					for _, launcher in launchers do
						visibility[launcher.id] = false
					end
				end,
				ui = {
					theme = {
						default = {},
						merge = function()
							return {}
						end,
					},
					components = {
						button = function(_theme, props)
							local button = node()
							buttons[props.text] = props.onClick
							return button
						end,
					},
				},
			})
			for id in registered do
				buttons[id]()
				buttons[id]()
				for other, visible in visibility do
					assert(visible == (other == id), "only activated panel visible: " .. id .. " / " .. other)
				end
			end
			-- Finish on a docked panel, since HUD-owned sheets close through hud.close.
			buttons.contracts()
			started.closeAll()
			for _, visible in visibility do
				assert(not visible, "close all")
			end
			started.destroy()
		end
	end,
	["context menu tiles and HUD clear topbar and mobile control zones at target viewports"] = function()
		for _, size in { { 360, 640 }, { 640, 360 }, { 1280, 720 }, { 1920, 1080 } } do
			-- ScreenGui consumes the topbar inset; model coordinates are in the remaining safe area.
			local width, height = size[1], size[2] - 56
			local menuWidth, columns, tileHeight, top = Panels.menuBounds(width, height)
			local menu = {
				x = (width - menuWidth) / 2,
				y = top,
				width = menuWidth,
				height = math.ceil(19 / columns) * (tileHeight + 6) - 6,
			}
			local stick = { x = 0, y = height - 128, width = 128, height = 128 }
			local jump = { x = width - 128, y = height - 128, width = 128, height = 128 }
			assert(menuWidth <= 720 and menu.x >= 0 and menu.y >= 0, "centered menu respects safe area")
			assert(menu.y + menu.height <= height - 128, "all tiles fit above movement controls without scrolling")
			assert(not overlaps(menu, stick) and not overlaps(menu, jump), "menu clears movement zones")
			local hud = Model.contextHudBounds(width, height)
			assert(
				not overlaps(hud.vitals, hud.objective) and not overlaps(hud.vitals, hud.menu),
				"HUD cards remain separate"
			)
			for _, rect in hud do
				assert(rect.y >= 0 and rect.x >= 0 and rect.x + rect.width <= width, "HUD within topbar safe area")
				assert(not overlaps(rect, stick) and not overlaps(rect, jump), "HUD clears joystick and jump")
			end
			-- Opening any sheet/photo mode hides vitals/objective; they are mutually exclusive surfaces.
			assert(hud.photo.y + hud.photo.height <= height - 128, "photo controls fit above movement zones")
		end
	end,
}
