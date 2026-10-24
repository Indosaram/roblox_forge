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
}

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
		{ text = L.text(locale, "scr.arrival.goal", view.objective) },
		{ text = L.text(locale, "scr.arrival.skip_note") },
		{ text = L.text(locale, "scr.arrival.continue"), onClick = act.close },
	}
	if view.canSkip then
		table.insert(rows, { text = L.text(locale, "scr.arrival.skip"), onClick = act.skip })
	end
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
	local capacity = ctx.capacity or (if players then players.MaxPlayers else 16)
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
			if arrivalShown or not tutorial or tutorial.complete then
				return false
			end
			arrivalShown = tutorial.step == "arrive" or tutorial.step == "gather"
			return arrivalShown
		end,
	})

	return {
		panels = panels,
		destroy = function()
			for _, panel in panels do
				panel.destroy()
			end
		end,
	}
end

return M
