--!strict
-- Exact item ids and prices match the market and harbor-sell command contracts.
local M = {}
local Ledger = require("../../../core/domain/command/Ledger")
local CrossServer = require("../../../core/domain/market/CrossServer")
local Locale = require("./SurvivalHUDLocale")
local env: any = getfenv()

-- Catalog browse page size: the tradeable set is the whole content catalog (~200 ids), so the
-- item picker is a searchable, category-filtered, paged list instead of one button per id.
M.PAGE_SIZE = 8
M.CATEGORIES = { "all", "material", "food", "gear", "building" }
local GEAR_TAGS = { tool = true, ["weapon-tool"] = true, clothing = true, saddle = true, instrument = true }

--- Browse category of a content item: gear, building (kits/parts), food or material.
function M.category(item: any?): string
	if not item then
		return "material"
	end
	for _, tag in item.tags or {} do
		if GEAR_TAGS[tag] or tag == "sprinkler" then
			return "gear"
		end
	end
	local id: string = item.id
	if string.sub(id, -4) == "-kit" or table.find(item.tags or {}, "building-part") then
		return "building"
	end
	return if item.foodEffects then "food" else "material"
end

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

--- Listing fee line: the same fee the server books (CrossServer.fee), and what the seller collects.
function M.feeText(locale: string, price: number): string
	local fee = CrossServer.fee(price)
	local template = if string.sub(locale, 1, 2) == "ko"
		then "수수료 %d%%: %d · 판매 시 받는 조개돈 %d"
		else "Fee %d%%: %d · you receive %d when sold"
	return string.format(template, CrossServer.FEE_PERCENT, fee, price - fee)
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
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.Enabled = "ForgeCrossServerMarket", false, false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local sheet = ctx.ui.components.modalSheet(ctx.ui.theme.default, {
		name = "TradeSheet",
		title = text("Harbor market", "항구 장터"),
		parent = gui,
	})
	ctx.fitSheet(sheet.frame)
	sheet.frame.Visible = true
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
		status.Text = if result.ok
			then text("Confirmed", "완료")
			else text("Settlement pending: ", "정산 대기 중: ") .. tostring(result.reason)
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
	local function render(snapshot)
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
				send("buy", { listing.id, listing.price })
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
	local unsubscribe = ctx.onSnapshot(function(snapshot)
		latest = snapshot
		render(snapshot)
	end)
	sheet.close.Activated:Connect(function()
		gui.Enabled = false
	end)
	ctx.dock({
		id = "market",
		label = text("Market", "장터"),
		order = 5,
		setOpen = function(open)
			gui.Enabled = open
		end,
		isOpen = function()
			return gui.Enabled
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
			gui.Enabled = true
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
