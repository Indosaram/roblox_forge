--!strict
local Panel = require("./CrossServerMarketPanel")
local Locale = require("./SurvivalHUDLocale")
-- Mounts the panel against recording fakes: every created node, widget props and harbor-sell result.
local function mount(harborResult: any): any
	local nodes: { any } = {}
	local widgets: { any } = {}
	local sends: { any } = {}
	local listener: any = nil
	local function signal(): any
		local value: any = {}
		function value.Connect(_, callback)
			value.callback = callback
			return { Disconnect = function() end }
		end
		return value
	end
	local function node(): any
		local value: any = { FocusLost = signal(), Destroy = function() end }
		function value:GetChildren(): any
			return {}
		end
		table.insert(nodes, value)
		return value
	end
	local sheet = { frame = node(), scroll = node(), close = { Activated = signal() } }
	local function widget(_theme, props): any
		table.insert(widgets, props)
		props.node = node()
		props.node.Text = props.text
		return props.node
	end
	local player = {
		WaitForChild = function()
			return {}
		end,
	}
	local panel = Panel.factory({
		locale = "en-us",
		icons = {
			item = function(id)
				return { text = id }
			end,
		},
		instance = { new = node },
		enum = {
			AutomaticSize = { Y = "Y" },
			ZIndexBehavior = { Sibling = "Sibling" },
			SortOrder = { LayoutOrder = "LayoutOrder" },
		},
		udim2 = {
			new = function(...)
				return { ... }
			end,
			fromScale = function(...)
				return { ... }
			end,
			fromOffset = function(...)
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
		fitSheet = function() end,
		dock = function() end,
		onSnapshot = function(callback)
			listener = callback
			return function() end
		end,
		send = function(action, args)
			table.insert(sends, { action = action, args = args })
			return if action == "survival-coop:harbor-sell" then harborResult else { ok = true }
		end,
	})
	local state = {
		market = {
			balance = 100,
			items = { exact = { catalogId = "wood", quantity = 2 } },
			catalogIds = { "wood" },
			listed = {},
			filter = "wood",
			listings = {},
			claims = {},
			page = 1,
			pages = 0,
		},
	}
	state["harbor-buyback"] = { prices = { wood = 1 }, dailyUnits = 200, remaining = 7 }
	listener(state)
	local rows: { any } = {}
	for _, value in nodes do
		if value.LayoutOrder then
			table.insert(rows, value)
		end
	end
	table.sort(rows, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	local layout = nil
	for _, value in nodes do
		layout = if value.SortOrder ~= nil then value else layout
	end
	return { panel = panel, rows = rows, widgets = widgets, sends = sends, layout = layout, status = widgets[1].node }
end
local function sellRow(rows: { any }): number
	for index, row in rows do
		if row.Text == "Sell wood (1 each)" then
			return index
		end
	end
	error("harbor sell button missing")
end
return {
	["harbor rows read in LayoutOrder sequence: label, quantity box, then Sell"] = function()
		local ui = mount({ ok = true })
		assert(ui.layout and ui.layout.SortOrder == "LayoutOrder", "list layout sorts by LayoutOrder")
		local sell = sellRow(ui.rows)
		local quantity, header = ui.rows[sell - 1], ui.rows[sell - 2]
		assert(quantity.ClearTextOnFocus == false and quantity.Text == "1", "quantity box right before Sell")
		assert(
			string.find(header.Text, "wood x2", 1, true) and string.find(header.Text, "1 each", 1, true),
			"item, held count and price label right before the quantity box: " .. tostring(header.Text)
		)
		assert(string.find(ui.rows[sell - 3].Text, "Harbor buys 7/200", 1, true), "cap line heads the harbor block")
		ui.panel.destroy()
	end,
	["harbor oversell reaches the server and its refusal shows; market draft stays separate"] = function()
		local ui = mount({ ok = false, reason = "INSUFFICIENT_ITEMS" })
		local sell = sellRow(ui.rows)
		local box = ui.rows[sell - 1]
		box.Text = "201"
		box.FocusLost.callback()
		for _, props in ui.widgets do
			if props.text == "Sell wood (1 each)" then
				props.onClick()
			end
		end
		local sent = ui.sends[#ui.sends]
		assert(sent.action == "survival-coop:harbor-sell" and sent.args[2] == 201, "typed quantity sent unclamped")
		assert(ui.status.Text == Locale.refusal("en-us", "INSUFFICIENT_ITEMS"), "refusal reason in status label")
		for _, props in ui.widgets do
			if string.sub(props.text, 1, 12) == "List bundle:" then
				props.onClick()
			end
		end
		assert(ui.sends[#ui.sends].args[2] == 1, "market listing draft untouched by harbor quantity")
		ui.panel.destroy()
	end,
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
				props.node = node()
				return props.node
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
				enum = {
					AutomaticSize = { Y = "Y" },
					ZIndexBehavior = { Sibling = "Sibling" },
					SortOrder = { LayoutOrder = "LayoutOrder" },
				},
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
					return { ok = action ~= "survival-coop:harbor-sell", reason = "DAILY_CAP" }
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
			state["harbor-buyback"] = { prices = { wood = 1, meat = 2 }, dailyUnits = 200, remaining = 7 }
			listener(state)
			assert(sheet.frame.width <= width - 24, "fitted sheet width")
			local count = #widgets
			listener(state)
			assert(#widgets == count, "unchanged snapshots preserve input focus")
			for _, props in widgets do
				assert(props.size[4] == 48, "touch target height")
				if props.text == "Buy bundle" or string.sub(props.text, 1, 12) == "List bundle:" then
					props.onClick()
				end
			end
			assert(sends[1].args[1] == "exact", "exact inventory id")
			assert(sends[2].args[1] == "seller:list" and sends[2].args[2] == 21, "agreed bundle price")
			assert(#sends == 2, "no harbor sell before its button")
			local cap, sell = false, nil
			for _, props in widgets do
				cap = cap or props.text == "Harbor buys 7/200 today"
				sell = if props.text == "Sell wood (1 each)" then props else sell
			end
			assert(cap and sell, "harbor cap and wood sell row shown")
			sell.onClick()
			local sent = sends[#sends]
			assert(
				sent.action == "survival-coop:harbor-sell" and sent.args[1] == "wood" and sent.args[2] == 1,
				"sell args"
			)
			assert(
				widgets[1].node.Text == "Daily limit reached",
				"refusal visible in the sheet: " .. tostring(widgets[1].node.Text)
			)
			panel.destroy()
		end
	end,
}
