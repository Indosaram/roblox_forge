--!strict
-- Client market panel: shows the lowest listings per catalog item from
-- snapshot.survivalExtensions.market and sends market-list / market-buy. The server owns every
-- eligibility, price and escrow decision; this panel only renders rows and a localized refusal.
-- Strings mirror games/robango-island/locale/strings.csv keys (market_*).
local M = {}

local LIST = "market-list"
local BUY = "market-buy"
local DEFAULT_QUANTITY = 1
local DEFAULT_PRICE = 10

local strings: { [string]: { string } } = {
	market_title = { "Market", "시장" },
	market_buy = { "Buy", "구매" },
	market_list = { "List 1", "1개 등록" },
	market_price = { "%d x%d", "%d x%d" },
	market_empty = { "No listings", "등록된 물건이 없어요" },
	market_ineligible = {
		"This account cannot trade yet",
		"이 계정은 아직 거래할 수 없어요",
	},
	market_outlier = {
		"That price is too far from the market",
		"시세와 너무 다른 가격이에요",
	},
	market_failed = {
		"Trade could not complete. Try again later",
		"거래를 완료하지 못했어요. 잠시 후 다시 시도하세요",
	},
}
local refusals: { [string]: string } = {
	INELIGIBLE_ACCOUNT_AGE = "market_ineligible",
	INELIGIBLE_PLAYTIME = "market_ineligible",
	INELIGIBLE_TUTORIAL = "market_ineligible",
	PRICE_OUTLIER = "market_outlier",
}

--- Pure text lookup (specced): `key` falls back to English; `%d` slots are filled in order.
function M.text(locale: string, key: string, first: number?, second: number?): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	local text = if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
	if first ~= nil then
		text = string.format(text, first, second or 0)
	end
	return text
end

--- Maps a server refusal reason to its localized message.
function M.refusal(locale: string, reason: string?): string
	return M.text(locale, refusals[reason or ""] or "market_failed")
end

function M.factory(ctx: any): { destroy: () -> () }?
	local ui = ctx.ui
	local theme = ui.theme.default
	local players = game:GetService("Players")
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeMarket", false, 14, false
	gui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local sheet = ui.components.modalSheet(theme, {
		name = "MarketSheet",
		title = M.text(ctx.locale, "market_title"),
		parent = gui,
	})
	local status = ui.components.label(theme, { text = "", size = UDim2.new(1, 0, 0, 28), parent = sheet.content })
	status.Name = "MarketStatus"
	local rows = Instance.new("Frame")
	rows.Name, rows.BackgroundTransparency, rows.Size, rows.Parent =
		"MarketRows", 1, UDim2.new(1, 0, 0, 0), sheet.content
	rows.AutomaticSize = Enum.AutomaticSize.Y
	local layout = Instance.new("UIListLayout")
	layout.Padding, layout.Parent = UDim.new(0, 6), rows
	local function line(order: number): Frame
		local frame = Instance.new("Frame")
		frame.Name, frame.BackgroundTransparency, frame.Size = "Row" .. order, 1, UDim2.new(1, 0, 0, 48)
		frame.LayoutOrder, frame.Parent = order, rows
		return frame
	end
	local function render(snapshot: { [string]: any })
		for _, child in rows:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		local market = snapshot.market
		if type(market) ~= "table" then
			return
		end
		local order = 0
		for _, catalog in market.catalogs do
			order += 1
			local header = line(order)
			ui.components.label(theme, { text = catalog.catalogId, size = UDim2.new(0.62, 0, 1, 0), parent = header })
			ui.components.button(theme, {
				text = M.text(ctx.locale, "market_list"),
				size = UDim2.new(0.36, 0, 1, 0),
				position = UDim2.fromScale(0.64, 0),
				parent = header,
				onClick = function()
					local result = ctx.send(LIST, { catalog.catalogId, DEFAULT_QUANTITY, DEFAULT_PRICE })
					status.Text = if result.ok then "" else M.refusal(ctx.locale, result.reason)
				end,
			})
			if #catalog.listings == 0 then
				order += 1
				ui.components.label(
					theme,
					{ text = M.text(ctx.locale, "market_empty"), size = UDim2.new(1, 0, 1, 0), parent = line(order) }
				)
			end
			for _, listing in catalog.listings do
				order += 1
				local entry = line(order)
				ui.components.label(theme, {
					text = M.text(ctx.locale, "market_price", listing.unitPrice, listing.quantity),
					size = UDim2.new(0.62, 0, 1, 0),
					parent = entry,
				})
				ui.components.button(theme, {
					text = M.text(ctx.locale, "market_buy"),
					size = UDim2.new(0.36, 0, 1, 0),
					position = UDim2.fromScale(0.64, 0),
					parent = entry,
					onClick = function()
						local result = ctx.send(BUY, { listing.id })
						status.Text = if result.ok then "" else M.refusal(ctx.locale, result.reason)
					end,
				})
			end
		end
	end
	local unsubscribe = ctx.onSnapshot(render)
	local input = game:GetService("UserInputService")
	local keyConnection = input.InputBegan:Connect(function(event, processed)
		if not processed and event.KeyCode == Enum.KeyCode.M then
			gui.Enabled = not gui.Enabled
		end
	end)
	return {
		destroy = function()
			keyConnection:Disconnect()
			unsubscribe()
			gui:Destroy()
		end,
	}
end

return M
