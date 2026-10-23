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
	camp_given = { "Gave %s x%d: %s %d/%d", "%s %d개 기부: %s %d/%d" },
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
	camp_forbidden = {
		"Only camp members can give to camp projects",
		"캠프 구성원만 프로젝트에 기부할 수 있어요",
	},
	camp_stale = {
		"The camp or your bag just changed. Check the new amounts and give again.",
		"캠프나 가방이 방금 바뀌었어요. 수량을 확인하고 다시 기부하세요.",
	},
	camp_not_needed = { "This project does not need that item", "이 프로젝트에는 필요 없는 재료예요" },
	camp_over = {
		"That is more than the project still needs. Lower the amount.",
		"프로젝트에 남은 필요량보다 많아요. 수량을 줄이세요.",
	},
	camp_locked_project = {
		"Finish the previous rung before giving to this project",
		"이전 단계를 먼저 완성해야 기부할 수 있어요",
	},
	camp_unknown_project = {
		"That project no longer exists. Reopen the camp.",
		"없는 프로젝트예요. 캠프를 다시 여세요.",
	},
	camp_bad_quantity = {
		"Choose an amount between 1 and what you carry",
		"1개 이상, 가진 만큼만 고르세요",
	},
	camp_short = {
		"You no longer carry that many (some may be reserved). Pick again.",
		"그만큼 가지고 있지 않아요 (예약된 재료 제외). 다시 고르세요.",
	},
	camp_missing_item = { "That item is no longer in your bag", "그 아이템이 가방에 없어요" },
	camp_busy = {
		"Camp storage is busy. Wait a moment and give again; nothing was lost.",
		"캠프 저장소가 바빠요. 잠시 뒤 다시 기부하세요. 잃은 재료는 없어요.",
	},
	camp_receipts = {
		"Too many recent camp deliveries. Try again later.",
		"최근 캠프 기부가 너무 많아요. 나중에 다시 시도하세요.",
	},
	camp_retry = {
		"Connection uncertain. Press Give again; it will not give twice.",
		"연결이 불확실해요. 다시 기부를 누르세요. 두 번 기부되지 않아요.",
	},
	camp_expired_session = {
		"Session expired. Reopen the camp and try again.",
		"세션이 만료됐어요. 캠프를 다시 열고 시도하세요.",
	},
	camp_left = {
		"You left the camp server. Rejoin to give.",
		"캠프 서버를 떠났어요. 다시 접속한 뒤 기부하세요.",
	},
	camp_rate = { "Too fast. Wait a moment, then give again.", "너무 빨라요. 잠시 뒤 다시 기부하세요." },
	camp_tribe = {
		"This camp could not be found. Reopen the camp.",
		"캠프를 찾을 수 없어요. 캠프를 다시 여세요.",
	},
	camp_host = { "That camp's host is not here right now", "그 캠프 주인이 지금 없어요" },
	camp_member_already = {
		"You are already in this camp. Use Give.",
		"이미 이 캠프 구성원이에요. 기부를 사용하세요.",
	},
	camp_pass_limit = {
		"This camp has too many visitors right now",
		"지금 이 캠프에 방문자가 너무 많아요",
	},
	camp_incomplete = {
		"Deliver every material before finishing",
		"모든 재료를 기부해야 완료할 수 있어요",
	},
	camp_not_joint = {
		"Two different members must give before finishing",
		"서로 다른 구성원 두 명이 기부해야 완료할 수 있어요",
	},
	camp_combat = {
		"A wildlife fight is still settling. Wait a moment, then give again.",
		"야생 동물과의 전투를 정산하는 중이에요. 잠시 뒤 다시 기부하세요.",
	},
	camp_not_started = {
		"Nobody has given to this project yet",
		"아직 아무도 이 프로젝트에 기부하지 않았어요",
	},
}
-- Every code a camp command can return (CampExtension, Camp, Inventory, Session admission and the
-- client transport) has its own line; only a truly unknown code falls back to camp_refused.
local REFUSALS: { [string]: string } = {
	NOT_FRIEND = "camp_not_friend",
	NO_PASS = "camp_no_pass",
	VISIT_EXPIRED = "camp_expired",
	FORBIDDEN = "camp_forbidden",
	STALE_VERSION = "camp_stale",
	ITEM_NOT_NEEDED = "camp_not_needed",
	OVER_DELIVERY = "camp_over",
	PROJECT_LOCKED = "camp_locked_project",
	UNKNOWN_PROJECT = "camp_unknown_project",
	INVALID_QUANTITY = "camp_bad_quantity",
	EMPTY_RESERVATION = "camp_bad_quantity",
	UNAVAILABLE = "camp_short",
	UNKNOWN_ITEM = "camp_missing_item",
	RESERVE_FAILED = "camp_short",
	RESERVATION_OWNER = "camp_retry",
	REQUEST_CONFLICT = "camp_retry",
	RECEIPT_EXISTS = "camp_retry",
	INVALID_REQUEST = "camp_retry",
	COMMAND_PENDING = "camp_retry",
	SERVER_EVENT_PENDING = "camp_retry",
	TRANSFER_PENDING = "camp_busy",
	COMBAT_PENDING = "camp_combat",
	COMMIT_FAILED = "camp_busy",
	STALE_PERSONAL_REVISION = "camp_stale",
	REQUEST_WINDOW_FULL = "camp_rate",
	ACTOR_LEAVING = "camp_left",
	["player not joined"] = "camp_left",
	["invalid args"] = "camp_bad_quantity",
	["invalid arity"] = "camp_bad_quantity",
	["invalid tuple"] = "camp_bad_quantity",
	["invalid tuple data"] = "camp_bad_quantity",
	TRANSPORT_FAILED = "camp_retry",
	SETTLE_FAILED = "camp_busy",
	CAMP_COMMIT_FAILED = "camp_busy",
	CAMP_UNAVAILABLE = "camp_busy",
	PERSONAL_UNAVAILABLE = "camp_busy",
	COMMAND_UNAVAILABLE = "camp_busy",
	RECEIPT_LIMIT = "camp_receipts",
	REQUEST_EXPIRED = "camp_expired_session",
	ACTOR_LEFT = "camp_left",
	RATE_LIMITED = "camp_rate",
	["rate limited"] = "camp_rate",
	INVALID_TRIBE = "camp_tribe",
	TRIBE_MISMATCH = "camp_tribe",
	HOST_UNAVAILABLE = "camp_host",
	ALREADY_MEMBER = "camp_member_already",
	PASS_LIMIT = "camp_pass_limit",
	INCOMPLETE = "camp_incomplete",
	NOT_JOINT = "camp_not_joint",
	NOT_STARTED = "camp_not_started",
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
	local code = reason or ""
	-- The client transport appends the engine error: "TRANSPORT_FAILED: <detail>".
	if string.sub(code, 1, 16) == "TRANSPORT_FAILED" then
		code = "TRANSPORT_FAILED"
	end
	return M.text(locale, REFUSALS[code] or "camp_refused")
end

--- Refusal codes with their own line (specs prove each is distinct from the generic one).
function M.refusalCodes(): { string }
	local codes = {}
	for code in REFUSALS do
		table.insert(codes, code)
	end
	table.sort(codes)
	return codes
end

-- Items the player may give: the carried bag's unreserved stacks, ordered by id.
--- names: the pack's display names (the same ones the requirement rows use), so the picker and
--- the cost line name an item identically (p43: picker "섬유" vs requirement "고사리 섬유").
function M.choices(locale: string, packet: any, names: { [string]: string }?): { Choice }
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
				label = names and names[row.item.catalogId] or HudLocale.text(locale, row.item.catalogId),
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

--- Success line after a donation: item x quantity and the project's new progress.
function M.given(locale: string, item: string, quantity: number, project: string, row: Row): string
	local total = math.min(row.need, row.delivered + quantity)
	return string.format(M.text(locale, "camp_given"), item, quantity, project, total, row.need)
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
