--!strict
-- Client shop panel: lists the monetization catalog from snapshot.survivalExtensions.monetization
-- and sends the server-side prompt action on Buy. The server owns every prompt/grant decision;
-- this panel only renders rows (price text + buy button) and a localized refusal message.
-- Strings mirror games/robango-island/locale/strings.csv keys (shop_*).
local M = {}

local PROMPT = "shop-prompt"
local SYNC = "shop-sync"

local strings: { [string]: { string } } = {
	shop_title = { "Shop", "상점" },
	shop_buy = { "Buy", "구매" },
	shop_owned = { "Owned", "보유 중" },
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
	PRODUCT_NOT_CONFIGURED = "shop_unavailable",
	SUBSCRIPTION_INELIGIBLE = "shop_ineligible",
	ALREADY_OWNED = "shop_owned",
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
	local status = ui.components.label(theme, { text = "", size = UDim2.new(1, 0, 0, 28), parent = sheet.content })
	status.Name = "ShopStatus"
	local rows = Instance.new("Frame")
	rows.Name, rows.BackgroundTransparency, rows.Size, rows.Parent = "ShopRows", 1, UDim2.fromScale(1, 0), sheet.content
	rows.AutomaticSize = Enum.AutomaticSize.Y
	local layout = Instance.new("UIListLayout")
	layout.Padding, layout.Parent = UDim.new(0, 6), rows
	local function render(snapshot: { [string]: any })
		for _, child in rows:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		local shop = snapshot.monetization
		if type(shop) ~= "table" then
			return
		end
		for index, row in shop.catalog do
			local line = Instance.new("Frame")
			line.Name, line.BackgroundTransparency, line.Size = "Row" .. index, 1, UDim2.new(1, 0, 0, 48)
			line.LayoutOrder, line.Parent = index, rows
			ui.components.label(theme, {
				text = row.name .. "  " .. M.text(ctx.locale, "shop_price", row.price),
				size = UDim2.fromScale(0.62, 1),
				parent = line,
			})
			ui.components.button(theme, {
				text = M.text(ctx.locale, if row.owned then "shop_owned" else "shop_buy"),
				size = UDim2.fromScale(0.36, 1),
				position = UDim2.fromScale(0.64, 0),
				parent = line,
				onClick = function()
					if row.owned then
						return
					end
					local result = ctx.send(PROMPT, { row.key })
					status.Text = if result.ok then "" else M.refusal(ctx.locale, result.reason)
				end,
			})
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
