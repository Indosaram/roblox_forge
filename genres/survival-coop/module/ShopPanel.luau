--!strict
-- Client shop panel: lists the monetization catalog from snapshot.survivalExtensions.monetization
-- and sends the server-side prompt action on Buy. The server owns every prompt/grant decision;
-- this panel only renders rows (price text + buy button + what the purchase gives) and a
-- localized refusal message.
-- Strings mirror games/robango-island/locale/strings.csv keys (shop_*).
local M = {}

-- Durable ids are namespaced: the server's action list carries "survival-coop:<id>".
local PROMPT = "survival-coop:shop-prompt"
local SYNC = "survival-coop:shop-sync"
local SELECT = "survival-coop:skin-select"
-- Row geometry (ui-layout.spec mirrors these): a 48px name/price + buy strip, then a
-- full-width description line of what the purchase grants.
M.ROW_HEIGHT = 48
M.DESCRIPTION_HEIGHT = 40
M.DESCRIPTION_TEXT_SIZE = 14

local strings: { [string]: { string } } = {
	shop_title = { "Shop", "상점" },
	shop_buy = { "Buy", "구매" },
	shop_owned = { "Owned", "보유 중" },
	shop_skin_select = { "Select appearance", "외형 선택" },
	shop_price = { "%d Robux", "%d 로벅스" },
	shop_unavailable = { "Not available yet", "아직 구매할 수 없어요" },
	shop_ineligible = {
		"Subscriptions are not available for this account",
		"이 계정은 구독을 이용할 수 없어요",
	},
	shop_failed = {
		"Purchase could not start. Try again later",
		"구매를 시작하지 못했어요. 잠시 후 다시 시도하세요",
	},
}
local refusals: { [string]: string } = {
	PRODUCT_EFFECT_UNAVAILABLE = "shop_unavailable",
	PRODUCT_NOT_CONFIGURED = "shop_unavailable",
	SUBSCRIPTION_INELIGIBLE = "shop_ineligible",
	ALREADY_OWNED = "shop_owned",
	SKIN_NOT_OWNED = "shop_unavailable",
}

--- Pure text lookup (specced): `key` falls back to English; `%d` is filled with `amount`.
function M.text(locale: string, key: string, amount: number?): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	local text = if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
	if amount ~= nil then
		text = string.format(text, amount)
	end
	return text
end

--- Maps a server refusal reason to its localized message.
function M.refusal(locale: string, reason: string?): string
	return M.text(locale, refusals[reason or ""] or "shop_failed")
end

function M.factory(ctx: any): { destroy: () -> () }?
	local ui = ctx.ui
	local theme = ui.theme.default
	local players = game:GetService("Players")
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeShop", false, 14, false
	gui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local sheet = ui.components.modalSheet(theme, {
		name = "ShopSheet",
		title = M.text(ctx.locale, "shop_title"),
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
			id = "shop",
			label = M.text(ctx.locale, "shop_title"),
			order = 6,
			setOpen = function(open: boolean)
				gui.Enabled = open
			end,
			isOpen = function()
				return gui.Enabled
			end,
		})
	end
	local status = ui.components.label(theme, { text = "", size = UDim2.new(1, 0, 0, 28), parent = sheet.scroll })
	status.Name, status.Visible = "ShopStatus", false
	status:GetPropertyChangedSignal("Text"):Connect(function()
		status.Visible = status.Text ~= ""
	end)
	local rows = Instance.new("Frame")
	rows.Name, rows.BackgroundTransparency, rows.Size, rows.Parent = "ShopRows", 1, UDim2.fromScale(1, 0), sheet.scroll
	rows.AutomaticSize = Enum.AutomaticSize.Y
	local layout = Instance.new("UIListLayout")
	layout.Padding, layout.Parent = UDim.new(0, 6), rows
	-- Rows are kept and updated in place. Rebuilding them on every snapshot replaced the Buy
	-- button between a player's press and release (snapshots arrive several times a second),
	-- so a tap could land on a destroyed button and nothing happened (live Studio capture).
	local built: {
		[string]: { line: Frame, label: TextLabel, detail: TextLabel, button: TextButton, row: any },
	} =
		{}
	local function render(snapshot: { [string]: any })
		local shop = snapshot.monetization
		if type(shop) ~= "table" then
			return
		end
		local seen: { [string]: boolean } = {}
		for index, row in shop.catalog do
			seen[row.key] = true
			local entry = built[row.key]
			if entry == nil then
				local line = Instance.new("Frame")
				line.Name, line.BackgroundTransparency = "Row" .. index, 1
				line.Size = UDim2.new(1, 0, 0, M.ROW_HEIGHT + M.DESCRIPTION_HEIGHT)
				line.Parent = rows
				local label = ui.components.label(theme, {
					text = "",
					size = UDim2.new(0.62, 0, 0, M.ROW_HEIGHT),
					parent = line,
				})
				local detail = ui.components.label(theme, {
					text = "",
					size = UDim2.new(1, 0, 0, M.DESCRIPTION_HEIGHT),
					position = UDim2.fromOffset(0, M.ROW_HEIGHT),
					textSize = M.DESCRIPTION_TEXT_SIZE,
					parent = line,
				})
				detail.Name = "Description"
				local created: any = nil
				local button = ui.components.button(theme, {
					text = "",
					size = UDim2.new(0.36, 0, 0, M.ROW_HEIGHT),
					position = UDim2.fromScale(0.64, 0),
					parent = line,
					onClick = function()
						local current = created.row
						if current.effectImplemented ~= true or not current.configured then
							status.Text = M.refusal(ctx.locale, "PRODUCT_EFFECT_UNAVAILABLE")
							return
						end
						if current.owned then
							if current.eligible and current.skin then
								local result = ctx.send(SELECT, { current.skin })
								status.Text = if result.ok then "" else M.refusal(ctx.locale, result.reason)
							end
							return
						end
						local result = ctx.send(PROMPT, { current.key })
						status.Text = if result.ok then "" else M.refusal(ctx.locale, result.reason)
					end,
				})
				button.Name = "Buy-" .. row.key
				created = { line = line, label = label, detail = detail, button = button, row = row }
				entry = created
				built[row.key] = created
			end
			local current = assert(entry, "shop row")
			current.row = row
			current.line.LayoutOrder = index
			-- A pack can localize listing names by key ("shop:<key>"); the catalog name is the fallback.
			current.label.Text = (
				if ctx.names and ctx.names["shop:" .. row.key] then ctx.names["shop:" .. row.key] else row.name
			)
				.. "  "
				.. M.text(ctx.locale, "shop_price", row.price)
			-- What the purchase gives ("shopdesc:<key>", locale/strings.csv shop_desc_*).
			current.detail.Text = if ctx.names then ctx.names["shopdesc:" .. row.key] or "" else ""
			current.button.Text = M.text(
				ctx.locale,
				if row.eligible then "shop_skin_select" elseif row.owned then "shop_owned" else "shop_buy"
			)
			current.button.Interactable = row.effectImplemented == true
				and row.configured == true
				and (not row.owned or row.eligible == true)
			current.button.BackgroundTransparency = if current.button.Interactable then 0 else 0.7
		end
		for key, entry in built do
			if not seen[key] then
				entry.line:Destroy()
				built[key] = nil
			end
		end
	end
	local unsubscribe = ctx.onSnapshot(render)
	task.spawn(function()
		ctx.send(SYNC, {})
	end)
	local input = game:GetService("UserInputService")
	local keyConnection = input.InputBegan:Connect(function(event, processed)
		if not processed and event.KeyCode == Enum.KeyCode.P then
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
