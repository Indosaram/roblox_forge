--!strict
-- Pure view model + strings for the camp panel (specced under Lune; CampPanel owns the
-- Roblox instances). Items offered for giving come from the player's own inventory
-- snapshot; visit candidates come from the camp slice. Strings mirror
-- games/robango-island/locale/strings.csv (camp_* keys).
local HudModel = require("./SurvivalHUDModel")
local HudLocale = require("./SurvivalHUDLocale")
local M = {}

export type Row = { id: string, label: string, delivered: number, need: number, locked: boolean, costs: { any } }
export type Host = { id: string, name: string }
export type Choice = { itemId: string, label: string, available: number }
export type Model = {
	role: string,
	rung: number,
	rungs: number,
	version: number,
	rows: { Row },
	pass: number?,
	passHost: string?,
	hosts: { Host },
	visitors: number,
	cooldowns: number,
	facilities: { string },
}

M.MAX_QUANTITY = 1000

local STRINGS: { [string]: { string } } = {
	camp_title = { "Camp", "캠프" },
	camp_rung = { "Rung", "단계" },
	camp_contribute = { "Give", "기부" },
	camp_complete = { "Finish project", "프로젝트 완료" },
	camp_locked = { "Locked", "잠김" },
	camp_visitor = { "Visitor pass", "방문 허가" },
	camp_visitor_none = { "No pass", "허가 없음" },
	camp_cooldown = { "Rejoin wait", "재가입 대기" },
	camp_facility = { "Facility", "시설" },
	camp_visit = { "Visit", "방문" },
	camp_help = { "Help", "돕기" },
	camp_visitors = { "Visitors", "방문자" },
	camp_item = { "Item", "아이템" },
	camp_quantity = { "Amount", "수량" },
	camp_less = { "-", "-" },
	camp_more = { "+", "+" },
	camp_no_items = { "Nothing to give", "줄 아이템 없음" },
	camp_not_friend = { "Only friends can visit", "친구만 방문할 수 있어요" },
	camp_no_pass = { "Ask to visit first", "먼저 방문을 요청하세요" },
	camp_expired = { "Visit pass expired", "방문 허가가 만료됐어요" },
	camp_refused = { "Camp action refused", "캠프 작업이 거절됐어요" },
}
local REFUSALS: { [string]: string } = {
	NOT_FRIEND = "camp_not_friend",
	NO_PASS = "camp_no_pass",
	VISIT_EXPIRED = "camp_expired",
}

function M.text(locale: string, key: string): string
	local entry = STRINGS[key]
	assert(entry, "UNKNOWN_CAMP_STRING")
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end
function M.keys(): { string }
	local keys = {}
	for key in STRINGS do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end
function M.refusal(locale: string, reason: string?): string
	return M.text(locale, REFUSALS[reason or ""] or "camp_refused")
end

-- Items the player may give: the carried bag's unreserved stacks, ordered by id.
function M.choices(locale: string, packet: any): { Choice }
	local result: { Choice } = {}
	local snapshots = if type(packet) == "table" then packet.snapshots else nil
	local genre = if type(snapshots) == "table" then snapshots["survival-coop"] else nil
	if type(genre) ~= "table" then
		return result
	end
	for _, row in HudModel.items(HudModel.bag(genre)) do
		if row.available > 0 then
			table.insert(result, {
				itemId = row.item.itemId,
				label = HudLocale.text(locale, row.item.catalogId),
				available = row.available,
			})
		end
	end
	return result
end

-- The chosen stack if it still exists, else the first one (nil when the bag is empty).
function M.select(choices: { Choice }, current: string?): Choice?
	for _, choice in choices do
		if choice.itemId == current then
			return choice
		end
	end
	return choices[1]
end

function M.cycle(choices: { Choice }, current: string?, step: number): string?
	if #choices == 0 then
		return nil
	end
	local index = 1
	for position, choice in choices do
		if choice.itemId == current then
			index = position
		end
	end
	return choices[(index - 1 + step) % #choices + 1].itemId
end

function M.clamp(quantity: number, available: number): number
	return math.clamp(math.floor(quantity), 1, math.max(1, math.min(available, M.MAX_QUANTITY)))
end

function M.costLine(locale: string, row: Row, names: { [string]: string }?): string
	local parts = {}
	for _, cost in row.costs do
		local name = names and names[cost.item] or HudLocale.text(locale, cost.item)
		table.insert(parts, `{name} {cost.delivered}/{cost.need}`)
	end
	return table.concat(parts, " · ")
end

-- Pure view model; `now` only decides pass status, the packet only names hosts.
function M.model(slice: any, now: number, packet: any?): Model?
	if type(slice) ~= "table" then
		return nil
	end
	local names: { [string]: string } = {}
	for _, entry in if type(packet) == "table" and type(packet.roster) == "table" then packet.roster else {} do
		names[entry.id] = entry.name
	end
	local hosts: { Host } = {}
	for id in slice.hosts or {} do
		table.insert(hosts, { id = id, name = names[id] or id })
	end
	table.sort(hosts, function(left, right)
		return left.id < right.id
	end)
	local empty = {
		role = slice.role,
		rung = 0,
		rungs = 0,
		version = 0,
		rows = {},
		hosts = hosts,
		visitors = 0,
		cooldowns = 0,
		facilities = {},
	}
	if type(slice.ladder) ~= "table" then
		return if slice.role == "guest" and #hosts > 0 then empty else nil
	end
	local rows: { Row } = {}
	local projects: { any } = {}
	for _, project in slice.ladder.projects do
		table.insert(projects, project)
	end
	table.sort(projects, function(left, right)
		return left.id < right.id
	end)
	for _, project in projects do
		local progress = slice.active[project.id]
		local delivered, need, costs = 0, 0, {}
		for _, cost in project.cost do
			local given = if progress then math.min(progress.delivered[cost.item] or 0, cost.quantity) else 0
			need += cost.quantity
			delivered += given
			table.insert(costs, { item = cost.item, delivered = given, need = cost.quantity })
		end
		table.insert(rows, {
			id = project.id,
			label = project.id,
			delivered = delivered,
			need = need,
			locked = slice.rung < project.rung - 1,
			costs = costs,
		})
	end
	local facilities: { string } = {}
	for facility in slice.facilities do
		table.insert(facilities, facility)
	end
	table.sort(facilities)
	local cooldowns = 0
	for _ in slice.cooldowns or {} do
		cooldowns += 1
	end
	local visitors = 0
	for _, pass in slice.passes or {} do
		if pass.expiresAt > now then
			visitors += 1
		end
	end
	local pass: number? = nil
	local passHost: string? = nil
	if slice.pass and slice.pass.expiresAt > now then
		pass = slice.pass.expiresAt - now
		passHost = slice.pass.hostId
	end
	empty.rung, empty.rungs, empty.version = slice.rung, #slice.ladder.rungs, slice.version
	empty.rows, empty.pass, empty.passHost = rows, pass, passHost
	empty.visitors, empty.cooldowns, empty.facilities = visitors, cooldowns, facilities
	return empty
end

return M
