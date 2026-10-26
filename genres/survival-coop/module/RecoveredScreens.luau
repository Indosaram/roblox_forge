--!strict
-- Recovered spec screens (p83 audit "not implemented"): ui.recipe-tracker, ui.score-library,
-- ui.clan-treasury, ui.clan-research, ui.territory, ui.build-manage, ui.social and the full
-- ui.arrival copy. Each screen is a pure rows(locale, state, act) model rendered by the shared
-- SocialSheet (48 px rows, fitted contextual sheet). Data comes from the existing snapshots and
-- every action sends an existing durable command; the server re-validates all of it.
local Sheet = require("./SocialSheet")
local L = require("./ScreenText")
local SocialText = require("./SocialLocale")
local Clan = require("../../../core/domain/settlement/Clan")
local Topology = require("../../../core/domain/settlement/Multistorey")
local RecipeMarks = require("./RecipeMarks")
local Selection = require("./MusicSelection")
local HUDModel = require("./SurvivalHUDModel")
local M = {}

M.PREFIX = "survival-coop:"
M.AMOUNTS = { 10, 50, 100, 500, 1000 }
M.SCREENS = {
	{ id = "recipe-tracker", spec = "ui.recipe-tracker", title = "scr.tracker.title", order = 30 },
	{ id = "score-library", spec = "ui.score-library", title = "scr.library.title", order = 31 },
	{ id = "clan-treasury", spec = "ui.clan-treasury", title = "scr.treasury.title", order = 32 },
	{ id = "clan-research", spec = "ui.clan-research", title = "scr.research.title", order = 33 },
	{ id = "territory", spec = "ui.territory", title = "scr.territory.title", order = 34 },
	{ id = "build-manage", spec = "ui.build-manage", title = "scr.manage.title", order = 35 },
	{ id = "players", spec = "ui.social", title = "scr.social.title", order = 36 },
	{ id = "arrival", spec = "ui.arrival", title = "scr.arrival.title", order = 37 },
	{ id = "jobs", spec = "ui.jobs", title = "scr.jobs.title", order = 38 },
	{ id = "clan-roles", spec = "ui.clan-roles", title = "scr.roles.title", order = 39 },
	-- Contextual: opened by a listing's Buy button in the harbor market, not by the navigator.
	{ id = "market-buy", spec = "ui.market-buy", title = "scr.buy.title", order = 40, contextual = true },
	-- Opened from the clan sheet and ui.clan-roles (p117); the clan-id box stays as a fallback.
	{ id = "clan-browse", spec = "ui.clan-browse", title = "scr.browse.title", order = 41, contextual = true },
}
-- The listing the market's Buy button handed to ui.market-buy (id, catalogId, quantity, price, seller).
M.buying = {} :: { listing: any? }

local function name(names: any, id: string): string
	return if names and names[id] then names[id] else id
end

local function sorted(map: any): { string }
	local keys = {}
	for key in map or {} do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function research(locale: string, definitionId: string): string
	local short = string.gsub(definitionId, "^clan%-research%-", "")
	local key = "scr.research." .. short
	return if L.has(key) then L.text(locale, key) else short
end

-- ui.recipe-tracker: state = { bag, warehouse, recipes, marks, names, status }
function M.trackerRows(locale: string, state: any, act: any): { any }
	local rows: { any } = {}
	local tracked = RecipeMarks.tracker(state.bag, state.warehouse, state.recipes or {}, state.marks)
	if #tracked == 0 then
		table.insert(rows, { text = L.text(locale, "scr.tracker.empty") })
	end
	for _, row in tracked do
		local label = name(state.names, row.recipeId)
		local short = 0
		for _, need in row.inputs do
			short += need.deficit
		end
		table.insert(rows, {
			text = if row.ready
				then L.text(locale, "scr.tracker.ready", label)
				else L.text(locale, "scr.tracker.missing", label, short),
		})
		for _, need in row.inputs do
			table.insert(rows, {
				text = if need.deficit > 0
					then L.text(
						locale,
						"scr.tracker.short",
						name(state.names, need.id),
						need.bag,
						need.warehouse,
						need.needed,
						need.deficit
					)
					else L.text(
						locale,
						"scr.tracker.input",
						name(state.names, need.id),
						need.bag,
						need.warehouse,
						need.needed
					),
			})
		end
		local output = (row.outputs or {})[1]
		if output then
			table.insert(
				rows,
				{ text = L.text(locale, "scr.tracker.output", name(state.names, output.item), output.quantity) }
			)
		end
		table.insert(rows, {
			text = L.text(locale, "scr.tracker.untrack", label),
			onClick = function()
				act.untrack(row.recipeId)
			end,
		})
	end
	table.insert(rows, { text = L.text(locale, "scr.tracker.limit", RecipeMarks.TODO_LIMIT) })
	if state.status then
		table.insert(rows, { text = state.status })
	end
	table.insert(rows, { text = L.text(locale, "scr.tracker.open_craft"), onClick = act.craft })
	return rows
end

-- ui.score-library: state = { library = { {scoreId, revision, tempo, parts, seconds} }?, selected }
function M.libraryRows(locale: string, state: any, act: any): { any }
	local rows: { any } = {}
	local library = state.library
	if library == nil then
		table.insert(rows, { text = L.text(locale, "scr.library.loading") })
	elseif #library == 0 then
		table.insert(rows, { text = L.text(locale, "scr.library.empty") })
	else
		table.insert(rows, { text = L.text(locale, "scr.library.count", #library) })
	end
	for _, entry in library or {} do
		local mark = if state.selected
				and state.selected.scoreId == entry.scoreId
				and state.selected.revision == entry.revision
			then "* "
			else ""
		table.insert(rows, {
			text = mark .. L.text(
				locale,
				"scr.library.row",
				entry.scoreId,
				entry.revision,
				entry.tempo or 0,
				entry.parts or 0,
				entry.seconds or 0
			),
			onClick = function()
				act.select(entry)
			end,
		})
	end
	if state.selected then
		table.insert(rows, {
			text = L.text(locale, "scr.library.selected", state.selected.scoreId .. "#" .. state.selected.revision),
		})
		table.insert(rows, { text = L.text(locale, "scr.library.share"), onClick = act.share })
		table.insert(rows, { text = L.text(locale, "scr.library.ensemble"), onClick = act.ensemble })
	end
	table.insert(rows, { text = L.text(locale, "scr.library.new"), onClick = act.editor })
	table.insert(rows, { text = L.text(locale, "scr.library.import"), onClick = act.import })
	table.insert(rows, { text = L.text(locale, "scr.library.shared") })
	return rows
end

local function noClan(locale: string, act: any): { any }
	return {
		{ text = L.text(locale, "scr.clan.none") },
		{ text = L.text(locale, "scr.clan.open"), onClick = act.clan },
	}
end

-- ui.clan-treasury: state = { clan, actorId, balance, amount, pending = "deposit"|"withdraw"?, status }
function M.treasuryRows(locale: string, state: any, act: any): { any }
	local clan = state.clan
	if not clan then
		return noClan(locale, act)
	end
	local rows: { any } = {
		{ text = L.text(locale, "scr.treasury.funds", clan.funds) },
		{ text = L.text(locale, "scr.treasury.balance", state.balance or 0) },
	}
	if state.pending then
		table.insert(rows, { text = L.text(locale, "scr.treasury.confirm_" .. state.pending, state.amount) })
		if state.status then
			table.insert(rows, { text = state.status })
		end
		table.insert(rows, { text = L.text(locale, "scr.confirm"), onClick = act.confirm })
		table.insert(rows, { text = L.text(locale, "scr.back"), onClick = act.back })
		return rows
	end
	local canWithdraw = Clan.allowed(clan, state.actorId, "withdraw")
	table.insert(rows, {
		text = L.text(locale, if canWithdraw then "scr.treasury.can_withdraw" else "scr.treasury.no_withdraw"),
	})
	table.insert(rows, { text = L.text(locale, "scr.treasury.amount", state.amount), onClick = act.amount })
	if Clan.allowed(clan, state.actorId, "deposit") then
		table.insert(rows, {
			text = L.text(locale, "scr.treasury.deposit", state.amount),
			onClick = function()
				act.ask("deposit")
			end,
		})
	end
	if canWithdraw then
		table.insert(rows, {
			text = L.text(locale, "scr.treasury.withdraw", state.amount),
			onClick = function()
				act.ask("withdraw")
			end,
		})
	end
	if state.status then
		table.insert(rows, { text = state.status })
	end
	table.insert(rows, { text = L.text(locale, "scr.treasury.ledger") })
	local entries = 0
	for _, id in sorted(clan.walletOperations) do
		local row = clan.walletOperations[id]
		local request = row.request or {}
		local status = if row.result == nil
			then "scr.status.pending"
			elseif row.result.ok then "scr.status.done"
			else "scr.status.refused"
		entries += 1
		table.insert(rows, {
			text = L.text(
				locale,
				if request.operation == "withdraw" then "scr.treasury.entry_withdraw" else "scr.treasury.entry_deposit",
				request.amount or 0,
				tostring(request.actor),
				L.text(locale, status)
			),
		})
	end
	for _, id in sorted(clan.jobs) do
		local job = clan.jobs[id]
		entries += 1
		table.insert(rows, {
			text = L.text(
				locale,
				"scr.treasury.spend",
				research(locale, job.definition),
				job.cost,
				L.text(locale, "scr.status." .. (if job.status == "pending" then "pending" else job.status))
			),
		})
	end
	if entries == 0 then
		table.insert(rows, { text = L.text(locale, "scr.treasury.ledger_empty") })
	end
	return rows
end

-- ui.clan-research: state = { clan, outpost, actorId, now, operations, policy, status }
function M.researchRows(locale: string, state: any, act: any): { any }
	local clan = state.clan
	if not clan then
		return noClan(locale, act)
	end
	local rows: { any } = {
		{ text = L.text(locale, "scr.research.summary", clan.level, clan.funds) },
		{ text = L.text(locale, "scr.research.hall") },
	}
	local manage = Clan.allowed(clan, state.actorId, "research")
	local definitions = {}
	for _, definition in state.operations or {} do
		if definition.kind == "clan-research" then
			table.insert(definitions, definition)
		end
	end
	table.sort(definitions, function(a: any, b: any): boolean
		return a.gates.clanLevel < b.gates.clanLevel
	end)
	for _, definition in definitions do
		local label = research(locale, definition.id)
		local job: any = nil
		for _, candidate in clan.jobs do
			if candidate.definition == definition.id and candidate.status ~= "cancelled" then
				job = candidate
			end
		end
		if job and job.status == "completed" then
			table.insert(rows, { text = L.text(locale, "scr.research.done", label) })
		elseif job then
			local left = job.finishAt - state.now
			if left > 0 then
				table.insert(rows, { text = L.text(locale, "scr.research.running", label, L.duration(left)) })
				if manage then
					table.insert(rows, {
						text = L.text(
							locale,
							"scr.research.cancel",
							label,
							math.floor(job.cost * ((state.policy and state.policy.cancelRefund) or 0))
						),
						onClick = function()
							act.command("research-cancel", { jobId = job.jobId })
						end,
					})
				end
			else
				table.insert(rows, { text = L.text(locale, "scr.research.ready", label) })
				if manage then
					table.insert(rows, {
						text = L.text(locale, "scr.research.complete", label),
						onClick = function()
							act.command("research-complete", { jobId = job.jobId })
						end,
					})
				end
			end
		else
			table.insert(rows, {
				text = L.text(
					locale,
					"scr.research.row",
					label,
					definition.gates.clanLevel,
					definition.cost,
					math.ceil(definition.seconds / 60)
				),
			})
			local lock = if not manage
				then L.text(locale, "scr.research.locked_role")
				elseif clan.level < definition.gates.clanLevel then L.text(
					locale,
					"scr.research.locked_level",
					definition.gates.clanLevel
				)
				elseif clan.funds < definition.cost then L.text(
					locale,
					"scr.research.locked_funds",
					definition.cost
				)
				else nil
			if lock then
				table.insert(rows, { text = lock })
			else
				table.insert(rows, {
					text = L.text(locale, "scr.research.start", label),
					onClick = function()
						act.command("research-start", { id = definition.id })
					end,
				})
			end
		end
	end
	local capture = Clan.effect(clan, state.actorId, "advanced-capture", state.now, state.outpost)
	table.insert(rows, {
		text = L.text(locale, if capture then "scr.research.capture_on" else "scr.research.capture_off"),
	})
	if state.status then
		table.insert(rows, { text = state.status })
	end
	return rows
end

-- ui.territory: state = { home, clan, outpost, actorId, now, here, pending, status }
function M.territoryRows(locale: string, state: any, act: any): { any }
	local rows: { any } = {}
	local home = state.home
	if home and home.owner == state.actorId then
		table.insert(rows, {
			text = L.text(
				locale,
				"scr.territory.personal",
				SocialText.text(locale, "dest." .. tostring(home.location or "cove-north")),
				home.landRank or 1
			),
		})
	else
		table.insert(rows, { text = L.text(locale, "scr.territory.personal_none") })
	end
	local clan = state.clan
	if clan and clan.territory ~= "" then
		table.insert(rows, { text = L.text(locale, "scr.territory.clan", L.layout(locale, clan.territory)) })
	else
		table.insert(rows, { text = L.text(locale, "scr.territory.clan_none") })
	end
	table.insert(rows, { text = L.text(locale, "scr.territory.rules") })
	local outpost = state.outpost or {}
	if outpost.owner and outpost.owner ~= "" and state.now < (outpost.expiresAt or 0) then
		table.insert(rows, {
			text = L.text(locale, "scr.territory.outpost", outpost.owner, L.duration(outpost.expiresAt - state.now)),
		})
	else
		table.insert(rows, { text = L.text(locale, "scr.territory.outpost_none") })
	end
	if state.here then
		table.insert(rows, { text = L.text(locale, "scr.territory.here", L.layout(locale, state.here)) })
	end
	if clan and state.pending then
		table.insert(rows, { text = L.text(locale, "scr.territory.confirm", L.layout(locale, state.pending)) })
		table.insert(rows, { text = L.text(locale, "scr.confirm"), onClick = act.confirm })
		table.insert(rows, { text = L.text(locale, "scr.back"), onClick = act.back })
	elseif clan and state.here and state.here ~= clan.territory and Clan.allowed(clan, state.actorId, "territory") then
		table.insert(rows, {
			text = L.text(locale, "scr.territory.claim", L.layout(locale, state.here)),
			onClick = act.ask,
		})
	end
	if state.status then
		table.insert(rows, { text = state.status })
	end
	if clan then
		table.insert(rows, { text = L.text(locale, "scr.territory.journal") })
		local journal = clan.journal or {}
		if #journal == 0 then
			table.insert(rows, { text = L.text(locale, "scr.territory.journal_empty") })
		end
		for index = #journal, 1, -1 do
			local entry = journal[index]
			table.insert(rows, {
				text = L.text(
					locale,
					"scr.territory.entry",
					L.duration(state.now - entry.at),
					L.layout(locale, entry.from),
					L.layout(locale, entry.to)
				),
			})
		end
	end
	return rows
end

local function partName(locale: string, kind: string): string
	local key = "scr.manage." .. kind
	return if L.has(key) then L.text(locale, key) else kind
end

-- ui.build-manage: state = { building = {version, parts}, home, actorId, names, pending, status }
function M.manageRows(locale: string, state: any, act: any): { any }
	local rows: { any } = {}
	local building = state.building or { version = 0, parts = {} }
	local home = state.home
	local structures = if home and home.owner == state.actorId then home.structures or {} else {}
	local partIds = sorted(building.parts)
	local structureIds = sorted(structures)
	if state.pending then
		local pending = state.pending
		if pending.kind == "part" then
			local part = building.parts[pending.id]
			table.insert(rows, {
				text = if part
					then L.text(locale, "scr.manage.confirm", part.floor, partName(locale, part.kind))
					else L.refusal(locale, "UNKNOWN_PART"),
			})
		else
			local placed = structures[pending.id]
			table.insert(rows, {
				text = if placed
					then L.text(locale, "scr.manage.structure_confirm", name(state.names, placed.kind))
					else L.refusal(locale, "UNKNOWN_STRUCTURE"),
			})
		end
		if state.status then
			table.insert(rows, { text = state.status })
		end
		table.insert(rows, { text = L.text(locale, "scr.confirm"), onClick = act.confirm })
		table.insert(rows, { text = L.text(locale, "scr.back"), onClick = act.back })
		return rows
	end
	if #partIds == 0 and #structureIds == 0 then
		table.insert(rows, { text = L.text(locale, "scr.manage.empty") })
	end
	if #partIds > 0 then
		table.insert(rows, { text = L.text(locale, "scr.manage.floors", #partIds, building.version) })
	end
	table.sort(partIds, function(a: string, b: string): boolean
		local pa, pb = building.parts[a], building.parts[b]
		if pa.floor ~= pb.floor then
			return pa.floor > pb.floor
		end
		return a < b
	end)
	for _, id in partIds do
		local part = building.parts[id]
		-- Dry run of the authoritative topology rule: upper floors and stairs block removal.
		local _, refusal = Topology.remove(building, id, building.version)
		if refusal then
			table.insert(rows, {
				text = L.text(
					locale,
					"scr.manage.blocked",
					part.floor,
					partName(locale, part.kind),
					L.refusal(locale, refusal)
				),
			})
		else
			table.insert(rows, {
				text = L.text(locale, "scr.manage.part", part.floor, partName(locale, part.kind), part.x, part.z),
				onClick = function()
					act.ask("part", id)
				end,
			})
		end
	end
	if #structureIds > 0 then
		table.insert(rows, { text = L.text(locale, "scr.manage.home", #structureIds) })
	end
	for _, id in structureIds do
		local placed = structures[id]
		local label = name(state.names, placed.kind)
		if home.plots and home.plots[id] then
			table.insert(rows, {
				text = L.text(locale, "scr.manage.structure_blocked", label, L.refusal(locale, "PLOT_OCCUPIED")),
			})
		else
			table.insert(rows, {
				text = L.text(locale, "scr.manage.structure", label),
				onClick = function()
					act.ask("structure", id)
				end,
			})
		end
	end
	if state.status then
		table.insert(rows, { text = state.status })
	end
	if home and home.owner == state.actorId then
		table.insert(rows, { text = L.text(locale, "scr.manage.move"), onClick = act.move })
	end
	return rows
end

-- ui.social: state = { roster = {{id, name}}, actorId, capacity, hosts, clan, status }
function M.socialRows(locale: string, state: any, act: any): { any }
	local others = {}
	for _, entry in state.roster or {} do
		if entry.id ~= state.actorId then
			table.insert(others, entry)
		end
	end
	table.sort(others, function(a: any, b: any): boolean
		return a.name < b.name
	end)
	local rows: { any } = {
		{ text = L.text(locale, "scr.social.count", #others + 1, state.capacity) },
	}
	if #others == 0 then
		table.insert(rows, { text = L.text(locale, "scr.social.empty") })
	end
	local canInvite = state.clan ~= nil and Clan.allowed(state.clan, state.actorId, "invite")
	for _, other in others do
		table.insert(rows, { text = L.text(locale, "scr.social.player", other.name) })
		if state.hosts and state.hosts[other.id] then
			table.insert(rows, {
				text = L.text(locale, "scr.social.visit", other.name),
				onClick = function()
					act.send("camp-visit-open", { other.id })
				end,
			})
		end
		table.insert(rows, {
			text = L.text(locale, "scr.social.trade", other.name),
			onClick = function()
				act.send("trade-open", { other.id })
			end,
		})
		table.insert(rows, {
			text = L.text(locale, "scr.social.party", other.name),
			onClick = function()
				act.send("party-action", { "invite", other.id })
			end,
		})
		if canInvite and not state.clan.members[other.id] then
			table.insert(rows, {
				text = L.text(locale, "scr.social.clan", other.name),
				onClick = function()
					act.send(
						"clan-invite",
						{ state.clan.clanId, { target = other.id, expectedRevision = state.clan.revision } }
					)
				end,
			})
		end
	end
	if state.status then
		table.insert(rows, { text = state.status })
	end
	table.insert(rows, { text = L.text(locale, "scr.social.access"), onClick = act.access })
	table.insert(rows, { text = L.text(locale, "scr.social.clan_open"), onClick = act.clan })
	return rows
end

-- ui.arrival: state = { tutorial, objective } (objective is the contracts board's localized line)
function M.arrivalRows(locale: string, state: any, act: any): { any }
	local tutorial = state.tutorial or {}
	local view = {
		objective = state.objective or L.text(locale, "scr.arrival.together"),
		canSkip = tutorial.complete ~= true and tutorial.step == "arrive",
	}
	local rows: { any } = {
		{ text = L.text(locale, "scr.arrival.premise") },
		{ text = L.text(locale, "scr.arrival.together") },
		{ text = L.text(locale, if state.touch then "scr.arrival.goal_touch" else "scr.arrival.goal", view.objective) },
		{ text = L.text(locale, "scr.arrival.skip_note") },
		{ text = L.text(locale, "scr.arrival.continue"), onClick = act.close },
	}
	if view.canSkip then
		table.insert(rows, { text = L.text(locale, "scr.arrival.skip"), onClick = act.skip })
	end
	return rows
end

-- ui.jobs: state = { jobs = {{id, job}}, now (ms), names, status }
function M.jobsRows(locale: string, state: any, act: any): { any }
	local rows: { any } = {}
	if #(state.jobs or {}) == 0 then
		table.insert(rows, { text = L.text(locale, "scr.jobs.empty") })
	end
	for _, entry in state.jobs or {} do
		local job = entry.job
		local label = name(state.names, job.recipeId)
		local finishAt = job.finishAt or 0
		-- Capped at the job's own length so a client clock behind the server never shows more time
		-- than the recipe takes; whole seconds round up, so a running job never reads 0:00 (p105 D2).
		local length = if job.startedAt then finishAt - job.startedAt else math.huge
		local left = math.min(finishAt - state.now, length)
		local ready = job.state == "Ready" or job.state == "Running" and left <= 0
		local phase = if job.state == "Reserved"
			then L.text(locale, "scr.jobs.reserved")
			elseif ready then L.text(locale, "scr.jobs.ready")
			else L.text(locale, "scr.jobs.running", L.duration(math.ceil(left / 1000)))
		table.insert(rows, { text = L.text(locale, "scr.jobs.row", label, string.sub(entry.id, 1, 8), phase) })
		for _, pair: any in { { "escrow", job.inputs }, { "result", job.outputs } } do
			local parts = {}
			for _, stack in pair[2] or {} do
				table.insert(parts, name(state.names, stack.catalogId) .. " x" .. stack.quantity)
			end
			if #parts > 0 then
				table.insert(rows, { text = L.text(locale, "scr.jobs." .. pair[1], table.concat(parts, ", ")) })
			end
		end
		local verb = if job.state == "Reserved" then "start" elseif ready then "complete" else nil
		if verb then
			table.insert(rows, {
				text = L.text(locale, "scr.jobs." .. verb, label),
				onClick = function()
					act.command("craft-" .. verb, entry.id)
				end,
			})
		end
		if job.state == "Reserved" then
			table.insert(rows, {
				text = L.text(locale, "scr.jobs.cancel", label),
				onClick = function()
					act.command("craft-cancel", entry.id)
				end,
			})
		end
	end
	if state.status then
		table.insert(rows, { text = state.status })
	end
	table.insert(rows, { text = L.text(locale, "scr.jobs.cancel_note") })
	table.insert(rows, { text = L.text(locale, "scr.jobs.terms") })
	table.insert(rows, { text = L.text(locale, "scr.tracker.open_craft"), onClick = act.craft })
	table.insert(rows, { text = L.text(locale, "scr.nav.research"), onClick = act.research })
	table.insert(rows, { text = L.text(locale, "scr.jobs.taming"), onClick = act.taming })
	return rows
end

local PREVIEW_ROLES = { "officer", "member", "visitor" }
function M.rolesRows(locale: string, state: any, act: any): { any }
	local clan = state.clan
	if not clan then
		local rows = { { text = L.text(locale, "scr.clan.none") } }
		for _, role in { "member", "visitor" } do
			table.insert(rows, {
				text = L.text(locale, "scr.roles.apply_" .. role),
				onClick = function()
					act.apply(role)
				end,
			})
		end
		table.insert(rows, { text = L.text(locale, "scr.roles.browse"), onClick = act.browse })
		if state.applied then
			table.insert(rows, {
				text = L.text(locale, "scr.roles.withdraw_draft", state.applied),
				onClick = function()
					act.withdraw(state.applied)
				end,
			})
		end
		if state.status then
			table.insert(rows, { text = state.status })
		end
		table.insert(rows, { text = L.text(locale, "scr.clan.open"), onClick = act.clan })
		return rows
	end
	local ids = sorted(clan.members)
	local govern = Clan.allowed(clan, state.actorId, "govern")
	local rows: { any } = {
		{ text = L.text(locale, "scr.roles.count", #ids) },
		{ text = L.text(locale, if govern then "scr.roles.note" else "scr.roles.readonly") },
	}
	-- A member missing from the server roster is offline: never show the bare user id (p115 D5).
	local function display(id: string): string
		return if state.names and state.names[id] then state.names[id] else L.text(locale, "scr.roles.offline")
	end
	for _, id in ids do
		local member = clan.members[id]
		local who = display(id)
		table.insert(rows, {
			text = L.text(
				locale,
				"scr.roles.line",
				who,
				L.text(locale, "scr.roles.role_" .. member.role),
				L.text(locale, if member.withdraw then "scr.roles.on" else "scr.roles.off")
			),
		})
		if govern and member.role ~= "owner" then
			local role = if member.role == "officer" then "member" else "officer"
			table.insert(rows, {
				text = L.text(locale, "scr.roles.make_" .. role, who),
				onClick = function()
					act.command("role", { target = id, role = role })
				end,
			})
			if member.role ~= "visitor" then
				table.insert(rows, {
					text = L.text(locale, if member.withdraw then "scr.roles.revoke" else "scr.roles.grant", who),
					onClick = function()
						act.command("capability", { target = id, enabled = not member.withdraw })
					end,
				})
			end
		end
	end
	for _, role in PREVIEW_ROLES do
		table.insert(rows, {
			text = L.text(locale, "scr.roles.preview", L.text(locale, "scr.roles.role_" .. role)),
			onClick = function()
				act.preview(role)
			end,
		})
	end
	if Clan.allowed(clan, state.actorId, "invite") then
		local drafts = sorted(clan.drafts)
		if #drafts == 0 then
			table.insert(rows, { text = L.text(locale, "scr.roles.drafts_empty") })
		end
		for _, id in drafts do
			local who = display(id)
			local role = L.text(locale, "scr.roles.role_" .. clan.drafts[id].role)
			table.insert(rows, {
				text = L.text(locale, "scr.roles.draft_confirm", who, role),
				onClick = function()
					act.command("draft-confirm", { target = id })
				end,
			})
			table.insert(rows, {
				text = L.text(locale, "scr.roles.draft_cancel", who),
				onClick = function()
					act.command("draft-cancel", { target = id })
				end,
			})
		end
	end
	if state.status then
		table.insert(rows, { text = state.status })
	end
	table.insert(rows, { text = L.text(locale, "scr.clan.open"), onClick = act.clan })
	return rows
end

-- ui.clan-browse: state = { page = { query, page, pages, rows = {{id, members, capacity, recruiting}} },
--   selected, inClan, status }. A row fills the apply / join action for that clan.
function M.browseRows(locale: string, state: any, act: any): { any }
	local page: any = state.page
	local rows: { any } = {}
	if not page then
		table.insert(rows, { text = L.text(locale, "scr.browse.list"), onClick = act.all })
	elseif #page.rows == 0 then
		table.insert(rows, { text = L.text(locale, "scr.browse.empty") })
	end
	table.insert(rows, { text = L.text(locale, "scr.browse.search"), onClick = act.search })
	if page and page.query ~= "" then
		table.insert(rows, { text = L.text(locale, "scr.browse.query", page.query) })
		table.insert(rows, { text = L.text(locale, "scr.browse.all"), onClick = act.all })
	end
	for _, row in if page then page.rows else {} do
		local text = L.text(
			locale,
			"scr.browse.row",
			row.id,
			row.members,
			row.capacity,
			L.text(locale, if row.recruiting then "scr.browse.recruiting" else "scr.browse.full")
		)
		table.insert(rows, {
			text = text,
			onClick = function()
				act.select(row.id)
			end,
		})
	end
	if page and page.pages > 1 then
		table.insert(rows, { text = L.text(locale, "scr.browse.page", page.page, page.pages) })
		for _, step in { { by = -1, key = "scr.browse.prev" }, { by = 1, key = "scr.browse.next" } } do
			local target = page.page + step.by
			if target >= 1 and target <= page.pages then
				table.insert(rows, {
					text = L.text(locale, step.key),
					onClick = function()
						act.page(target)
					end,
				})
			end
		end
	end
	local id = state.selected
	if id and not state.inClan then
		table.insert(rows, { text = L.text(locale, "scr.browse.selected", id) })
		for _, role in { "member", "visitor" } do
			table.insert(rows, {
				text = L.text(locale, "scr.browse.apply_" .. role, id),
				onClick = function()
					act.apply(id, role)
				end,
			})
		end
		table.insert(rows, {
			text = L.text(locale, "scr.browse.join", id),
			onClick = function()
				act.join(id)
			end,
		})
	end
	if state.status then
		table.insert(rows, { text = state.status })
	end
	table.insert(rows, { text = L.text(locale, "scr.nav.roles"), onClick = act.roles })
	return rows
end

--- The status line for a clan-preview result: the role and the capabilities it grants.
function M.previewLine(locale: string, data: any): string
	local grants = {}
	for _, capability in { "view", "build", "deposit", "invite", "research", "territory", "govern", "withdraw" } do
		if data.grants[capability] then
			table.insert(grants, L.text(locale, "scr.roles.cap_" .. capability))
		end
	end
	return L.text(
		locale,
		"scr.roles.preview_line",
		L.text(locale, "scr.roles.role_" .. data.role),
		table.concat(grants, ", ")
	)
end

-- ui.market-buy: state = { listing, market = { balance, listings }, names, status }
function M.buyRows(locale: string, state: any, act: any): { any }
	local listing, market = state.listing, state.market or {}
	local back = { text = L.text(locale, "scr.buy.open_market"), onClick = act.market }
	if not listing then
		return { { text = L.text(locale, "scr.buy.empty") }, back }
	end
	local rows: { any } = {
		{ text = L.text(locale, "scr.buy.item", name(state.names, listing.catalogId), listing.quantity) },
		{ text = L.text(locale, "scr.buy.total", listing.price, market.balance or 0) },
		{ text = L.text(locale, "scr.buy.listing", string.sub(tostring(listing.id), 1, 8)) },
		{ text = L.text(locale, "scr.buy.whole") },
		{ text = L.text(locale, "scr.buy.final") },
	}
	local listed = market.listings == nil
	for _, other in market.listings or {} do
		listed = listed or (other.id == listing.id and other.price == listing.price)
	end
	if state.status then
		table.insert(rows, { text = state.status })
	end
	if not listed then
		table.insert(rows, { text = L.text(locale, "scr.buy.gone") })
	elseif (market.balance or 0) < listing.price then
		table.insert(rows, { text = L.refusal(locale, "INSUFFICIENT_FUNDS") })
	elseif not state.done then
		table.insert(rows, { text = L.text(locale, "scr.buy.confirm", listing.price), onClick = act.confirm })
	end
	table.insert(rows, back)
	return rows
end

local function bagOf(survival: any): any
	for _, bag in (survival and survival.inventory) or {} do
		if bag.kind == "carried" then
			return bag
		end
	end
	return nil
end

function M.factory(ctx: any): any
	local env: any = getfenv()
	local locale = ctx.locale
	local players = if env.game then env.game:GetService("Players") else nil
	local actorId = ctx.actorId or tostring(players.LocalPlayer.UserId)
	local now = ctx.serverNow or function(): number
		return env.workspace:GetServerTimeNow()
	end
	local here = ctx.currentLayout
		or function(): string?
			local root = env.workspace:FindFirstChild("ForgeRoleWorld")
			local id = if root then root:GetAttribute("ForgeLayoutId") else nil
			return if type(id) == "string" then id else nil
		end
	local capacity = ctx.capacity or (if players then players.MaxPlayers else nil) or 16
	local content = ctx.content or {}
	local panels: { any } = {}
	local function send(action: string, args: { any }): any
		local result = ctx.send(M.PREFIX .. action, args)
		return if type(result) == "table" then result else { ok = false }
	end
	local function open(id: string)
		if ctx.open then
			ctx.open(id)
		end
	end
	local function mount(index: number, select: any, rows: any, extra: any?): any
		local screen = M.SCREENS[index]
		local spec: any = {
			id = screen.id,
			name = "Screen-" .. screen.id,
			title = L.text(locale, screen.title),
			order = screen.order,
			hidden = true,
			select = select,
			rows = rows,
		}
		for key, value in extra or {} do
			spec[key] = value
		end
		local panel = Sheet.mount(ctx, spec)
		table.insert(panels, panel)
		return panel
	end

	-- ui.recipe-tracker
	local trackerStatus: string? = nil
	local tracker: any
	tracker = mount(1, function(extensions: any, packet: any): any
		local snapshots = packet.snapshots or {}
		return {
			bag = bagOf(snapshots["survival-coop"]),
			warehouse = snapshots.survivalSettlement and snapshots.survivalSettlement.warehouse,
			marks = extensions["recipe-marks"],
		}
	end, function(state: any): { any }
		local view = table.clone(state or {})
		view.recipes, view.names, view.status = content.recipes, ctx.names, trackerStatus
		return M.trackerRows(locale, view, {
			untrack = function(recipeId: string)
				local result = send("recipe-mark", { recipeId, "todo", false })
				trackerStatus = if result.ok then nil else L.refusal(locale, result.reason)
				tracker.render()
			end,
			craft = function()
				open("craft")
			end,
		})
	end)

	-- ui.score-library
	mount(2, function(extensions: any): any
		return { library = extensions.ensemble and extensions.ensemble.library }
	end, function(state: any): { any }
		local view = { library = state and state.library, selected = Selection.get() }
		return M.libraryRows(locale, view, {
			select = function(entry: any)
				Selection.set({ scoreId = entry.scoreId, revision = entry.revision, parts = entry.parts, owned = true })
				panels[2].render()
			end,
			share = function()
				open("score-share")
			end,
			ensemble = function()
				open("ensemble-lobby")
			end,
			editor = function()
				open("music")
			end,
			import = function()
				open("score-import")
			end,
		})
	end)

	-- ui.clan-treasury
	local amountIndex, pendingWallet, walletStatus = 1, nil :: string?, nil :: string?
	local treasury: any
	treasury = mount(3, function(extensions: any, packet: any): any
		local survival = (packet.snapshots or {})["survival-coop"]
		return { clan = extensions.clan, balance = survival and tonumber(survival.balance) }
	end, function(state: any): { any }
		local clan = state and state.clan
		return M.treasuryRows(locale, {
			clan = clan,
			actorId = actorId,
			balance = state and state.balance,
			amount = M.AMOUNTS[amountIndex],
			pending = pendingWallet,
			status = walletStatus,
		}, {
			clan = function()
				open("clan")
			end,
			amount = function()
				amountIndex = amountIndex % #M.AMOUNTS + 1
				treasury.render()
			end,
			ask = function(operation: string)
				pendingWallet, walletStatus = operation, nil
				treasury.render()
			end,
			back = function()
				pendingWallet, walletStatus = nil, nil
				treasury.render()
			end,
			confirm = function()
				local operation = pendingWallet :: string
				local result = send("clan-" .. operation, { clan.clanId, { amount = M.AMOUNTS[amountIndex] } })
				if result.ok then
					pendingWallet, walletStatus = nil, L.text(locale, "scr.treasury.done")
				else
					walletStatus = L.refusal(locale, result.reason)
				end
				treasury.render()
			end,
		})
	end)

	-- ui.clan-research
	local researchStatus: string? = nil
	local researchPanel: any
	researchPanel = mount(4, function(extensions: any): any
		return { clan = extensions.clan, outpost = extensions.outpost }
	end, function(state: any): { any }
		local clan = state and state.clan
		return M.researchRows(locale, {
			clan = clan,
			outpost = state and state.outpost,
			actorId = actorId,
			now = now(),
			operations = content.operations,
			policy = content.clanPolicy,
			status = researchStatus,
		}, {
			clan = function()
				open("clan")
			end,
			command = function(operation: string, args: any)
				args.expectedRevision = clan.revision
				local result = send("clan-" .. operation, { clan.clanId, args })
				researchStatus = if result.ok then nil else L.refusal(locale, result.reason)
				researchPanel.render()
			end,
		})
	end)

	-- ui.territory
	local pendingTerritory, territoryStatus = nil :: string?, nil :: string?
	local territory: any
	territory = mount(5, function(extensions: any): any
		return { home = extensions.home, clan = extensions.clan, outpost = extensions.outpost }
	end, function(state: any): { any }
		local clan = state and state.clan
		return M.territoryRows(locale, {
			home = state and state.home,
			clan = clan,
			outpost = state and state.outpost,
			actorId = actorId,
			now = now(),
			here = here(),
			pending = pendingTerritory,
			status = territoryStatus,
		}, {
			ask = function()
				pendingTerritory, territoryStatus = here(), nil
				territory.render()
			end,
			back = function()
				pendingTerritory = nil
				territory.render()
			end,
			confirm = function()
				local result = send(
					"clan-relocate",
					{ clan.clanId, { territory = pendingTerritory, expectedRevision = clan.revision } }
				)
				pendingTerritory = nil
				territoryStatus = if result.ok then nil else L.refusal(locale, result.reason)
				territory.render()
			end,
		})
	end)

	-- ui.build-manage
	local pendingRecover, manageStatus = nil :: any, nil :: string?
	local manage: any
	manage = mount(6, function(extensions: any): any
		return { building = extensions.building, home = extensions.home }
	end, function(state: any): { any }
		local building = state and state.building
		local home = state and state.home
		return M.manageRows(locale, {
			building = building,
			home = home,
			actorId = actorId,
			names = ctx.names,
			pending = pendingRecover,
			status = manageStatus,
		}, {
			ask = function(kind: string, id: string)
				pendingRecover, manageStatus = { kind = kind, id = id }, nil
				manage.render()
			end,
			back = function()
				pendingRecover, manageStatus = nil, nil
				manage.render()
			end,
			move = function()
				open("home-move")
			end,
			confirm = function()
				local pending = pendingRecover
				local result = if pending.kind == "part"
					then send("building-remove", { { version = building.version, id = pending.id } })
					else send("home-recover", { home.homeId, { id = pending.id } })
				if result.ok then
					pendingRecover, manageStatus = nil, L.text(locale, "scr.manage.done")
				else
					manageStatus = L.refusal(locale, result.reason)
				end
				manage.render()
			end,
		})
	end)

	-- ui.social
	local socialStatus: string? = nil
	local social: any
	social = mount(7, function(extensions: any, packet: any): any
		local camp = extensions.camp
		return {
			roster = packet.roster,
			hosts = if camp and camp.role == "guest" then camp.hosts else nil,
			clan = extensions.clan,
		}
	end, function(state: any): { any }
		local view = table.clone(state or {})
		view.actorId, view.capacity, view.status = actorId, capacity, socialStatus
		return M.socialRows(locale, view, {
			send = function(action: string, args: { any })
				local result = send(action, args)
				socialStatus = if result.ok then L.text(locale, "scr.social.sent") else L.refusal(locale, result.reason)
				social.render()
			end,
			access = function()
				open("home-permissions")
			end,
			clan = function()
				open("clan")
			end,
		})
	end)

	-- ui.arrival: opens once per session while the onboarding tutorial is at its first steps.
	local arrivalShown = false
	local arrival: any
	arrival = mount(8, function(extensions: any): any
		return { contracts = extensions.contracts }
	end, function(state: any): { any }
		local contracts = state and state.contracts
		return M.arrivalRows(locale, {
			tutorial = contracts and contracts.tutorial,
			touch = ctx.touch or players and env.game:GetService("UserInputService").TouchEnabled,
			objective = if contracts and ctx.objective then ctx.objective(contracts) else nil,
		}, {
			close = function()
				arrival.close()
			end,
			skip = function()
				send("tutorial-skip-arrival", {})
				arrival.render()
			end,
		})
	end, {
		autoOpen = function(state: any): boolean
			local tutorial = state and state.contracts and state.contracts.tutorial
			local role = ctx.worldRole or env.workspace and env.workspace:GetAttribute("ForgeWorldRole")
			if arrivalShown or not tutorial or tutorial.complete or role ~= "onboarding" and role ~= "home" then
				return false
			end
			arrivalShown = tutorial.step == "arrive" or tutorial.step == "gather"
			return arrivalShown
		end,
	})

	-- ui.jobs
	local jobsStatus: string? = nil
	local jobs: any
	-- No snapshot arrives while a job runs, so the open sheet re-reads the clock every second until
	-- no job is running: the countdown moves and Collect appears at the deadline (p105 D2).
	local delay = ctx.delay or function(seconds: number, callback: () -> ())
		env.task.delay(seconds, callback)
	end
	local ticking = false
	local function tick()
		ticking = false
		if jobs.isOpen() then
			jobs.refresh()
		end
	end
	jobs = mount(9, function(_extensions: any, packet: any): any
		local survival = (packet.snapshots or {})["survival-coop"]
		return { jobs = if survival then HUDModel.jobs(survival, actorId) else {} }
	end, function(state: any): { any }
		for _, entry in (state and state.jobs) or {} do
			if entry.job.state == "Running" and not ticking and jobs.isOpen() then
				ticking = true
				delay(1, tick)
			end
		end
		return M.jobsRows(locale, {
			jobs = state and state.jobs,
			now = now() * 1000,
			names = ctx.names,
			status = jobsStatus,
		}, {
			command = function(action: string, id: string)
				local result = send(action, { id })
				jobsStatus = if result.ok then nil else L.refusal(locale, result.reason)
				jobs.render()
			end,
			craft = function()
				open("craft")
			end,
			research = function()
				open("clan-research")
			end,
			taming = function()
				open("taming")
			end,
		})
	end)

	-- ui.clan-roles
	local rolesStatus: string? = nil
	local rolesView: string? = nil
	local applied: string? = nil
	local roles: any
	local function draft(id: string, role: string): any
		local result = send("clan-draft", { id, { role = role } })
		applied = if result.ok then id else applied
		return result
	end
	roles = mount(10, function(extensions: any, packet: any): any
		local names = {}
		for _, entry in packet.roster or {} do
			names[entry.id] = entry.name
		end
		return { clan = extensions.clan, names = names }
	end, function(state: any): { any }
		local clan = state and state.clan
		-- A status line belongs to the view it was made in: joining, leaving or switching clans drops
		-- it (p115 D4: "no clan with that ID" stayed on the member view after creating a clan).
		local view = if clan then tostring(clan.clanId) .. "/" .. tostring(clan.members[actorId] ~= nil) else ""
		if view ~= rolesView then
			rolesView, rolesStatus = view, nil
		end
		return M.rolesRows(locale, {
			clan = clan,
			actorId = actorId,
			names = state and state.names,
			status = rolesStatus,
			applied = if clan then nil else applied,
		}, {
			clan = function()
				open("clan")
			end,
			command = function(operation: string, args: any)
				args.expectedRevision = clan.revision
				local result = send("clan-" .. operation, { clan.clanId, args })
				rolesStatus = if result.ok then nil else L.refusal(locale, result.reason)
				roles.render()
			end,
			preview = function(role: string)
				local result = send("clan-preview", { clan.clanId, { role = role } })
				rolesStatus = if result.ok then M.previewLine(locale, result.data) else L.refusal(locale, result.reason)
				roles.render()
			end,
			apply = function(role: string)
				local id = if ctx.askText then ctx.askText() else nil
				if type(id) ~= "string" or id == "" then
					return
				end
				local result = draft(id, role)
				rolesStatus = if result.ok
					then L.text(locale, "scr.roles.applied", id)
					else L.refusal(locale, result.reason)
				roles.render()
			end,
			withdraw = function(id: string)
				local result = send("clan-draft-cancel", { id, {} })
				applied = if result.ok then nil else applied
				rolesStatus = if result.ok then nil else L.refusal(locale, result.reason)
				roles.render()
			end,
			browse = function()
				open("clan-browse")
			end,
		})
	end)

	-- ui.clan-browse
	local browseStatus: string?, picked: string? = nil, nil
	local browse: any
	local function fetch(query: string, page: number)
		local result = send("clan-browse", { query, page })
		browseStatus = if result.ok then nil else L.refusal(locale, result.reason)
		browse.render()
	end
	browse = mount(12, function(extensions: any): any
		return { page = extensions["clan-browse"], inClan = extensions.clan ~= nil }
	end, function(state: any): { any }
		local page = state and state.page
		local query = if page then page.query else ""
		return M.browseRows(locale, {
			page = page,
			selected = picked,
			inClan = state and state.inClan,
			status = browseStatus,
		}, {
			all = function()
				fetch("", 1)
			end,
			search = function()
				local text = if ctx.askText then ctx.askText() else nil
				if type(text) == "string" then
					fetch(string.sub(text, 1, 32), 1)
				end
			end,
			page = function(index: number)
				fetch(query, index)
			end,
			select = function(id: string)
				picked, browseStatus = id, nil
				browse.render()
			end,
			apply = function(id: string, role: string)
				local result = draft(id, role)
				browseStatus = if result.ok
					then L.text(locale, "scr.roles.applied", id)
					else L.refusal(locale, result.reason)
				browse.render()
			end,
			join = function(id: string)
				local result = send("clan-join", { id, {} })
				browseStatus = if result.ok then nil else L.refusal(locale, result.reason)
				browse.render()
			end,
			roles = function()
				open("clan-roles")
			end,
		})
	end)

	-- ui.market-buy: one confirm per listing handed over by the market's Buy button.
	local buyStatus: string?, bought = nil, false
	local shownListing: any = nil
	local buy: any
	buy = mount(11, function(extensions: any): any
		return { market = extensions.market }
	end, function(state: any): { any }
		local listing = M.buying.listing
		if listing ~= shownListing then
			shownListing, buyStatus, bought = listing, nil, false
		end
		return M.buyRows(locale, {
			listing = listing,
			market = state and state.market,
			names = ctx.names,
			status = buyStatus,
			done = bought,
		}, {
			market = function()
				open("market")
			end,
			confirm = function()
				local result = send("market-buy", { listing.id, listing.price })
				bought = result.ok
				buyStatus = if result.ok then L.text(locale, "scr.buy.done") else L.refusal(locale, result.reason)
				buy.render()
			end,
		})
	end)

	return {
		panels = panels,
		destroy = function()
			for _, panel in panels do
				panel.destroy()
			end
		end,
	}
end

-- ui.storage: the camp warehouse beside the bag (p101; folded in here for QA-PERF-01's script
-- budget). Capacity (slots and weight) of both containers, who may move items, a category filter,
-- item pick, quantity stepper and Store / Take through the existing transfer-deposit /
-- transfer-withdraw {itemId, quantity} commands; the server re-checks membership, reach and
-- capacity. Reserved stacks and an unsettled transfer lock the move. Copy is scr.storage.* rows.
local S = {}
M.storage = S

local GEAR_TAGS = { tool = true, ["weapon-tool"] = true, clothing = true, saddle = true, instrument = true }

--- Browse category of a content item: gear, building (kits/parts), food or material.
function S.category(item: any?): string
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

S.FILTERS = { "all", "material", "food", "gear", "building" }
S.STEPS = { 1, 5, 10, 50, 100 }
-- TransferRuntime accepts 1..1000 units per request.
S.MAX_MOVE = 1000

--- Next quantity on the stepper: the fixed steps up to the stack, then the whole stack, then 1.
function S.nextQuantity(current: number, available: number): number
	local all = math.min(available, S.MAX_MOVE)
	if current >= all then
		return 1
	end
	for _, step in S.STEPS do
		if step > current and step < all then
			return step
		end
	end
	return all
end

local function kilos(milli: number): string
	return string.format("%.1f", milli / 1000)
end

local function usage(container: any, weights: { [string]: number }): (number, number, string, string)
	local slots, weight = 0, 0
	for _, item in container.items do
		slots += 1
		weight += (weights[item.catalogId] or 0) * item.quantity
	end
	local limits = container.limits or {}
	return slots, limits.slots or 0, kilos(weight), kilos(limits.hardWeightMilli or 0)
end

-- state = { actorId, content, names, settlement, bag, warehouse, mode = "deposit"|"withdraw",
--   filter, selected, quantity, pending, status }
function S.rows(locale: string, state: any, act: any): { any }
	local warehouse, bag = state.warehouse, state.bag
	if not warehouse or not bag then
		return { { text = L.text(locale, "scr.storage.unavailable") } }
	end
	local weights, definitions = {}, {}
	for _, item in (state.content or {}).items or {} do
		weights[item.id], definitions[item.id] = item.weightMilli or 0, item
	end
	local names = state.names or {}
	local function label(id: string): string
		return names[id] or id
	end
	local used, slots, weight, limit = usage(warehouse, weights)
	local bagUsed, bagSlots, bagWeight, bagLimit = usage(bag, weights)
	local roles = (state.settlement and state.settlement.roles) or {}
	local member = roles[state.actorId] ~= nil
	local deposit = state.mode ~= "withdraw"
	local rows: { any } = {
		{ text = L.text(locale, "scr.storage.capacity", used, slots, weight, limit) },
		{ text = L.text(locale, "scr.storage.bag", bagUsed, bagSlots, bagWeight, bagLimit) },
		{ text = L.text(locale, if member then "scr.storage.member" else "scr.storage.visitor") },
		{
			text = L.text(locale, if deposit then "scr.storage.mode_bag" else "scr.storage.mode_storage"),
			onClick = act.mode,
		},
		{
			text = L.text(locale, "scr.storage.filter", L.text(locale, "scr.storage.cat_" .. (state.filter or "all"))),
			onClick = act.filter,
		},
	}
	local source = if deposit then bag else warehouse
	local shown = {}
	for _, row in HUDModel.items(source) do
		local category = S.category(definitions[row.item.catalogId])
		if state.filter == nil or state.filter == "all" or category == state.filter then
			table.insert(shown, row)
		end
	end
	if #shown == 0 then
		local key = if next(source.items) == nil
			then (if deposit then "scr.storage.empty_bag" else "scr.storage.empty_storage")
			else "scr.storage.empty_filter"
		table.insert(rows, { text = L.text(locale, key) })
	end
	-- The picked stack, its stepper, Store/Take and the result sit right under the filter, above the
	-- other stacks, so the move button stays on screen at 360x640 (p105 D5: it was below the fold).
	local listed: { any } = {}
	for _, row in shown do
		local item = row.item
		local text = L.text(locale, "scr.storage.item", label(item.catalogId), item.quantity, row.reserved)
		if item.itemId == state.selected then
			table.insert(rows, { text = "* " .. text })
			if row.available < 1 then
				table.insert(rows, { text = L.text(locale, "scr.storage.locked") })
			elseif state.pending then
				table.insert(rows, { text = L.text(locale, "scr.storage.pending") })
			elseif member then
				local amount = math.clamp(state.quantity or 1, 1, math.min(row.available, S.MAX_MOVE))
				table.insert(rows, {
					text = L.text(locale, "scr.storage.quantity", amount, row.available),
					onClick = act.quantity,
				})
				table.insert(rows, {
					text = L.text(
						locale,
						if deposit then "scr.storage.deposit" else "scr.storage.withdraw",
						amount,
						label(item.catalogId)
					),
					onClick = function()
						act.move(if deposit then "transfer-deposit" else "transfer-withdraw", item.itemId, amount)
					end,
				})
			end
		else
			table.insert(listed, {
				text = text,
				onClick = if member
					then function()
						act.select(item.itemId)
					end
					else nil,
			})
		end
	end
	if state.status then
		table.insert(rows, { text = state.status })
	end
	for _, row in listed do
		table.insert(rows, row)
	end
	table.insert(rows, { text = L.text(locale, "scr.storage.note") })
	return rows
end

local opener: (() -> ())? = nil

--- Opens the storage sheet once a factory has mounted it; false lets the caller fall back.
function S.show(): boolean
	if opener then
		opener()
	end
	return opener ~= nil
end

function S.factory(ctx: any): any
	local view: any = { mode = "deposit", filter = "all", quantity = 1 }
	local panel: any
	local function rerender()
		panel.render()
	end
	panel = Sheet.mount(ctx, {
		id = "storage",
		name = "Storage",
		title = L.text(ctx.locale, "scr.storage.title"),
		order = 41,
		hidden = true,
		select = function(_extensions: any, packet: any): any
			local snapshots = packet.snapshots or {}
			local shared = snapshots.survivalSettlement or {}
			local survival = snapshots["survival-coop"]
			-- A new snapshot settles (or replays) the in-flight transfer: offer the move again.
			view.pending = false
			return {
				bag = if survival then HUDModel.bag(survival) else nil,
				settlement = shared.settlement,
				warehouse = shared.warehouse,
			}
		end,
		rows = function(state: any): { any }
			local full = table.clone(state or {})
			full.actorId, full.content, full.names = ctx.actorId, ctx.content, ctx.names
			for key, value in view do
				full[key] = value
			end
			return S.rows(ctx.locale, full, {
				mode = function()
					view.mode = if view.mode == "deposit" then "withdraw" else "deposit"
					view.selected, view.quantity, view.status = nil, 1, nil
					rerender()
				end,
				filter = function()
					view.filter = S.FILTERS[(table.find(S.FILTERS, view.filter) or 1) % #S.FILTERS + 1]
					rerender()
				end,
				select = function(id: string)
					view.selected, view.quantity, view.status = id, 1, nil
					rerender()
				end,
				quantity = function()
					local source = if view.mode == "deposit" then full.bag else full.warehouse
					for _, row in HUDModel.items(source) do
						if row.item.itemId == view.selected then
							view.quantity = S.nextQuantity(view.quantity, row.available)
						end
					end
					rerender()
				end,
				move = function(action: string, id: string, amount: number)
					view.pending = true
					rerender()
					local result = ctx.send("survival-coop:" .. action, { id, amount } :: { any })
					local phase = if type(result.data) == "table" then result.data.status else nil
					view.pending = result.ok and (phase == "pending" or phase == "recovering")
					view.status = if not result.ok
						then L.refusal(ctx.locale, result.reason)
						elseif view.pending then L.text(ctx.locale, "scr.storage.pending")
						else L.text(ctx.locale, "scr.storage.done")
					if result.ok and not view.pending then
						view.selected, view.quantity = nil, 1
					end
					rerender()
				end,
			})
		end,
	})
	opener = panel.show
	local destroy = panel.destroy
	panel.destroy = function()
		opener = nil
		destroy()
	end
	return panel
end

return M
