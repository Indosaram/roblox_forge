--!strict
local Panel = require("./CrossServerMarketPanel")
return {
	["production market controls fit phone and desktop and bind exact item and agreed price"] = function()
		for _, width in { 360, 1280 } do
			local widgets: { any } = {}
			local sends: { any } = {}
			local listener: any = nil
			local function signal(): any
				return {
					Connect = function()
						return { Disconnect = function() end }
					end,
				}
			end
			local function node(): any
				local value: any = { FocusLost = signal(), Destroy = function() end }
				function value:GetChildren(): any
					return {}
				end
				return value
			end
			local sheet = { frame = node(), scroll = node(), close = { Activated = signal() } }
			local function widget(_theme, props): any
				table.insert(widgets, props)
				return node()
			end
			local player = {
				UserId = 1,
				WaitForChild = function()
					return {}
				end,
			}
			local ctx: any = {
				locale = "en-us",
				icons = {
					item = function(id)
						return { text = id }
					end,
				},
				instance = { new = node },
				enum = { AutomaticSize = { Y = "Y" } },
				udim2 = {
					new = function(...)
						return { ... }
					end,
					fromScale = function(...)
						return { ... }
					end,
				},
				game = {
					GetService = function(_, name)
						return if name == "Players" then { LocalPlayer = player } else { PromptTriggered = signal() }
					end,
				},
				ui = {
					theme = { default = {} },
					components = {
						modalSheet = function()
							return sheet
						end,
						label = widget,
						button = widget,
					},
				},
				fitSheet = function(frame)
					frame.width = math.min(440, width - 24)
				end,
				dock = function() end,
				onSnapshot = function(callback)
					listener = callback
					return function() end
				end,
				send = function(action, args)
					table.insert(sends, { action = action, args = args })
					return { ok = true }
				end,
			}
			local panel = Panel.factory(ctx)
			local state = {
				market = {
					balance = 100,
					items = { exact = { catalogId = "wood", quantity = 2 } },
					catalogIds = { "wood" },
					listed = {},
					filter = "wood",
					listings = { { id = "seller:list", catalogId = "wood", quantity = 2, price = 21 } },
					claims = {},
					page = 1,
					pages = 0,
				},
			}
			listener(state)
			assert(sheet.frame.width <= width - 24, "fitted sheet width")
			local count = #widgets
			listener(state)
			assert(#widgets == count, "unchanged snapshots preserve input focus")
			for _, props in widgets do
				assert(props.size[4] == 48, "touch target height")
				if props.text == "Buy bundle" or props.text == "List bundle" then
					props.onClick()
				end
			end
			assert(sends[1].args[1] == "exact", "exact inventory id")
			assert(sends[2].args[1] == "seller:list" and sends[2].args[2] == 21, "agreed bundle price")
			panel.destroy()
		end
	end,
}
