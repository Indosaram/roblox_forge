--!strict
local Panel = require("./CrossServerMarketPanel")
local Locale = require("./SurvivalHUDLocale")
-- Mounts the panel against recording fakes: every created node, widget props and harbor-sell result.
local function mount(harborResult: any, locale: string?, listResult: any?, gate: string?, noMarket: boolean?): any
	local nodes: { any } = {}
	local promptSignal: any = nil
	local gui: any = nil
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
		local value: any = { Focused = signal(), FocusLost = signal(), Destroy = function() end }
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
		locale = locale or "en-us",
		color3 = {
			fromRGB = function(r, g, b)
				return { r = r, g = g, b = b }
			end,
		},
		icons = {
			item = function(id)
				return { text = id }
			end,
		},
		instance = {
			new = function(class: string): any
				local made = node()
				gui = if class == "ScreenGui" then made else gui
				return made
			end,
		},
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
				if name == "Players" then
					return { LocalPlayer = player }
				end
				promptSignal = promptSignal or { PromptTriggered = signal() }
				return promptSignal
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
			if action == "survival-coop:market-list" and listResult then
				return listResult
			end
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
			eligible = gate == nil,
			ineligibleReason = gate,
		},
	}
	state["harbor-buyback"] = { prices = { wood = 1 }, dailyUnits = 200, remaining = 7 }
	if noMarket then
		(state :: any).market = nil
	end
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
	return {
		panel = panel,
		rows = rows,
		widgets = widgets,
		sends = sends,
		layout = layout,
		status = widgets[1].node,
		gui = gui,
		player = player,
		prompt = promptSignal.PromptTriggered,
	}
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
	["p45 a server without a market slice says the market is unavailable, never loading (EN/KO)"] = function()
		for locale, word in { ["en-us"] = "unavailable", ["ko-kr"] = "쓸 수 없어요" } :: { [string]: string } do
			local ui = mount({ ok = true }, locale, nil, nil, true)
			assert(string.find(ui.status.Text, word, 1, true), locale .. ": " .. tostring(ui.status.Text))
			assert(not string.find(ui.status.Text, "loading", 1, true), "no loading claim")
			assert(not string.find(ui.status.Text, "불러오는 중", 1, true), "no loading claim (ko)")
			ui.panel.destroy()
		end
	end,
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
		assert(ui.status.Text == "You cannot sell more than you hold (held 2)", "refusal reason in status label")
		for _, props in ui.widgets do
			if string.sub(props.text, 1, 12) == "List bundle:" then
				props.onClick()
			end
		end
		assert(ui.sends[#ui.sends].args[2] == 1, "market listing draft untouched by harbor quantity")
		ui.panel.destroy()
	end,
	["harbor oversell refusal shows under the pressed Sell row with the held count, EN and KO"] = function()
		for locale, expected in
			{
				["en-us"] = "You cannot sell more than you hold (held 2)",
				["ko-kr"] = "보유 수량보다 많이 팔 수 없어요 (보유 2)",
			} :: { [string]: string }
		do
			local ui = mount({ ok = false, reason = "INSUFFICIENT_ITEMS" }, locale)
			local sell = nil
			for _, props in ui.widgets do
				sell = if props.text == string.format(Locale.text(locale, "sell"), "wood", 1) then props else sell
			end
			assert(sell, "sell button")
			local box = nil
			for index, row in ui.rows do
				if row == sell.node then
					box = ui.rows[index - 1]
					local below = ui.rows[index + 1]
					sell.onClick()
					assert(
						below.Name == "SellStatus" and below.Visible == true,
						locale .. ": row status right below Sell"
					)
					assert(below.Text == expected, locale .. ": oversell text: " .. tostring(below.Text))
				end
			end
			assert(box and box.ClearTextOnFocus == false, "quantity box found")
			ui.panel.destroy()
		end
		assert(
			Locale.refusal("ko-kr", "INSUFFICIENT_ITEMS") ~= Locale.refusal("ko-kr", "INGREDIENT_MISSING"),
			"INSUFFICIENT_ITEMS has its own text, not the generic supplies bucket"
		)
	end,
	["quantity box selects its whole value on focus so Backspace and typing replace it"] = function()
		local ui = mount({ ok = true })
		local sell = sellRow(ui.rows)
		local box = ui.rows[sell - 1]
		assert(box.Focused.callback, "focus handler wired")
		box.Text = "12"
		box.SelectionStart, box.CursorPosition = -1, 1
		box.Focused.callback()
		assert(box.SelectionStart == 1 and box.CursorPosition == 3, "whole text selected on focus")
		box.Text = ""
		assert(box.Text == "", "clearing does not immediately put a number back")
		box.FocusLost.callback()
		assert(box.Text == "", "an empty field remains editable after blur")
		box.Text = "3"
		box.FocusLost.callback()
		for _, props in ui.widgets do
			if props.node == ui.rows[sell] then
				props.onClick()
			end
		end
		assert(ui.sends[#ui.sends].args[2] == 3, "typing after clear replaces the quantity")
		ui.panel.destroy()
	end,
	["an NPC prompt opens dialogue only; a plain market prompt still opens the market"] = function()
		local ui = mount({ ok = true })
		local function prompt(attributes: { [string]: any }, holder: { [string]: any }?): any
			return {
				GetAttribute = function(_, key)
					return attributes[key]
				end,
				Parent = if holder
					then {
						GetAttribute = function(_, key)
							return holder[key]
						end,
					}
					else nil,
			}
		end
		local gui: any = ui.gui
		local function enabled(): any
			return gui.Enabled
		end
		gui.Enabled = false
		ui.prompt.callback(prompt({ ForgeMarket = true }, { ForgeHarborFacility = "npc.sella" }), ui.player)
		assert(enabled() == false, "npc.sella prompt must not stack the market over its dialogue")
		ui.prompt.callback(prompt({ ForgeMarket = true, ForgeDialogue = "station.market" }), ui.player)
		assert(enabled() == false, "talking market board opens dialogue first")
		ui.prompt.callback(prompt({ ForgeMarket = true }), ui.player)
		assert(enabled() == true, "a non-talking market prompt opens the market")
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
				local value: any = { Focused = signal(), FocusLost = signal(), Destroy = function() end }
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
	["p45 market list inputs are labelled, dark-themed, and a refusal names its gate under List (EN/KO)"] = function()
		for locale, expected in
			{
				["en-us"] = { "Quantity", "Whole bundle price (shellmoney)", "2 hours" },
				["ko-kr"] = { "수량", "묶음 전체 가격 (조개돈)", "2시간" },
			} :: { [string]: { string } }
		do
			local ui = mount(
				{ ok = true },
				locale,
				{ ok = false, reason = "INELIGIBLE_PLAYTIME" },
				"INELIGIBLE_PLAYTIME"
			)
			local list, listIndex = nil, nil
			for index, row in ui.rows do
				if string.find(tostring(row.Text), Locale.text(locale, "trade.bundle.list") .. ":", 1, true) then
					list, listIndex = row, index
				end
			end
			assert(list and listIndex, "list button")
			local price, priceCaption = ui.rows[listIndex - 1], ui.rows[listIndex - 2]
			local quantity, quantityCaption = ui.rows[listIndex - 3], ui.rows[listIndex - 4]
			assert(quantity.Text == "1" and price.Text == "10", "quantity and price boxes precede List")
			assert(quantityCaption.Text == expected[1] and quantityCaption.Name == "InputCaption", "quantity caption")
			assert(priceCaption.Text == expected[2] and priceCaption.Name == "InputCaption", "price caption")
			for _, box in { quantity, price } do
				assert(box.PlaceholderText ~= nil and box.BorderSizePixel == 0, "labelled placeholder, no border")
				assert(box.BackgroundColor3.r < 40 and box.TextColor3.r > 200, "dark field with light text")
			end
			local blocked = false
			for _, row in ui.rows do
				blocked = blocked or (row.Name == "ListBlocked" and string.find(row.Text, expected[3], 1, true) ~= nil)
			end
			assert(blocked, locale .. ": the eligibility gate is shown before a press")
			for _, props in ui.widgets do
				if props.node == list then
					props.onClick()
				end
			end
			local sent = ui.sends[#ui.sends]
			assert(sent.action == "survival-coop:market-list", "list command")
			assert(sent.args[1] == "exact" and sent.args[2] == 1 and sent.args[3] == 10, "panel args")
			local below = ui.rows[listIndex + 1]
			assert(below.Name == "ListStatus" and below.Visible == true, "status row right below List")
			assert(string.find(below.Text, expected[3], 1, true), locale .. ": refusal names the gate: " .. below.Text)
			assert(not string.find(below.Text, "INELIGIBLE", 1, true), "never the raw code")
			ui.panel.destroy()
		end
	end,
	["p45 every market-list refusal code has its own KO/EN line"] = function()
		for _, code in Panel.listRefusalCodes() do
			for _, locale in { "en-us", "ko-kr" } do
				local line = Panel.listRefusal(locale, code)
				assert(line ~= Panel.listRefusal(locale, "NEVER_A_CODE"), code .. " " .. locale .. " is specific")
				assert(not string.find(line, "_", 1, true) and line ~= code, code .. " is a sentence")
			end
		end
		for _, code in { "INELIGIBLE_ACCOUNT_AGE", "INELIGIBLE_PLAYTIME", "INELIGIBLE_TUTORIAL", "INVALID_ACCOUNT" } do
			assert(table.find(Panel.listRefusalCodes(), code), code .. " mapped")
		end
		assert(
			Panel.listRefusal("en-us", "TRANSPORT_FAILED: timeout") == Panel.listRefusal("en-us", "TRANSPORT_FAILED"),
			"transport prefix"
		)
		assert(
			Panel.listRefusal("ko-kr", "INELIGIBLE_PLAYTIME") ~= Panel.listRefusal("ko-kr", "INELIGIBLE_TUTORIAL"),
			"distinct gates"
		)
	end,
}
