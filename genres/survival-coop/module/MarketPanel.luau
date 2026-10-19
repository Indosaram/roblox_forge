--!strict
-- Client market panel. Reads snapshot.survivalExtensions.market and sends the namespaced durable
-- commands survival-coop:market-list / market-buy / market-cancel. The server owns every
-- eligibility, price, fee and escrow decision; this panel only renders rows, keeps a local list
-- draft (quantity and unit price) and shows a localized result. Item names come from
-- `ctx.names` (pack display names by content id) with the raw id as the fallback.
-- Strings mirror games/robango-island/locale/strings.csv keys (market_*).
local M = {}

-- Roblox globals are read from the environment so this module also type-checks under lune.
local env: any = getfenv()
local game: any = env.game
local Instance: any = env.Instance
local Enum: any = env.Enum
local UDim: any = env.UDim
local UDim2: any = env.UDim2

M.LIST = "survival-coop:market-list"
M.BUY = "survival-coop:market-buy"
M.CANCEL = "survival-coop:market-cancel"
M.ACTIONS = table.freeze({ M.LIST, M.BUY, M.CANCEL })
local DEFAULT_PRICE = 10
local MAX_PRICE = 2 ^ 31

M.STRINGS = table.freeze({
	market_title = { "Market", "시장" },
	market_buy = { "Buy", "구매" },
	market_list = { "List", "등록" },
	market_cancel = { "Cancel", "취소" },
	market_price = { "%d each x%d", "개당 %d x%d" },
	market_empty = { "No listings", "등록된 물건이 없어요" },
	market_sell = { "Sell from your bag", "가방에서 팔기" },
	market_browse = { "Listings", "판매 목록" },
	market_mine = { "Your listings", "내 판매 목록" },
	market_nothing = {
		"Nothing to sell yet. Gather raw goods first",
		"아직 팔 물건이 없어요. 먼저 재료를 모아 오세요",
	},
	market_have = { "%s (have %d)", "%s (보유 %d)" },
	market_draft = { "x%d at %d each, fee %d", "%d개, 개당 %d, 수수료 %d" },
	market_balance = { "Shellmoney %d", "조개돈 %d" },
	market_listed = { "Listed %s", "%s 등록했어요" },
	market_bought = { "Bought %s", "%s 샀어요" },
	market_cancelled = { "%s returned to your bag", "%s 가방으로 돌아왔어요" },
	market_ineligible = {
		"This account cannot trade yet",
		"이 계정은 아직 거래할 수 없어요",
	},
	market_outlier = {
		"That price is too far from the market",
		"시세와 너무 다른 가격이에요",
	},
	market_funds = { "Not enough Shellmoney", "조개돈이 부족해요" },
	market_bag_full = { "Your bag is full", "가방이 가득 찼어요" },
	market_gone = { "That listing is no longer available", "이미 팔렸거나 내려간 물건이에요" },
	market_not_owned = { "You do not have that many", "그만큼 갖고 있지 않아요" },
	market_gate_tutorial = {
		"Finish the tutorial to start trading",
		"첫 안내를 끝내야 시장 거래가 열려요",
	},
	market_gate_age = {
		"Your account is too new to trade yet",
		"계정이 너무 새로워서 아직 거래할 수 없어요",
	},
	market_gate_playtime = {
		"Play a little longer to unlock trading",
		"조금 더 플레이하면 거래할 수 있어요",
	},
	market_gate_cap = {
		"Daily trade limit reached. Come back tomorrow",
		"오늘 거래 한도를 다 썼어요. 내일 다시 오세요",
	},
	market_failed = {
		"Trade could not complete. Try again later",
		"거래를 완료하지 못했어요. 잠시 후 다시 시도하세요",
	},
})
local refusals: { [string]: string } = {
	INELIGIBLE_ACCOUNT_AGE = "market_ineligible",
	INELIGIBLE_PLAYTIME = "market_ineligible",
	INELIGIBLE_TUTORIAL = "market_ineligible",
	PRICE_OUTLIER = "market_outlier",
	INSUFFICIENT_FUNDS = "market_funds",
	INSUFFICIENT_FEE = "market_funds",
	BAG_FULL = "market_bag_full",
	LISTING_UNAVAILABLE = "market_gone",
	NOT_OWNED = "market_not_owned",
}

local gates: { [string]: string } = {
	INELIGIBLE_TUTORIAL = "market_gate_tutorial",
	INELIGIBLE_ACCOUNT_AGE = "market_gate_age",
	INELIGIBLE_PLAYTIME = "market_gate_playtime",
	DAILY_TRADE_CAP = "market_gate_cap",
}

--- Pure text lookup (specced): `key` falls back to English; `%` slots are filled in order.
function M.text(locale: string, key: string, ...: any): string
	local entry = M.STRINGS[key]
	if entry == nil then
		return key
	end
	local text = if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
	if select("#", ...) > 0 then
		text = string.format(text, ...)
	end
	return text
end

--- Maps a server refusal reason to its localized message.
function M.refusal(locale: string, reason: string?): string
	return M.text(locale, refusals[reason or ""] or "market_failed")
end

--- Display name of a content id: the pack name when known, else the raw id.
function M.name(names: { [string]: string }?, id: string): string
	return names and names[id] or id
end

--- Listing fee the server will charge (mirrors core Market.fee; display only).
function M.fee(market: any, quantity: number, unitPrice: number): number
	local bp = if type(market.feeBasisPoints) == "number" then market.feeBasisPoints else 0
	local minimum = if type(market.minFee) == "number" then market.minFee else 0
	return math.max(minimum, (quantity * unitPrice * bp) // 10000)
end

export type Draft = { quantity: number, price: number }
export type Model = {
	balance: number?,
	-- Server-published gate: false disables List/Buy; `gate` is the localized key to show.
	eligible: boolean,
	gate: string?,
	sell: { { catalogId: string, name: string, held: number, draft: Draft, fee: number } },
	mine: { { id: string, catalogId: string, name: string, quantity: number, unitPrice: number } },
	browse: {
		{
			catalogId: string,
			name: string,
			listings: { { id: string, quantity: number, unitPrice: number } },
		}
	},
}

--- Pure view model (specced). Sell rows: only goods the player actually holds, each with a
--- clamped draft. Browse: other sellers' listings, catalogs without any listing omitted.
function M.model(market: any, names: { [string]: string }?, drafts: { [string]: Draft }, self: string?): Model
	-- Only an explicit server `eligible = false` closes trading; the reason comes from the server.
	local eligible = market.eligible ~= false
	local model: Model = {
		balance = market.balance,
		eligible = eligible,
		gate = if eligible then nil else (gates[market.ineligibleReason or ""] or "market_ineligible"),
		sell = {},
		mine = {},
		browse = {},
	}
	local lowest: { [string]: number } = {}
	for _, catalog in market.catalogs or {} do
		local rows = {}
		for _, listing in catalog.listings or {} do
			if lowest[catalog.catalogId] == nil then
				lowest[catalog.catalogId] = listing.unitPrice
			end
			if listing.seller ~= self then
				table.insert(rows, { id = listing.id, quantity = listing.quantity, unitPrice = listing.unitPrice })
			end
		end
		if #rows > 0 then
			table.insert(
				model.browse,
				{ catalogId = catalog.catalogId, name = M.name(names, catalog.catalogId), listings = rows }
			)
		end
	end
	for _, catalog in market.catalogs or {} do
		local id = catalog.catalogId
		local held = (market.holdings or {})[id]
		if type(held) == "number" and held > 0 then
			local draft = drafts[id] or { quantity = 1, price = lowest[id] or DEFAULT_PRICE }
			draft = {
				quantity = math.clamp(draft.quantity, 1, math.min(held, 1000)),
				price = math.clamp(draft.price, 1, MAX_PRICE),
			}
			drafts[id] = draft
			table.insert(model.sell, {
				catalogId = id,
				name = M.name(names, id),
				held = held,
				draft = draft,
				fee = M.fee(market, draft.quantity, draft.price),
			})
		end
	end
	local own = {}
	for id, listing in market.listed or {} do
		if listing.status == "active" then
			table.insert(own, {
				id = id,
				catalogId = listing.catalogId,
				name = M.name(names, listing.catalogId),
				quantity = listing.quantity,
				unitPrice = listing.unitPrice,
			})
		end
	end
	table.sort(own, function(a, b)
		return a.id < b.id
	end)
	model.mine = own
	return model
end

--- Next draft after a stepper press (pure). Price steps grow with the price (1, 10, 100...).
function M.step(draft: Draft, field: string, direction: number, held: number): Draft
	local nextDraft = table.clone(draft)
	if field == "quantity" then
		nextDraft.quantity = math.clamp(draft.quantity + direction, 1, math.max(1, math.min(held, 1000)))
	else
		local unit = 10 ^ math.max(0, math.floor(math.log10(math.max(1, draft.price))) - 1)
		if direction < 0 and draft.price - unit < 1 then
			unit = 1
		end
		nextDraft.price = math.clamp(draft.price + direction * unit, 1, MAX_PRICE)
	end
	return nextDraft
end

function M.factory(ctx: any): { destroy: () -> () }?
	local ui = ctx.ui
	local theme = ui.theme.default
	local names: { [string]: string }? = ctx.names
	local players = game:GetService("Players")
	local self = tostring(players.LocalPlayer.UserId)
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeMarket", false, 14, false
	gui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local sheet = ui.components.modalSheet(theme, {
		name = "MarketSheet",
		title = M.text(ctx.locale, "market_title"),
		parent = gui,
	})
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sheet.frame.Visible = true
	if ctx.fitSheet then
		ctx.fitSheet(sheet.frame)
	end
	sheet.close.Activated:Connect(function()
		gui.Enabled = false
	end)
	if ctx.dock then
		ctx.dock({
			id = "market",
			label = M.text(ctx.locale, "market_title"),
			order = 5,
			setOpen = function(open: boolean)
				gui.Enabled = open
			end,
			isOpen = function()
				return gui.Enabled
			end,
		})
	end
	local status = ui.components.label(theme, { text = "", size = UDim2.new(1, 0, 0, 28), parent = sheet.scroll })
	status.Name = "MarketStatus"
	status.TextWrapped = true
	local rows = Instance.new("Frame")
	rows.Name, rows.BackgroundTransparency, rows.Size, rows.Parent =
		"MarketRows", 1, UDim2.fromScale(1, 0), sheet.scroll
	rows.AutomaticSize = Enum.AutomaticSize.Y
	local layout = Instance.new("UIListLayout")
	layout.Padding, layout.SortOrder, layout.Parent = UDim.new(0, 6), Enum.SortOrder.LayoutOrder, rows
	local drafts: { [string]: Draft } = {}
	local latest: { [string]: any } = {}
	local order = 0
	local function line(): any
		order += 1
		local frame = Instance.new("Frame")
		frame.Name, frame.BackgroundTransparency, frame.Size = "Row" .. order, 1, UDim2.new(1, 0, 0, 48)
		frame.LayoutOrder, frame.Parent = order, rows
		return frame
	end
	local function label(text: string, width: number, parent: any)
		local item = ui.components.label(theme, { text = text, size = UDim2.fromScale(width, 1), parent = parent })
		item.TextWrapped = true
		return item
	end
	local function button(text: string, x: number, width: number, parent: any, onClick: () -> (), enabled: boolean?)
		local open = enabled ~= false
		local item = ui.components.button(theme, {
			text = text,
			size = UDim2.new(width, -4, 1, 0),
			position = UDim2.fromScale(x, 0),
			parent = parent,
			onClick = function()
				if open then
					onClick()
				end
			end,
		})
		if not open then
			item.Active, item.AutoButtonColor = false, false
			item.BackgroundTransparency, item.TextTransparency = 0.6, 0.5
		end
		return item
	end
	local render: (snapshot: { [string]: any }) -> ()
	local function send(action: string, args: { any }, done: (data: any) -> string)
		local result = ctx.send(action, args)
		status.Text = if result.ok then done(result.data or {}) else M.refusal(ctx.locale, result.reason)
	end
	render = function(snapshot: { [string]: any })
		latest = snapshot
		for _, child in rows:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		order = 0
		local market = snapshot.market
		if type(market) ~= "table" then
			return
		end
		local model = M.model(market, names, drafts, self)
		if model.gate ~= nil then
			local gate = label(M.text(ctx.locale, model.gate), 1, line())
			gate.Name = "MarketGate"
		end
		if model.balance ~= nil then
			label(M.text(ctx.locale, "market_balance", model.balance), 1, line())
		end
		label(M.text(ctx.locale, "market_sell"), 1, line())
		if #model.sell == 0 then
			label(M.text(ctx.locale, "market_nothing"), 1, line())
		end
		for _, entry in model.sell do
			label(M.text(ctx.locale, "market_have", entry.name, entry.held), 1, line())
			local draft = entry.draft
			local controls = line()
			local function stepper(field: string, direction: number)
				return function()
					drafts[entry.catalogId] = M.step(drafts[entry.catalogId] or draft, field, direction, entry.held)
					render(latest)
				end
			end
			button("-", 0, 0.12, controls, stepper("quantity", -1))
			button("+", 0.12, 0.12, controls, stepper("quantity", 1))
			button("-$", 0.24, 0.14, controls, stepper("price", -1))
			button("+$", 0.38, 0.14, controls, stepper("price", 1))
			button(M.text(ctx.locale, "market_list"), 0.52, 0.48, controls, function()
				send(M.LIST, { entry.catalogId, draft.quantity, draft.price }, function()
					return M.text(ctx.locale, "market_listed", entry.name)
				end)
			end, model.eligible)
			label(M.text(ctx.locale, "market_draft", draft.quantity, draft.price, entry.fee), 1, line())
		end
		if #model.mine > 0 then
			label(M.text(ctx.locale, "market_mine"), 1, line())
		end
		for _, own in model.mine do
			local row = line()
			label(own.name .. "  " .. M.text(ctx.locale, "market_price", own.unitPrice, own.quantity), 0.64, row)
			button(M.text(ctx.locale, "market_cancel"), 0.64, 0.36, row, function()
				send(M.CANCEL, { own.id }, function()
					return M.text(ctx.locale, "market_cancelled", own.name)
				end)
			end)
		end
		label(M.text(ctx.locale, "market_browse"), 1, line())
		if #model.browse == 0 then
			label(M.text(ctx.locale, "market_empty"), 1, line())
		end
		for _, catalog in model.browse do
			for _, listing in catalog.listings do
				local row = line()
				label(
					catalog.name .. "  " .. M.text(ctx.locale, "market_price", listing.unitPrice, listing.quantity),
					0.64,
					row
				)
				button(M.text(ctx.locale, "market_buy"), 0.64, 0.36, row, function()
					send(M.BUY, { listing.id }, function()
						return M.text(ctx.locale, "market_bought", catalog.name)
					end)
				end, model.eligible)
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
