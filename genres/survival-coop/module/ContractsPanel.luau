--!strict
-- ContractsPanel: contract board + tutorial tracker; buttons send durable commands.
local HudLocale = require("./SurvivalHUDLocale")
local M = {}

local PREFIX = "survival-coop:"

-- Mirrors the pack's `ct_*` locale rows.
local STRINGS: { [string]: { en: string, ko: string } } = {
	contracts_title = { en = "Contracts", ko = "계약" },
	contracts_accept = { en = "Accept", ko = "수락" },
	contracts_deliver = { en = "Deliver", ko = "납품" },
	contracts_accepted = { en = "Accepted", ko = "수락함" },
	contracts_reward = { en = "Reward", ko = "보상" },
	contracts_coins = { en = "Shellmoney %d", ko = "조개돈 %d" },
	contracts_trust = { en = "Trust", ko = "신뢰도" },
	contracts_tier = { en = "Tier", ko = "단계" },
	contracts_empty = { en = "No contracts available", ko = "받을 수 있는 계약이 없어요" },
	contracts_refused = { en = "Refused: ", ko = "거절됨: " },
	contracts_reason_insufficient = {
		en = "Not enough items to deliver yet.",
		ko = "납품할 아이템이 아직 부족해요.",
	},
	contracts_reason_carry = {
		en = "Carry %s x%d in your bag (have %d).",
		ko = "가방에 %s %d개를 들고 오세요 (현재 %d개).",
	},
	contracts_reason_bag_full = {
		en = "Your bag is full. Make room first.",
		ko = "가방이 가득 찼어요. 공간을 비우세요.",
	},
	contracts_reason_pending = {
		en = "Saving... try again in a moment.",
		ko = "저장 중이에요. 잠시 후 다시 시도하세요.",
	},
	contracts_reason_order = {
		en = "Complete the earlier first-day contract first.",
		ko = "앞선 첫날 계약을 먼저 완료하세요.",
	},
	contracts_reason_other = { en = "That did not work. Try again.", ko = "잘 안 됐어요. 다시 시도하세요." },
	tutorial_title = { en = "Objective", ko = "목표" },
	tutorial_skip = { en = "Skip arrival", ko = "도착 장면 건너뛰기" },
	tutorial_done = { en = "Tutorial complete", ko = "튜토리얼 완료" },
	["tutorial.arrive"] = { en = "Arrive on the island", ko = "섬에 도착하세요" },
	["tutorial.gather"] = {
		en = "Gather a resource: walk up and press E",
		ko = "자원을 채집하세요: 다가가서 E",
	},
	["tutorial.craft-stone-axe"] = {
		en = "Craft an axe: press C (Menu > Craft); the pinned recipe is first",
		ko = "도끼를 만드세요: C 키 (메뉴 > 제작), 고정된 제작법이 맨 위",
	},
	["tutorial.declare-settlement"] = {
		en = "Place your settlement: store wood in the warehouse (I), then press B to build",
		ko = "정착지를 세우세요: 가방(I)에서 창고에 나무 보관 후 B 키로 건설",
	},
	["tutorial.accept-contract"] = {
		en = "Accept the first contract: Menu > Contracts",
		ko = "첫 계약을 수락하세요: 메뉴 > 계약",
	},
	["tutorial.deliver-contract"] = {
		en = "Deliver the first contract: Menu > Contracts > Deliver",
		ko = "첫 계약을 납품하세요: 메뉴 > 계약 > 납품",
	},
	-- After the tutorial the onboarding chain points at route 1 (spec: guides raise the grade).
	["tutorial.next-route"] = {
		en = "Next: raise island grade with guides (Menu > Island rank), then open Menu > Routes",
		ko = "다음: 가이드로 섬 개발 등급 올리기 (메뉴 > 섬 등급), 그다음 메뉴 > 항로",
	},
	["faction.route-surveyors"] = { en = "Route Survey Society", ko = "노선 측량 협회" },
	["faction.artisan-guilds"] = { en = "Artisan Guild Union", ko = "장인 길드 연합" },
	["faction.island-ecology"] = { en = "Island Ecology Trust", ko = "섬 생태 신탁" },
}

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
	return if string.sub(locale, 1, 2) == "ko" then entry.ko else entry.en
end
M.STRINGS = STRINGS

--- Pure view model so the layout is testable without Instances.
function M.model(locale: string, state: any, names: { [string]: string }?): any
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
		objective = if tutorial.complete
			then M.text(locale, "tutorial.next-route")
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
	local rendered: string?, notice: string?, objective = nil, nil, ""
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
		notice, status.Text, status.Visible = text, text or "", text ~= nil
		sheet.scroll.Size = UDim2.new(1, 0, 1, if text then -100 else -44)
		tracker:SetAttribute("ForgeContractsNotice", text ~= nil)
		tracker.Text = text or objective
	end
	local function render(state: any)
		local view = M.model(locale, state, ctx.names)
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
					setNotice(
						if type(result) == "table" and result.ok == false
							then M.refusal(locale, result.reason, result.data, ctx.names)
							else nil
					)
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
		local state = snapshot.contracts
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
