--!strict
-- ContractsPanel: contract board + tutorial tracker; buttons send durable commands.
local HudLocale = require("./SurvivalHUDLocale")
local Text = require("./CharacterText")
local M = {}
local EARLY = { arrive = true, gather = true, ["craft-stone-axe"] = true }

local PREFIX = "survival-coop:"
local PackLocale = require("./PackLocale")

-- Rows live in the pack's locale table as ctr.<key> (games/robango-island/locale/strings.csv).
local STRINGS: { [string]: { string } } = PackLocale.rows({}, { "ctr." })

--- Player sentence for a refusal (never the raw code).
function M.refusal(locale: string, reason: string?, short: any?, names: { [string]: string }?): string
	if reason == "INSUFFICIENT_ITEMS" and type(short) == "table" then
		local name = names and names[short.item] or HudLocale.text(locale, short.item)
		return string.format(M.text(locale, "contracts_reason_carry"), name, short.need, short.have)
	end
	local key = if reason == "INSUFFICIENT_ITEMS"
		then "contracts_reason_insufficient"
		elseif reason == "BAG_FULL" then "contracts_reason_bag_full"
		elseif reason == "CONTRACT_PENDING" or reason == "CHARGE_PENDING" then "contracts_reason_pending"
		elseif reason == "OUT_OF_ORDER" then "contracts_reason_order"
		else "contracts_reason_other"
	return M.text(locale, key)
end

function M.text(locale: string, key: string): string
	local entry = STRINGS[key]
	if entry == nil then
		return key
	end
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end
M.STRINGS = STRINGS

-- Objective hints that name a keyboard key have a touch variant (<hint>_touch) without it.
local TOUCH_HINTS = { ["tutorial.gather"] = true }

--- Pure view model so the layout is testable without Instances. `touch` picks the key-free hint.
function M.model(locale: string, state: any, names: { [string]: string }?, guide: string?, touch: boolean?): any
	local function itemName(id: string): string
		return if names and names[id] then names[id] else HudLocale.text(locale, id)
	end
	local rows: { any } = {}
	for _, offer in state.offers or {} do
		local reward: { string } = {}
		for _, item in offer.reward do
			table.insert(reward, string.format("%s x%d", itemName(item.item), item.quantity))
		end
		if type(offer.coins) == "number" and offer.coins > 0 then
			table.insert(reward, string.format(M.text(locale, "contracts_coins"), offer.coins))
		end
		local deliver: { string } = {}
		for _, item in offer.deliver or {} do
			table.insert(deliver, string.format("%s x%d", itemName(item.item), item.quantity))
		end
		table.insert(rows, {
			id = offer.id,
			accepted = offer.accepted,
			action = if offer.accepted then "contract-deliver" else "contract-accept",
			label = if offer.accepted then M.text(locale, "contracts_deliver") else M.text(locale, "contracts_accept"),
			reward = table.concat(reward, ", "),
			goal = table.concat(deliver, ", "),
			faction = if offer.faction then M.text(locale, "faction." .. offer.faction) else nil,
			trust = offer.trust,
		})
	end
	local factions: { any } = {}
	for id, trust in state.trust or {} do
		table.insert(factions, {
			id = id,
			name = M.text(locale, "faction." .. id),
			text = string.format(
				"%s: %d (%s %d)",
				M.text(locale, "faction." .. id),
				trust.value,
				M.text(locale, "contracts_tier"),
				trust.tier
			),
		})
	end
	table.sort(factions, function(a, b)
		return a.id < b.id
	end)
	local tutorial = state.tutorial or {}
	return {
		rows = rows,
		factions = factions,
		objective = if guide and not EARLY[tutorial.step]
			then guide
			elseif tutorial.complete then M.text(locale, "tutorial.next-route")
			elseif touch and TOUCH_HINTS[tutorial.hint] then M.text(locale, tutorial.hint .. "_touch")
			else M.text(locale, tutorial.hint or "tutorial.arrive"),
		canSkip = tutorial.complete ~= true and tutorial.step == "arrive",
	}
end

--- Identity of what the board renders.
function M.renderKey(view: any): string
	local parts = { view.objective, tostring(view.canSkip) }
	for _, faction in view.factions do
		table.insert(parts, faction.text)
	end
	for _, row in view.rows do
		table.insert(
			parts,
			table.concat({
				row.id,
				tostring(row.accepted),
				row.label,
				row.action,
				tostring(row.goal),
				tostring(row.reward),
				tostring(row.trust),
				tostring(row.faction),
			}, "\31")
		)
	end
	return table.concat(parts, "\30")
end

function M.factory(ctx: any): any
	local components, theme = ctx.ui.components, ctx.ui.theme.default
	local locale = ctx.locale
	local players = game:GetService("Players")
	local touch = ctx.touch or game:GetService("UserInputService").TouchEnabled == true
	local gui = Instance.new("ScreenGui")
	gui.Name = "ContractsPanel"
	gui.ResetOnSpawn = false
	gui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local sheet = components.modalSheet(theme, { name = "ContractBoard", title = M.text(locale, "contracts_title") })
	sheet.frame.Parent = gui
	if ctx.fitSheet then
		ctx.fitSheet(sheet.frame)
	end
	sheet.close.Activated:Connect(function()
		sheet.frame.Visible = false
	end)
	-- Tracker and skip sit in the dock column when one exists.
	local slot: Instance = ctx.objectiveSlot or gui
	local docked = ctx.objectiveSlot ~= nil
	local tracker = components.label(theme, {
		text = M.text(locale, "tutorial_title") .. ": " .. M.text(locale, "tutorial.arrive"),
		size = if docked then UDim2.fromScale(1, 0) else UDim2.fromOffset(260, 44),
		position = if docked then nil else UDim2.new(1, -276, 0, 12),
		parent = slot,
		chip = true,
		textSize = if docked then 14 else nil,
	})
	tracker.Name, tracker.LayoutOrder = "ObjectiveTracker", 1
	if docked then
		tracker.AutomaticSize = Enum.AutomaticSize.Y
		local pad = tracker:FindFirstChildOfClass("UIPadding")
		if pad then
			pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
		end
	end
	local skip = components.button(theme, {
		text = M.text(locale, "tutorial_skip"),
		size = if docked then UDim2.new(1, 0, 0, 44) else UDim2.fromOffset(180, 44),
		position = if docked then nil else UDim2.new(1, -196, 0, 62),
		parent = slot,
		onClick = function()
			ctx.send(PREFIX .. "tutorial-skip-arrival", {})
		end,
	})
	skip.Visible = false
	skip.Name, skip.LayoutOrder = "SkipArrival", 2
	if ctx.dock then
		ctx.dock({
			id = "contracts",
			label = M.text(locale, "contracts_title"),
			order = 1,
			setOpen = function(open: boolean)
				sheet.frame.Visible = open
			end,
			isOpen = function()
				return sheet.frame.Visible
			end,
		})
	end
	local toggle = components.button(theme, {
		text = M.text(locale, "contracts_title"),
		size = UDim2.fromOffset(120, 44),
		position = UDim2.new(1, -136, 0, 112),
		parent = gui,
		onClick = function()
			sheet.frame.Visible = not sheet.frame.Visible
		end,
	})
	toggle.Name = "ContractsToggle"
	toggle.Visible = ctx.dock == nil

	-- Rebuild only on content change (a rebuild ate a mid-click press, QA step 74).
	local rendered: string?, notice: string?, objective, flash: string? = nil, nil, "", nil
	-- Refusals also show in the open sheet: the dock tracker is hidden under it.
	local status = components.label(theme, {
		text = "",
		size = UDim2.new(1, -16, 0, 44),
		position = UDim2.new(0, 8, 1, -52),
		parent = sheet.frame,
		chip = true,
		textSize = 13,
	})
	status.Name, status.Visible, status.ZIndex = "Notice", false, 53
	local function setNotice(text: string?)
		notice = text
		local line = text or flash
		status.Text, status.Visible = line or "", line ~= nil
		sheet.scroll.Size = UDim2.new(1, 0, 1, if line then -100 else -44)
		tracker:SetAttribute("ForgeContractsNotice", line ~= nil)
		tracker.Text = line or objective
	end
	-- Success lines (delivery, guide complete) show for a few seconds.
	local function flashFor(text: string)
		flash = text
		setNotice(notice)
		task.delay(5, function()
			if flash == text then
				flash = nil
				setNotice(notice)
			end
		end)
	end
	local guide: string?, seen = nil, {}
	local function render(state: any)
		local view = M.model(locale, state, ctx.names, guide, touch)
		local key = M.renderKey(view)
		objective = M.text(locale, "tutorial_title") .. ": " .. view.objective
		-- A refusal stays until the board changes (vitals ticks erased it).
		setNotice(if key == rendered then notice else nil)
		skip.Visible = view.canSkip
		if key == rendered then
			return
		end
		rendered = key
		for _, child in sheet.scroll:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local order = 0
		local function add(text: string, lines: number?)
			order += 1
			local line = components.label(
				theme,
				{ text = text, size = UDim2.new(1, -16, 0, 20 * (lines or 1) + 4), parent = sheet.scroll }
			)
			line.Name = "Line-" .. order
			line.TextWrapped, line.LayoutOrder = true, order
		end
		if #view.rows == 0 then
			add(M.text(locale, "contracts_empty"))
		end
		for _, row in view.rows do
			add(
				string.format(
					"%s%s: %s\n%s: %s  ·  %s +%d",
					if row.faction then row.faction .. " - " else "",
					M.text(locale, "contracts_deliver"),
					if row.goal ~= "" then row.goal else row.id,
					M.text(locale, "contracts_reward"),
					row.reward,
					M.text(locale, "contracts_trust"),
					row.trust
				),
				2
			)
			order += 1
			local button = components.button(theme, {
				text = row.label,
				size = UDim2.new(1, -16, 0, 44),
				parent = sheet.scroll,
				onClick = function()
					local result = ctx.send(PREFIX .. row.action, { row.id })
					local ok = type(result) ~= "table" or result.ok ~= false
					setNotice(if ok then nil else M.refusal(locale, result.reason, result.data, ctx.names))
					if ok and row.accepted then
						flashFor(string.format(M.text(locale, "contracts_delivered"), row.reward))
					end
				end,
			})
			-- Unique names: QA addresses rows and lines by name.
			button.Name = (if row.accepted then "Deliver-" else "Accept-") .. row.id
			button.LayoutOrder = order
		end
		for _, faction in view.factions do
			add(faction.text)
		end
	end

	local unsubscribe = ctx.onSnapshot(function(snapshot)
		local state, ch = snapshot.contracts, snapshot.character
		guide = if ctx.content and ch then Text.guideObjective(locale, ctx.content, ch, ctx.names or {}) else nil
		local done = Text.newGuides(locale, seen, ch)
		if done then
			flashFor(done)
		end
		if type(state) == "table" then
			render(state)
		end
	end)
	return {
		destroy = function()
			unsubscribe()
			gui:Destroy()
		end,
	}
end

return M
