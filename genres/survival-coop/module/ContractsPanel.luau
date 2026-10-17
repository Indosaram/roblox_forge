--!strict
-- ContractsPanel: contract board (accept, deliver, reward preview, trust per
-- faction) plus the tutorial objective tracker (current step, skip arrival).
-- Pure view over snapshot.survivalExtensions.contracts; every button issues a
-- durable command through ctx.send and the server stays authoritative.
local HudLocale = require("./SurvivalHUDLocale")
local M = {}

local PREFIX = "survival-coop:"

-- Mirrors the `ct_*` rows in the pack's locale/strings.csv (key with "." and "-" as "_").
local STRINGS: { [string]: { en: string, ko: string } } = {
	contracts_title = { en = "Contracts", ko = "계약" },
	contracts_accept = { en = "Accept", ko = "수락" },
	contracts_deliver = { en = "Deliver", ko = "납품" },
	contracts_accepted = { en = "Accepted", ko = "수락함" },
	contracts_reward = { en = "Reward", ko = "보상" },
	contracts_trust = { en = "Trust", ko = "신뢰도" },
	contracts_tier = { en = "Tier", ko = "단계" },
	contracts_empty = { en = "No contracts available", ko = "받을 수 있는 계약이 없어요" },
	contracts_refused = { en = "Refused: ", ko = "거절됨: " },
	tutorial_title = { en = "Objective", ko = "목표" },
	tutorial_skip = { en = "Skip arrival", ko = "도착 장면 건너뛰기" },
	tutorial_done = { en = "Tutorial complete", ko = "튜토리얼 완료" },
	["tutorial.arrive"] = { en = "Arrive on the island", ko = "섬에 도착하세요" },
	["tutorial.gather"] = { en = "Gather a resource", ko = "자원을 채집하세요" },
	["tutorial.craft-stone-axe"] = { en = "Craft a stone axe", ko = "돌도끼를 만드세요" },
	["tutorial.declare-settlement"] = { en = "Place your settlement", ko = "정착지를 세우세요" },
	["tutorial.accept-contract"] = { en = "Accept the first contract", ko = "첫 계약을 수락하세요" },
	["tutorial.deliver-contract"] = { en = "Deliver the first contract", ko = "첫 계약을 납품하세요" },
	["faction.route-surveyors"] = { en = "Route Survey Society", ko = "노선 측량 협회" },
	["faction.artisan-guilds"] = { en = "Artisan Guild Union", ko = "장인 길드 연합" },
	["faction.island-ecology"] = { en = "Island Ecology Trust", ko = "섬 생태 신탁" },
}

function M.text(locale: string, key: string): string
	local entry = STRINGS[key]
	if entry == nil then
		return key
	end
	return if string.sub(locale, 1, 2) == "ko" then entry.ko else entry.en
end
M.STRINGS = STRINGS

--- Pure view model so the layout is testable without Instances.
function M.model(locale: string, state: any): any
	local rows: { any } = {}
	for _, offer in state.offers or {} do
		local reward: { string } = {}
		for _, item in offer.reward do
			table.insert(reward, string.format("%s x%d", HudLocale.text(locale, item.item), item.quantity))
		end
		table.insert(rows, {
			id = offer.id,
			accepted = offer.accepted,
			action = if offer.accepted then "contract-deliver" else "contract-accept",
			label = if offer.accepted then M.text(locale, "contracts_deliver") else M.text(locale, "contracts_accept"),
			reward = table.concat(reward, ", "),
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
			then M.text(locale, "tutorial_done")
			else M.text(locale, tutorial.hint or "tutorial.arrive"),
		canSkip = tutorial.complete ~= true and tutorial.step == "arrive",
	}
end

function M.factory(ctx: any): any
	local components, theme = ctx.ui.components, ctx.ui.theme
	local locale = ctx.locale
	local players = game:GetService("Players")
	local gui = Instance.new("ScreenGui")
	gui.Name = "ContractsPanel"
	gui.ResetOnSpawn = false
	gui.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
	local sheet = components.modalSheet(theme, { name = "ContractBoard", title = M.text(locale, "contracts_title") })
	sheet.frame.Parent = gui
	local tracker = components.label(theme, {
		text = "",
		size = UDim2.fromOffset(260, 44),
		position = UDim2.new(1, -276, 0, 12),
		parent = gui,
		chip = true,
	})
	local skip = components.button(theme, {
		text = M.text(locale, "tutorial_skip"),
		size = UDim2.fromOffset(180, 44),
		position = UDim2.new(1, -196, 0, 62),
		parent = gui,
		onClick = function()
			ctx.send(PREFIX .. "tutorial-skip-arrival", {})
		end,
	})
	skip.Visible = false
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

	local function render(state: any)
		local view = M.model(locale, state)
		tracker.Text = M.text(locale, "tutorial_title") .. ": " .. view.objective
		skip.Visible = view.canSkip
		for _, child in sheet.scroll:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local order = 0
		local function add(text: string)
			order += 1
			local line =
				components.label(theme, { text = text, size = UDim2.new(1, -16, 0, 28), parent = sheet.scroll })
			line.LayoutOrder = order
		end
		for _, faction in view.factions do
			add(faction.text)
		end
		if #view.rows == 0 then
			add(M.text(locale, "contracts_empty"))
		end
		for _, row in view.rows do
			add(
				string.format(
					"%s  |  %s: %s  |  +%d %s",
					row.id,
					M.text(locale, "contracts_reward"),
					row.reward,
					row.trust,
					M.text(locale, "contracts_trust")
				)
			)
			order += 1
			local button = components.button(theme, {
				text = row.label,
				size = UDim2.new(1, -16, 0, 44),
				parent = sheet.scroll,
				onClick = function()
					local result = ctx.send(PREFIX .. row.action, { row.id })
					if type(result) == "table" and result.ok == false then
						tracker.Text = M.text(locale, "contracts_refused") .. tostring(result.reason)
					end
				end,
			})
			button.LayoutOrder = order
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
