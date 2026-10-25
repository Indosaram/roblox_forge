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

local PackLocale = require("./PackLocale")
local STRINGS: { [string]: { string } } = PackLocale.rows({})
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
local LOAN_REFUSALS: { [string]: string } = {
	FORBIDDEN = "camp_loan_forbidden",
	OWN_LOAN = "camp_loan_own",
	NOT_BORROWER = "camp_loan_not_borrower",
	NO_LOAN = "camp_loan_missing",
	LOAN_OUT = "camp_loan_busy",
	NOT_LENDER = "camp_loan_not_lender",
	LOAN_TAKEN = "camp_loan_taken",
	LOAN_EXISTS = "camp_loan_exists",
	LOAN_IN_USE = "camp_loan_in_use",
	BAG_FULL = "camp_loan_bag_full",
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
function M.refusal(locale: string, reason: string?, loan: boolean?): string
	local code = reason or ""
	-- The client transport appends the engine error: "TRANSPORT_FAILED: <detail>".
	if string.sub(code, 1, 16) == "TRANSPORT_FAILED" then
		code = "TRANSPORT_FAILED"
	end
	if loan and LOAN_REFUSALS[code] then
		return M.text(locale, LOAN_REFUSALS[code])
	end
	return M.text(locale, REFUSALS[code] or "camp_refused")
end

--- camp-loan refusal codes with their own line (FORBIDDEN means "not a camp member" here).
function M.loanRefusalCodes(): { string }
	local codes = {}
	for code in LOAN_REFUSALS do
		table.insert(codes, code)
	end
	table.sort(codes)
	return codes
end

export type LoanRow = { name: string, text: string, args: { string }? }

--- Equipment loans (camp-loan): lend the picked item, then one row per open loan with the
--- action this player may take (borrow, return, recall) or a status line. `people` maps ids to
--- display names, `items` catalog ids to item names.
function M.loans(locale: string, slice: any, me: string, choice: Choice?, people: any, items: any): { LoanRow }
	local rows: { LoanRow } = {}
	if type(slice) ~= "table" or slice.role ~= "member" then
		return rows
	end
	local function person(id: string): string
		return people and people[id] or id
	end
	local function item(catalogId: string): string
		return items and items[catalogId] or HudLocale.text(locale, catalogId)
	end
	table.insert(rows, {
		name = "LoanOffer",
		text = if choice
			then string.format(M.text(locale, "camp_loan_offer"), choice.label)
			else M.text(locale, "camp_loan_nothing"),
		args = if choice then { "offer", choice.itemId } else nil,
	})
	local ids = {}
	for id in slice.loans or {} do
		table.insert(ids, id)
	end
	table.sort(ids)
	if #ids == 0 then
		table.insert(rows, { name = "LoanEmpty", text = M.text(locale, "camp_loan_empty") })
	end
	for _, id in ids do
		local loan = slice.loans[id]
		local name, mine = item(loan.catalogId), loan.lender == me
		local key, verb, who = nil, nil, nil
		if loan.borrower == me then
			key, verb = "camp_loan_return", "return"
		elseif loan.borrower then
			key, who = "camp_loan_out", person(loan.borrower)
		elseif mine then
			key, verb = "camp_loan_recall", "recall"
		else
			key, verb, who = "camp_loan_take", "take", person(loan.lender)
		end
		table.insert(rows, {
			name = "Loan-" .. id,
			text = if who
				then string.format(M.text(locale, key), name, who)
				else string.format(M.text(locale, key), name),
			args = if verb then { verb, id } else nil,
		})
	end
	return rows
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
