--!strict
-- Bundle prices and exact item ids match the durable market command contract.
local M = {}
local Ledger = require("../../../core/domain/command/Ledger")
local Locale = require("./SurvivalHUDLocale")
local env: any = getfenv()
function M.factory(ctx: any): any
	local Instance = ctx.instance or env.Instance
	local Enum = ctx.enum or env.Enum
	local UDim2 = ctx.udim2 or env.UDim2
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
	layout.Parent = body
	local order = 0
	local drafts: { [string]: any } = {}
	local lastRender: string? = nil
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
	local function input(value, changed)
		order += 1
		local row = Instance.new("TextBox")
		row.Size, row.Text, row.ClearTextOnFocus = UDim2.new(1, 0, 0, 48), tostring(value), false
		row.TextSize, row.LayoutOrder, row.Parent = 18, order, body
		row.FocusLost:Connect(function()
			changed(tonumber(row.Text))
		end)
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
	local unsubscribe = ctx.onSnapshot(function(snapshot)
		local state = snapshot.market
		if not state then
			status.Text = text(
				"Market is loading. Gather goods, then return to list or browse bundles.",
				"장터를 불러오는 중입니다. 재료를 채집한 뒤 돌아와 판매하거나 구매하세요."
			)
			return
		end
		local signature = Ledger.canonical(state)
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
			end)
			input(draft.price, function(value)
				draft.price = math.clamp(math.floor(value or 1), 1, 1000000)
			end)
			button(
				Locale.text(ctx.locale, "trade.bundle.list")
					.. ": "
					.. ctx.icons.item(item.catalogId).text
					.. " x"
					.. tostring(draft.quantity),
				function()
					send("list", { id, draft.quantity, draft.price })
				end
			)
		end
		if sellable == 0 then
			label(
				text(
					"No tradable goods yet. Gather resources and bring them to the harbor.",
					"판매할 재료가 없습니다. 재료를 채집하여 항구로 가져오세요."
				)
			)
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
		for _, id in state.catalogIds do
			button(ctx.icons.item(id).text, function()
				send("browse", { id, state.page })
			end)
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
		if player == game:GetService("Players").LocalPlayer and value:GetAttribute("ForgeMarket") then
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
