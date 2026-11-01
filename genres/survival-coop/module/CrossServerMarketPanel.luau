--!strict
-- Exact item ids and prices match the market and harbor-sell command contracts.
local M = {}
local Ledger = require("../../../core/domain/command/Ledger")
local CrossServer = require("../../../core/domain/market/CrossServer")
local Locale = require("./SurvivalHUDLocale")
local BuyScreen = require("./RecoveredScreens")
local SocialLocale = require("./SocialLocale")
local IconFallback = require("../../../core/ui-kit/IconFallback")
local Shell = require("./HudShell")
local Cards = require("./SheetCards")
local Theme = require("../../../core/ui-kit/Theme")
local env: any = getfenv()

-- Catalog browse page size: the tradeable set is the whole content catalog (~200 ids), so the
-- item picker is a searchable, category-filtered, paged list instead of one button per id.
M.PAGE_SIZE = 8
M.CATEGORIES = { "all", "material", "food", "gear", "building" }
-- Single-player mode keeps only the harbor (NPC) buyback; buying, own listings and the collection
-- box need other players' listings.
M.SOLO_TABS = table.freeze({ "sell" })
-- Browse category of a content item (the storage screen owns it; same buckets).
M.category = BuyScreen.storage.category

--- Pure catalog filter: case-insensitive substring of the display name or id, one category,
--- clamped page. Returns the page's ids plus the clamped page and page count.
function M.browse(
	ids: { string },
	query: string,
	category: string,
	page: number,
	name: (string) -> string,
	categoryOf: (string) -> string
): { ids: { string }, page: number, pages: number }
	local needle = string.lower(query or "")
	local matched = {}
	for _, id in ids do
		local label = string.lower(name(id) or id)
		local hit = needle == ""
			or string.find(label, needle, 1, true) ~= nil
			or string.find(id, needle, 1, true) ~= nil
		if hit and (category == "all" or categoryOf(id) == category) then
			table.insert(matched, id)
		end
	end
	local pages = math.max(1, math.ceil(#matched / M.PAGE_SIZE))
	local current = math.clamp(math.floor(page or 1), 1, pages)
	local slice = {}
	for index = (current - 1) * M.PAGE_SIZE + 1, math.min(#matched, current * M.PAGE_SIZE) do
		table.insert(slice, matched[index])
	end
	return { ids = slice, page = current, pages = pages }
end

--- True when a world prompt opens ui.dialogue first (ExtensionPanels' speaker rule).
function M.talksFirst(prompt: any): boolean
	if type(prompt:GetAttribute("ForgeDialogue")) == "string" then
		return true
	end
	local holder = prompt.Parent
	local facility = if holder then holder:GetAttribute("ForgeHarborFacility") else nil
	return type(facility) == "string" and string.sub(facility, 1, 4) == "npc."
end

--- Harbor sell refusal text; an oversell names how many units of that item the bag holds.
function M.sellRefusal(locale: string, reason: string?, items: { [string]: any }, catalogId: string): string
	if reason ~= "INSUFFICIENT_ITEMS" then
		return Locale.refusal(locale, reason or "unknown")
	end
	local held = 0
	for _, item in items do
		held += if item.catalogId == catalogId then item.quantity else 0
	end
	return string.format(Locale.text(locale, "oversell"), held)
end

-- market-list refusals: every code the list path can return (eligibility gate, CrossServer book,
-- Session admission/ledger, client transport) maps to its own line; unknown codes say so.
local LIST_REFUSALS: { [string]: string } = {
	INVALID_ACCOUNT = "market.account",
	INELIGIBLE_ACCOUNT_AGE = "market.age",
	INELIGIBLE_PLAYTIME = "market.playtime",
	INELIGIBLE_TUTORIAL = "market.tutorial",
	invalid_listing = "market.invalid",
	["invalid args"] = "market.invalid",
	["invalid arity"] = "market.invalid",
	["invalid tuple"] = "market.invalid",
	["invalid tuple data"] = "market.invalid",
	listing_declined = "market.declined",
	item_unavailable = "market.declined",
	pending = "market.pending",
	COMMAND_PENDING = "market.pending",
	SERVER_EVENT_PENDING = "market.pending",
	TRANSFER_PENDING = "market.pending",
	COMBAT_PENDING = "market.combat",
	COMMIT_FAILED = "market.pending",
	PERSONAL_UNAVAILABLE = "market.pending",
	conflict = "market.conflict",
	REQUEST_CONFLICT = "market.conflict",
	REQUEST_EXPIRED = "market.expired",
	STALE_PERSONAL_REVISION = "market.expired",
	["rate limited"] = "market.rate",
	RATE_LIMITED = "market.rate",
	REQUEST_WINDOW_FULL = "market.rate",
	ACTOR_LEFT = "market.left",
	ACTOR_LEAVING = "market.left",
	["player not joined"] = "market.left",
	COMMAND_UNAVAILABLE = "market.unavailable",
	TRANSPORT_FAILED = "market.transport",
}

--- Player sentence for a market-list refusal (never the raw code).
function M.listRefusal(locale: string, reason: string?): string
	local code = reason or ""
	if string.sub(code, 1, 16) == "TRANSPORT_FAILED" then
		code = "TRANSPORT_FAILED"
	end
	return Locale.text(locale, LIST_REFUSALS[code] or "market.refused")
end

--- Codes with their own list refusal line (specs prove each differs from the fallback).
function M.listRefusalCodes(): { string }
	local codes = {}
	for code in LIST_REFUSALS do
		table.insert(codes, code)
	end
	table.sort(codes)
	return codes
end

--- Sell tile columns for a list pane `width` px wide: tiles stay at least 170 px (name, quality and
--- price rows unclipped beside a 40 px icon), one to four across.
function M.sellColumns(width: number): number
	return math.clamp(math.floor(width / 170), 1, 4)
end

--- Tile rows of a bag stack: its quality line (level only when the item has one), the held count
--- and the harbor's unit price (or the not-bought line).
function M.tileLines(locale: string, item: any, each: number?): (string, string, string)
	local quality = Locale.text(locale, "quality") .. " " .. tostring(math.floor((item.qualityMilli or 0) / 1000))
	local level = tonumber(item.attributes and item.attributes.level) or 0
	if level > 0 then
		quality ..= " · " .. string.format(Locale.text(locale, "panel.tile_level"), level)
	end
	local held = string.format(Locale.text(locale, "panel.tile_held"), item.quantity)
	local price = if each
		then string.format(Locale.text(locale, "panel.tile_price"), each)
		else Locale.text(locale, "panel.tile_no_price")
	return quality, held, price
end

--- Listing fee line: the same fee the server books (CrossServer.fee), and what the seller collects.
function M.feeText(locale: string, price: number): string
	local fee = CrossServer.fee(price)
	local template = if string.sub(locale, 1, 2) == "ko"
		then "수수료 %d%%: %d · 판매 시 받는 조개돈 %d"
		else "Fee %d%%: %d · you receive %d when sold"
	return string.format(template, CrossServer.FEE_PERCENT, fee, price - fee)
end

--- Trading post as a full-screen panel (ui-spec 6.2, Robango C8; ExtensionPanels shell only): a
--- rail of Buy / Sell / My listings / Collection box tabs, the middle list or grid and the right
--- detail with one primary button. Same commands and refusal lines as the side sheet.
function M.shellPanel(
	ctx: any,
	gui: any,
	sheet: any,
	browse: any,
	drafts: { [string]: any },
	definitions: { [string]: any },
	rerender: () -> ()
): (any) -> ()
	local Instance, Enum, UDim2, UDim, Vector2 = env.Instance, env.Enum, env.UDim2, env.UDim, env.Vector2
	local theme = ctx.ui.theme.default
	local function t(key: string): string
		return Locale.text(ctx.locale, key)
	end
	sheet.frame:SetAttribute("ForgeShellPanel", "market")
	local function pane(name: string): any
		local frame = Instance.new("ScrollingFrame")
		frame.Name, frame.BackgroundTransparency, frame.BorderSizePixel = name, 1, 0
		frame.ScrollBarThickness, frame.CanvasSize = 6, UDim2.new()
		frame.AutomaticCanvasSize, frame.ZIndex, frame.Parent = Enum.AutomaticSize.Y, 52, sheet.frame
		local layout = Instance.new("UIListLayout")
		layout.Padding, layout.SortOrder, layout.Parent = UDim.new(0, 6), Enum.SortOrder.LayoutOrder, frame
		return frame
	end
	local rail, list, detail = pane("Rail"), pane("List"), pane("Detail")
	local action: (() -> ())? = nil
	local primary = ctx.ui.components.button(theme, {
		text = "",
		size = UDim2.fromOffset(120, 48),
		parent = sheet.frame,
		onClick = function()
			if action then
				action()
			end
		end,
	})
	primary.Name, primary.ZIndex = "Primary", 53
	local currency =
		ctx.ui.components.label(theme, { text = "", size = UDim2.fromOffset(140, 32), parent = sheet.frame })
	currency.Name, currency.ZIndex = "Currency", 53
	currency.BackgroundColor3, currency.BackgroundTransparency = Shell.color(Shell.PALETTE.ochre), 0
	currency.TextColor3 = Shell.color(Shell.PALETTE.ink)
	local pill = Instance.new("UICorner")
	pill.CornerRadius, pill.Parent = UDim.new(0.5, 0), currency
	-- U7: the kit label's halo stroke smeared ink digits on the ochre pill; plain bold ink.
	local halo = currency:FindFirstChildOfClass("UIStroke")
	if halo then
		halo:Destroy()
	end
	currency.Font = Enum.Font.BuilderSansBold
	local view: any = { tab = "buy", item = nil, listing = nil, own = nil, claim = nil, sell = nil }
	local layout: any = nil
	local order = 0
	local function place()
		local size = gui.AbsoluteSize
		layout = Shell.panel(size.X, size.Y, Shell.guiClear(gui), "market")
		Shell.applyPanel(sheet, layout, Vector2.zero)
		local at = Vector2.new(layout.frame.x, layout.frame.y)
		Shell.put(rail, layout.categories, at)
		Shell.put(list, layout.list, at)
		Shell.put(detail, layout.detailBody, at)
		Shell.put(primary, layout.primary, at)
		Shell.put(currency, layout.currency, at)
		primary.TextSize, currency.TextSize = layout.text.heading, layout.text.label
	end
	local function clear(frame: any)
		for _, child in frame:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end
	local function text(parent: any, value: string, style: string?, height: number?): any
		order += 1
		local size = layout.text[style or "body"]
		local item = ctx.ui.components.label(theme, {
			text = value,
			size = UDim2.new(1, -8, 0, height or math.max(28, math.ceil(size * 1.5))),
			parent = parent,
			textSize = size,
		})
		item.TextXAlignment, item.LayoutOrder = Enum.TextXAlignment.Left, order
		item.TextColor3 = Shell.color(Shell.PALETTE.bone)
		return item
	end
	-- R14: buttons drawn selected this render (the sheet skin keeps them sea-glass, others chips).
	local chosen: { [any]: true } = {}
	local function press(parent: any, value: string, selected: boolean, callback: () -> (), height: number?): any
		order += 1
		local item = ctx.ui.components.button(theme, {
			text = value,
			size = UDim2.new(1, -8, 0, height or layout.listRow),
			parent = parent,
			onClick = callback,
		})
		item.LayoutOrder, item.TextSize, item.TextWrapped = order, layout.text.label, true
		Shell.panelButton(item, selected)
		if selected then
			chosen[item] = true
		end
		return item
	end
	local function grid(parent: any, columns: number): any
		order += 1
		local frame = Instance.new("Frame")
		frame.Name, frame.BackgroundTransparency, frame.LayoutOrder = "Grid", 1, order
		frame.Size, frame.AutomaticSize, frame.Parent = UDim2.new(1, -8, 0, 0), Enum.AutomaticSize.Y, parent
		local cells = Instance.new("UIGridLayout")
		local edge = Shell.gridCell(layout.list.width, columns, layout.gap)
		cells.CellSize, cells.CellPadding = UDim2.fromOffset(edge, edge), UDim2.fromOffset(layout.gap, layout.gap)
		cells.SortOrder, cells.Parent = Enum.SortOrder.LayoutOrder, frame
		return frame
	end
	local function stepper(parent: any, steps: { number }, apply: (number) -> ())
		order += 1
		local row = Instance.new("Frame")
		row.Name, row.BackgroundTransparency, row.LayoutOrder = "Stepper", 1, order
		row.Size, row.Parent = UDim2.new(1, -8, 0, Shell.MIN_TOUCH), parent
		for index, step in steps do
			local item = ctx.ui.components.button(theme, {
				text = (if step > 0 then "+" else "") .. tostring(step),
				size = UDim2.new(1 / #steps, -6, 1, 0),
				position = UDim2.fromScale((index - 1) / #steps, 0),
				parent = row,
				onClick = function()
					apply(step)
				end,
			})
			item.TextSize = layout.text.label
			Shell.panelButton(item, false)
		end
	end
	local status = ""
	local function send(name: string, args: { any }, listRefusal: boolean?)
		local result = ctx.send("survival-coop:market-" .. name, args)
		status = if result.ok
			then t("panel.done")
			elseif listRefusal then M.listRefusal(ctx.locale, result.reason)
			else SocialLocale.refusal(ctx.locale, result.reason)
		rerender()
	end
	local CATEGORY_KEY = { all = "all", material = "material", food = "food", gear = "tool", building = "building" }
	local GLYPH = { all = "item", material = "wood", food = "food", gear = "tool", building = "building" }
	-- U7: pack category art (ui.icon.cat.<id>) on the buy grid; nil keeps the glyph.
	local function catArt(key: string): string?
		local icon = if ctx.icons and ctx.icons.ui then ctx.icons.ui("cat." .. CATEGORY_KEY[key]) else nil
		return if icon and icon.image and icon.image ~= "" then icon.image else nil
	end
	-- An empty pane: the parchment empty-state card (icon ring + one line), as craft and bag show it.
	local function emptyNote(parent: any, value: string, iconId: string)
		order += 1
		local icon = if ctx.icons and ctx.icons.ui then ctx.icons.ui(iconId) else nil
		Cards.empty(parent, {
			name = "EmptyNote",
			order = order,
			icon = { image = icon and icon.image, category = "item" },
			title = value,
			size = Theme.sheetText("body", layout.safeHeight),
		})
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(rerender)
	return function(snapshot: any)
		place()
		local state = snapshot.market
		local keep = { list.CanvasPosition, detail.CanvasPosition }
		for _, frame in { rail, list, detail } do
			clear(frame)
		end
		order, action = 0, nil
		table.clear(chosen)
		local header = sheet.frame:FindFirstChild("Header")
		local title = header and header:FindFirstChild("Title")
		if title then
			title.Text = t("panel.trading_post")
		end
		-- Single-player mode: buy, my listings and the collection box are the player market; only
		-- selling to the harbor (NPC buyback) works alone, so it is the one tab.
		local tabs: { string } = if ctx.solo then M.SOLO_TABS else Shell.MARKET_TABS
		if not table.find(tabs, view.tab) then
			view.tab = tabs[1]
		end
		for _, tab in tabs do
			press(rail, t("panel.tab." .. tab .. (if ctx.solo then "_solo" else "")), view.tab == tab, function()
				view.tab, status = tab, ""
				rerender()
			end, layout.categoryRow)
		end
		if not state then
			currency.Visible, primary.Visible = false, false
			text(list, t("panel.market_unavailable"), "body", 60).TextWrapped = true
			return
		end
		currency.Visible = true
		currency.Text = string.format(t("coins"), tonumber(state.balance) or 0)
		local primaryText: string? = nil
		if view.tab == "buy" then
			if browse.picked == nil then
				-- Category grid (4 columns) first; picking one turns it into the item list.
				local cells = grid(list, Shell.MARKET_GRID_COLUMNS)
				for index, key in M.CATEGORIES do
					local tile = ctx.ui.components.button(theme, {
						text = t("cat." .. CATEGORY_KEY[key]),
						size = UDim2.fromOffset(64, 64),
						parent = cells,
						onClick = function()
							browse.category, browse.page, browse.picked = key, 1, true
							rerender()
						end,
					})
					tile.LayoutOrder, tile.TextSize, tile.TextWrapped = index, layout.text.label, true
					tile.TextYAlignment = Enum.TextYAlignment.Bottom
					Shell.panelButton(tile, browse.category == key)
					local pad = Instance.new("UIPadding")
					pad.PaddingBottom, pad.Parent = UDim.new(0, 6), tile
					local badge = IconFallback.mount(
						tile,
						GLYPH[key],
						UDim2.fromScale(0.56, 0.56),
						UDim2.fromScale(0.22, 0.06),
						catArt(key)
					)
					if catArt(key) then
						badge.BackgroundTransparency = 1
					end
				end
			else
				press(list, t("panel.back"), false, function()
					browse.picked = nil
					rerender()
				end, Shell.MIN_TOUCH)
				local found = M.browse(state.catalogIds, browse.query, browse.category, browse.page, function(id)
					return ctx.icons.item(id).text
				end, function(id)
					return M.category(definitions[id])
				end)
				browse.page = found.page
				if #found.ids == 0 then
					text(list, t("panel.no_match"), "body", 48).TextWrapped = true
				end
				for _, id in found.ids do
					press(list, ctx.icons.item(id).text, state.filter == id, function()
						view.listing = nil
						send("browse", { id, 1 })
					end)
				end
				if found.page < found.pages then
					press(list, t("panel.more"), false, function()
						browse.page += 1
						rerender()
					end, Shell.MIN_TOUCH)
				end
			end
			-- Detail: the selected item's bundles; the primary buys the picked one (ui.market-buy confirms).
			if state.filter then
				text(detail, ctx.icons.item(state.filter).text, "heading")
			end
			if #state.listings == 0 then
				emptyNote(detail, t("panel.no_bundles"), if state.filter then "empty" else "market")
			end
			for _, listing in state.listings do
				if view.listing == nil then
					view.listing = listing.id
				end
				press(
					detail,
					string.format(t("panel.bundle"), listing.quantity, listing.price),
					view.listing == listing.id,
					function()
						view.listing = listing.id
						rerender()
					end,
					Shell.MIN_TOUCH
				)
				if view.listing == listing.id then
					primaryText = t("panel.buy")
					action = function()
						BuyScreen.buying.listing = listing
						if not (ctx.open and ctx.open("market-buy")) then
							send("buy", { listing.id, listing.price })
						end
					end
				end
			end
		elseif view.tab == "sell" then
			-- R14 (D2 phone 2.75): the sell sheet is the craft/bag parchment family. Category chips under
			-- the tab, a tile grid in the middle (icon, name, quality, held count, harbor unit price on
			-- every tile) and the picked stack's card, quantity, sale preview and primary on the right.
			local harbor = snapshot["harbor-buyback"]
			local buys = harbor and harbor.prices or {}
			local tradable = {}
			local present: { [string]: boolean } = {}
			for id, item in state.items do
				-- Solo: what the harbor buys; otherwise what the player market trades.
				if if ctx.solo then buys[item.catalogId] ~= nil else table.find(state.catalogIds, item.catalogId) then
					table.insert(tradable, id)
					present[M.category(definitions[item.catalogId])] = true
				end
			end
			table.sort(tradable)
			view.sellCategory = if present[view.sellCategory or ""] then view.sellCategory else "all"
			for _, key in M.CATEGORIES do
				if key == "all" or present[key] then
					local chip = press(rail, t("cat." .. CATEGORY_KEY[key]), view.sellCategory == key, function()
						view.sellCategory = key
						rerender()
					end, layout.categoryRow)
					chip.Name = "SellCategory-" .. key
				end
			end
			local ids = {}
			for _, id in tradable do
				local catalogId = state.items[id].catalogId
				if view.sellCategory == "all" or M.category(definitions[catalogId]) == view.sellCategory then
					table.insert(ids, id)
				end
			end
			if not table.find(ids, view.sell) then
				view.sell = ids[1]
			end
			local size = Theme.sheetText("body", layout.safeHeight)
			local columns = M.sellColumns(layout.list.width)
			order += 1
			local tiles = Instance.new("Frame")
			tiles.Name, tiles.BackgroundTransparency, tiles.LayoutOrder = "SellTiles", 1, order
			tiles.Size, tiles.AutomaticSize, tiles.Parent = UDim2.new(1, -8, 0, 0), Enum.AutomaticSize.Y, list
			local cells = Instance.new("UIGridLayout")
			cells.CellSize =
				UDim2.fromOffset(Shell.gridCell(layout.list.width, columns, layout.gap), Cards.pressTileHeight(4, size))
			cells.CellPadding = UDim2.fromOffset(layout.gap, layout.gap)
			cells.SortOrder, cells.Parent = Enum.SortOrder.LayoutOrder, tiles
			for index, id in ids do
				local item = state.items[id]
				local icon = ctx.icons.item(item.catalogId)
				local quality, held, price = M.tileLines(ctx.locale, item, buys[item.catalogId])
				local tile = Cards.pressTile(tiles, {
					name = "SellTile-" .. id,
					order = index,
					icon = icon,
					title = icon.text,
					lines = { quality, held },
					price = price,
					selected = view.sell == id,
					size = size,
				})
				tile.Activated:Connect(function()
					view.sell = id
					rerender()
				end)
			end
			if #ids == 0 then
				emptyNote(list, t("panel.nothing_to_sell"), "bag")
			end
			local picked = if view.sell then state.items[view.sell] else nil
			if picked then
				local id = view.sell :: string
				local draft = drafts[id] or { quantity = 1, price = 10 }
				drafts[id] = draft
				draft.quantity = math.clamp(draft.quantity, 1, math.max(1, picked.quantity))
				local icon = ctx.icons.item(picked.catalogId)
				local quality, held, price = M.tileLines(ctx.locale, picked, buys[picked.catalogId])
				order += 1
				Cards.hero(detail, {
					name = "SellCard",
					order = order,
					icon = icon,
					title = icon.text,
					caption = quality .. " · " .. held .. "\n" .. price,
					size = size,
				})
				if state.eligible == false and not ctx.solo then
					local blocked = text(detail, M.listRefusal(ctx.locale, state.ineligibleReason), "body", 60)
					blocked.Name, blocked.TextWrapped = "ListBlocked", true
				end
				text(detail, string.format(t("panel.quantity"), draft.quantity), "label")
				stepper(detail, { -10, -1, 1, 10 }, function(step)
					draft.quantity = math.clamp(draft.quantity + step, 1, picked.quantity)
					rerender()
				end)
				if not ctx.solo then
					text(detail, string.format(t("panel.price"), draft.price), "label")
					stepper(detail, Shell.PRICE_STEPS, function(step)
						draft.price = Shell.stepPrice(draft.price, step)
						rerender()
					end)
				end
				if not ctx.solo then
					local fee = text(detail, M.feeText(ctx.locale, draft.price), "caption", 40)
					fee.Name, fee.TextWrapped = "ListFee", true
					primaryText = t("panel.list")
					action = function()
						send("list", { id, draft.quantity, draft.price }, true)
					end
				end
				local each = buys[picked.catalogId]
				if ctx.solo and not each then
					local none = text(detail, t("panel.harbor_no_buy"), "body", 44)
					none.Name, none.TextWrapped = "HarborNoBuy", true
				end
				if each then
					local preview = text(
						detail,
						string.format(t("panel.sale_preview"), draft.quantity, draft.quantity * each),
						"body",
						44
					)
					preview.Name, preview.TextWrapped = "SalePreview", true
					local cap = text(
						detail,
						string.format(Locale.text(ctx.locale, "harbor"), harbor.remaining, harbor.dailyUnits),
						"label"
					)
					cap.Name = "HarborCap"
					local function sell()
						local result = ctx.send("survival-coop:harbor-sell", { picked.catalogId, draft.quantity })
						status = if result.ok
							then t("panel.done")
							else M.sellRefusal(ctx.locale, result.reason, state.items, picked.catalogId)
						rerender()
					end
					local label = string.format(Locale.text(ctx.locale, "sell"), icon.text, each)
					if ctx.solo then
						-- Solo: selling to the harbor is the sheet's one primary action.
						primaryText, action = label, sell
					else
						press(detail, label, false, sell, Shell.MIN_TOUCH)
					end
				end
			end
		elseif view.tab == "mine" then
			if #state.listed == 0 then
				emptyNote(list, t("panel.no_listings"), "market")
			end
			for _, listing in state.listed do
				if view.own == nil then
					view.own = listing.id
				end
				press(
					list,
					ctx.icons.item(listing.catalogId).text
						.. "  "
						.. string.format(t("panel.bundle"), listing.quantity, listing.price),
					view.own == listing.id,
					function()
						view.own = listing.id
						rerender()
					end
				)
				if view.own == listing.id then
					text(detail, ctx.icons.item(listing.catalogId).text, "heading")
					text(detail, string.format(t("panel.bundle"), listing.quantity, listing.price), "body")
					primaryText = t("panel.withdraw")
					action = function()
						view.own = nil
						send("cancel", { listing.id })
					end
				end
			end
		else
			if #state.claims == 0 then
				emptyNote(list, t("panel.no_claims"), "inbox")
			end
			for _, claim in state.claims do
				if view.claim == nil then
					view.claim = claim.id
				end
				local value = claim.value
				local line = if value.item
					then ctx.icons.item(value.item.catalogId).text .. " x" .. tostring(value.item.quantity)
					else string.format(t("coins"), value.coins or 0)
				press(list, line, view.claim == claim.id, function()
					view.claim = claim.id
					rerender()
				end)
				if view.claim == claim.id then
					text(detail, line, "heading")
					primaryText = t("panel.collect")
					action = function()
						view.claim = nil
						send("claim", { claim.id })
					end
				end
			end
			if state.page < state.pages then
				press(list, t("panel.more"), false, function()
					send("browse", { state.filter, state.page + 1 })
				end, Shell.MIN_TOUCH)
			end
		end
		if status ~= "" then
			local line = text(detail, status, "label", 44)
			line.Name, line.TextWrapped, line.LayoutOrder = "MarketStatus", true, -1
		end
		primary.Visible = primaryText ~= nil
		primary.Text = primaryText or ""
		Shell.panelButton(primary, true)
		primary.TextWrapped = true
		-- R14: the craft/bag sheet skin (Theme.sheet parchment, leather bar, chip rows, sea-glass
		-- selection and primary), the same pass SurvivalHUD runs on its panels.
		local safe = layout.safeHeight
		local lists = { rail, list, detail }
		for _, child in list:GetChildren() do
			if child.Name == "Grid" then
				table.insert(lists, child)
			end
		end
		Shell.skinSheet(sheet.frame, {
			tokens = Theme.sheet,
			body = Theme.sheetText("body", safe),
			title = Theme.sheetText("title", safe),
			selected = function(item: any): boolean
				return chosen[item] == true
			end,
			lists = lists,
		})
		list.CanvasPosition, detail.CanvasPosition = keep[1], keep[2]
	end
end

function M.factory(ctx: any): any
	local Instance = ctx.instance or env.Instance
	local Enum = ctx.enum or env.Enum
	local UDim2 = ctx.udim2 or env.UDim2
	local Color3 = ctx.color3 or env.Color3
	local game = ctx.game or env.game
	local korean = string.sub(ctx.locale, 1, 2) == "ko"
	local function text(en: string, ko: string): string
		return if korean then ko else en
	end
	-- The gui stays enabled and the sheet frame is the open state (like SocialSheet). The shell panel
	-- sizes itself from this gui's AbsoluteSize, and a disabled ScreenGui is not laid out: toggling
	-- Enabled kept the size from when it was last on screen (D2 F4: 1279x662 on a 799x359 phone, the
	-- Close pebble off-screen).
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn = "ForgeCrossServerMarket", false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local sheet = ctx.ui.components.modalSheet(ctx.ui.theme.default, {
		name = "TradeSheet",
		title = text("Harbor market", "항구 장터"),
		parent = gui,
	})
	ctx.fitSheet(sheet.frame)
	sheet.frame.Visible = false
	local status = ctx.ui.components.label(
		ctx.ui.theme.default,
		{ text = "", size = UDim2.new(1, 0, 0, 48), parent = sheet.scroll }
	)
	status.TextWrapped = true
	local body = Instance.new("Frame")
	body.Size, body.AutomaticSize, body.BackgroundTransparency, body.Parent =
		UDim2.fromScale(1, 0), Enum.AutomaticSize.Y, 1, sheet.scroll
	local layout = Instance.new("UIListLayout")
	layout.SortOrder, layout.Parent = Enum.SortOrder.LayoutOrder, body
	local order = 0
	local drafts: { [string]: any } = {}
	local lastRender: string? = nil
	local browse = { query = "", category = "all", page = 1 }
	local definitions: { [string]: any } = {}
	for _, item in (ctx.content and ctx.content.items) or {} do
		definitions[item.id] = item
	end
	local rerender: () -> () = function() end
	local function send(action, args)
		local result = ctx.send("survival-coop:market-" .. action, args)
		status.Text = if result.ok then text("Confirmed", "완료") else SocialLocale.refusal(ctx.locale, result.reason)
	end
	local function label(value)
		order += 1
		local row = ctx.ui.components.label(
			ctx.ui.theme.default,
			{ text = value, size = UDim2.new(1, 0, 0, 48), parent = body }
		)
		row.LayoutOrder, row.TextWrapped = order, true
		return row
	end
	local function button(value, callback)
		order += 1
		local row = ctx.ui.components.button(
			ctx.ui.theme.default,
			{ text = value, size = UDim2.new(1, 0, 0, 48), parent = body, onClick = callback }
		)
		row.LayoutOrder = order
	end
	local function input(value, changed, caption: string?)
		if caption then
			label(caption).Name = "InputCaption"
		end
		order += 1
		local row = Instance.new("TextBox")
		row.Size, row.Text, row.ClearTextOnFocus = UDim2.new(1, 0, 0, 48), tostring(value), false
		row.TextSize, row.LayoutOrder, row.Parent = 18, order, body
		-- Dark field on the dark sheet (the default grey box read as a disabled control).
		row.BorderSizePixel = 0
		if Color3 then
			row.BackgroundColor3 = Color3.fromRGB(18, 28, 26)
			row.TextColor3 = Color3.fromRGB(240, 244, 240)
		end
		if caption then
			row.PlaceholderText = caption
		end
		-- Focus selects the whole number: typing replaces it and Backspace clears it, wherever the
		-- tap lands (a caret left before "1" made Backspace a no-op and "999" read "9991").
		row.Focused:Connect(function()
			row.CursorPosition = #row.Text + 1
			row.SelectionStart = 1
		end)
		row.FocusLost:Connect(function()
			changed(tonumber(row.Text))
		end)
		return row
	end
	local function itemLabel(id, quantity, suffix)
		local icon = ctx.icons.item(id)
		local row = label(icon.text .. " x" .. tostring(quantity) .. " " .. (suffix or ""))
		if icon.image then
			local image = Instance.new("ImageLabel")
			image.Size, image.Position, image.BackgroundTransparency =
				UDim2.fromOffset(32, 32), UDim2.new(0, 0, 0.5, -16), 1
			image.Image, image.Parent = icon.image, row
		end
	end
	local latest: any = nil
	local renderShell: ((any) -> ())? = nil
	if ctx.shell then
		renderShell = M.shellPanel(ctx, gui, sheet, browse, drafts, definitions, function()
			rerender()
		end)
	end
	local function render(snapshot)
		if renderShell then
			renderShell(snapshot)
			return
		end
		local state = snapshot.market
		if not state then
			-- No market slice means the cross-server market is not wired on this server (Studio has
			-- no MemoryStore); the snapshot will not bring one later, so never claim it is loading.
			status.Text = text(
				"Player market is unavailable on this server.",
				"이 서버에서는 플레이어 장터를 쓸 수 없어요."
			)
			status.Name = "MarketUnavailable"
			return
		end
		if status.Name == "MarketUnavailable" then
			-- A later snapshot carries the market: the stale 'unavailable' header goes.
			status.Text, status.Name = "", "MarketStatus"
		end
		local harbor = snapshot["harbor-buyback"]
		local signature = Ledger.canonical({ state, harbor, browse })
		if signature == lastRender then
			return
		end
		lastRender = signature
		for _, row in body:GetChildren() do
			if row ~= layout then
				row:Destroy()
			end
		end
		order = 0
		label(text("Shellmoney ", "조개돈 ") .. tostring(state.balance))
		label(text("Sell: quantity / whole bundle price", "판매: 수량 / 묶음 전체 가격"))
		if state.eligible == false then
			-- Say why before a press: the server refuses every listing while the gate holds.
			label(M.listRefusal(ctx.locale, state.ineligibleReason)).Name = "ListBlocked"
		end
		local sellable = 0
		for id, item in state.items do
			if not table.find(state.catalogIds, item.catalogId) then
				continue
			end
			sellable += 1
			itemLabel(item.catalogId, item.quantity, "")
			local draft = drafts[id] or { quantity = 1, price = 10 }
			drafts[id] = draft
			input(draft.quantity, function(value)
				draft.quantity = math.clamp(math.floor(value or 1), 1, item.quantity)
			end, text("Quantity", "수량"))
			local feeLine: any = nil
			input(draft.price, function(value)
				draft.price = math.clamp(math.floor(value or 1), 1, 1000000)
				feeLine.Text = M.feeText(ctx.locale, draft.price)
			end, text("Whole bundle price (shellmoney)", "묶음 전체 가격 (조개돈)"))
			local listStatus: any = nil
			button(
				Locale.text(ctx.locale, "trade.bundle.list")
					.. ": "
					.. ctx.icons.item(item.catalogId).text
					.. " x"
					.. tostring(draft.quantity),
				function()
					local result = ctx.send("survival-coop:market-list", { id, draft.quantity, draft.price })
					local message = if result.ok
						then text("Listed", "등록 완료")
						else M.listRefusal(ctx.locale, result.reason)
					-- Shown under the pressed List button; the sheet-top status may be scrolled off.
					status.Text, listStatus.Text, listStatus.Visible = message, message, true
				end
			)
			listStatus = label("")
			listStatus.Name, listStatus.Visible = "ListStatus", false
			feeLine = label(M.feeText(ctx.locale, draft.price))
			feeLine.Name = "ListFee"
		end
		if sellable == 0 then
			label(
				text(
					"No tradable goods yet. Gather resources and bring them to the harbor.",
					"판매할 재료가 없습니다. 재료를 채집하여 항구로 가져오세요."
				)
			)
		end
		if harbor then
			label(string.format(Locale.text(ctx.locale, "harbor"), harbor.remaining, harbor.dailyUnits))
		end
		for id, item in if harbor then state.items else {} do
			local price = harbor.prices[item.catalogId]
			if price then
				-- Own draft: the server refuses an oversell visibly, so only the floor is enforced here.
				local draft = drafts["harbor:" .. id] or { quantity = 1 }
				drafts["harbor:" .. id] = draft
				itemLabel(item.catalogId, item.quantity, string.format(text("· %d each", "· 개당 %d"), price))
				local box = input(draft.quantity, function(value)
					draft.quantity = math.max(math.floor(value or 1), 1)
				end)
				local rowStatus: any = nil
				button(
					string.format(Locale.text(ctx.locale, "sell"), ctx.icons.item(item.catalogId).text, price),
					function()
						local result = ctx.send("survival-coop:harbor-sell", { item.catalogId, draft.quantity })
						local message = if result.ok
							then ""
							else M.sellRefusal(ctx.locale, result.reason, state.items, item.catalogId)
						box.Text = tostring(draft.quantity)
						-- Shown under the pressed Sell button; the sheet-top status may be scrolled off.
						status.Text, rowStatus.Text, rowStatus.Visible = message, message, message ~= ""
					end
				)
				rowStatus = label("")
				rowStatus.Name, rowStatus.Visible = "SellStatus", false
			end
		end
		label(text("Your listings", "내 판매 목록"))
		for _, listing in state.listed do
			itemLabel(listing.catalogId, listing.quantity, tostring(listing.price))
			button(text("Cancel to collection box", "취소 후 수령함으로"), function()
				send("cancel", { listing.id })
			end)
		end
		label(text("Browse / filter", "목록 / 품목 선택"))
		button(text("Refresh listings", "판매 목록 새로고침"), function()
			send("browse", { state.filter, state.page })
		end)
		if #state.listings == 0 then
			label(
				text(
					"No bundles listed. Choose an item below or list your own goods.",
					"등록된 묶음이 없습니다. 아래 품목을 선택하거나 직접 판매해 보세요."
				)
			)
		end
		label(text("Find an item: name, then category", "품목 찾기: 이름, 종류"))
		local search = input(browse.query, function() end)
		search.PlaceholderText = text("Search items", "품목 검색")
		search.FocusLost:Connect(function()
			browse.query, browse.page = search.Text, 1
			rerender()
		end)
		local CATEGORY_TEXT = {
			all = text("All items", "전체"),
			material = text("Materials", "재료"),
			food = text("Food", "음식"),
			gear = text("Gear", "장비"),
			building = text("Building", "건축"),
		}
		for _, key in M.CATEGORIES do
			button((if browse.category == key then "> " else "") .. CATEGORY_TEXT[key], function()
				browse.category, browse.page = key, 1
				rerender()
			end)
		end
		local found = M.browse(state.catalogIds, browse.query, browse.category, browse.page, function(id)
			return ctx.icons.item(id).text
		end, function(id)
			return M.category(definitions[id])
		end)
		browse.page = found.page
		if #found.ids == 0 then
			label(text("No item matches this search.", "검색과 맞는 품목이 없습니다."))
		end
		for _, id in found.ids do
			button(ctx.icons.item(id).text, function()
				send("browse", { id, state.page })
			end)
		end
		if found.pages > 1 then
			label(text("Items page ", "품목 쪽 ") .. tostring(found.page) .. "/" .. tostring(found.pages))
			if found.page > 1 then
				button(text("Previous items", "이전 품목"), function()
					browse.page -= 1
					rerender()
				end)
			end
			if found.page < found.pages then
				button(text("More items", "다음 품목"), function()
					browse.page += 1
					rerender()
				end)
			end
		end
		for _, listing in state.listings do
			itemLabel(
				listing.catalogId,
				listing.quantity,
				text("Whole bundle ", "묶음 전체 ") .. tostring(listing.price)
			)
			button(text("Buy bundle", "묶음 구매"), function()
				-- ui.market-buy confirms the exact bundle, total and balance before the debit.
				BuyScreen.buying.listing = listing
				if not (ctx.open and ctx.open("market-buy")) then
					send("buy", { listing.id, listing.price })
				end
			end)
		end
		label(text("Collection box ", "수령함 ") .. tostring(state.page) .. "/" .. tostring(state.pages))
		for _, claim in state.claims do
			if claim.value.item then
				itemLabel(claim.value.item.catalogId, claim.value.item.quantity, "")
			else
				label(text("Shellmoney ", "조개돈 ") .. tostring(claim.value.coins))
			end
			button(text("Collect", "수령"), function()
				send("claim", { claim.id })
			end)
		end
		if state.page > 1 then
			button(text("Previous page", "이전 쪽"), function()
				send("browse", { state.filter, state.page - 1 })
			end)
		end
		if state.page < state.pages then
			button(text("Next page", "다음 쪽"), function()
				send("browse", { state.filter, state.page + 1 })
			end)
		end
	end
	rerender = function()
		if latest then
			render(latest)
		end
	end
	-- p134 v58/v59 memory: the server pushes every second (other slices tick), and rebuilding the
	-- market grid on each push churned ~95 instances/s. Only a change in what it shows rebuilds it.
	local lastShown: string? = nil
	local http = game:GetService("HttpService")
	local unsubscribe = ctx.onSnapshot(function(snapshot)
		latest = snapshot
		local ok, shown = pcall(http.JSONEncode, http, { snapshot.market, snapshot["harbor-buyback"] })
		if ok and shown == lastShown then
			return
		end
		lastShown = if ok then shown else nil
		render(snapshot)
	end)
	-- One open state for the dock, the X and the prompt.
	local function setOpen(open: boolean)
		sheet.frame.Visible = open
		if open then
			rerender()
		end
	end
	sheet.close.Activated:Connect(function()
		setOpen(false)
	end)
	ctx.dock({
		id = "market",
		label = text("Market", "장터"),
		order = 5,
		setOpen = setOpen,
		isOpen = function()
			return sheet.frame.Visible == true
		end,
	})
	local prompt = game:GetService("ProximityPromptService").PromptTriggered:Connect(function(value, player)
		-- A prompt that talks first (NPC, market board) opens ui.dialogue; its Market choice opens
		-- this sheet. Opening here too stacked both sheets at once.
		if
			player == game:GetService("Players").LocalPlayer
			and value:GetAttribute("ForgeMarket")
			and not M.talksFirst(value)
		then
			setOpen(true)
		end
	end)
	return {
		destroy = function()
			unsubscribe()
			prompt:Disconnect()
			gui:Destroy()
		end,
	}
end
return M
