--!strict
-- Pure view models for the expedition-lane screens. Each function maps the server snapshot
-- (survivalExtensions.expedition plus the vitals/zone/taming slices) to a title and a flat
-- item list; ExpeditionPanels only renders them. Catalog ids are noted per function.
local Text = require("./ExpeditionText")
local M = {}

M.PARTY_ACTION = "survival-coop:party-action"
M.COMPANION_ACTION = "survival-coop:companion-action"

local ROW, LINE, BODY = 44, 40, 56

local function label(text: string, height: number?, name: string?): any
	return { kind = "label", text = text, height = height or LINE, name = name }
end
local function button(text: string, name: string, onClick: (() -> ())?): any
	return { kind = "button", text = text, height = ROW, name = name, onClick = onClick }
end

local function biome(names: any, id: string?): string
	return if id and names and names["biome_" .. id] then names["biome_" .. id] else id or "?"
end

-- ui.routes: five route cards with gates, stages, missions, capacity and expiry.
function M.routes(locale: string, state: any, names: any, choose: (number) -> ()): (string, { any })
	local items = {}
	for _, card in state.routes do
		table.insert(items, label(Text.text(locale, "exp_route", card.route, biome(names, card.biome)), LINE))
		table.insert(
			items,
			label(Text.text(locale, "exp_route_gate", card.level, card.rank, card.stages, card.missions), LINE)
		)
		table.insert(
			items,
			label(
				Text.text(locale, "exp_route_cap", card.capacity, Text.duration(card.expiresAt - state.now))
					.. if card.ok then "" else " - " .. Text.reason(locale, card.reason),
				BODY
			)
		)
		table.insert(
			items,
			button(Text.text(locale, if card.ok then "exp_choose" else "exp_locked"), "Route-" .. card.route, function()
				choose(card.route)
			end)
		)
	end
	return Text.text(locale, "exp_routes"), items
end

-- ui.depart-confirm: destination, stage, party eligibility, expiry and return destination.
function M.confirm(locale: string, state: any, route: number, actions: any): (string, { any })
	local card = state.routes[route]
	local ready = true
	for _, row in (state.party and state.party.roster) or {} do
		ready = ready and row.ready
	end
	local items = {
		label(
			Text.text(
				locale,
				"exp_depart_body",
				Text.text(locale, if ready then "exp_yes" else "exp_no"),
				Text.duration(if card then card.expiresAt - state.now else 0)
			),
			BODY + 16,
			"DepartBody"
		),
	}
	table.insert(items, button(Text.text(locale, "exp_confirm"), "DepartConfirm", actions.confirm))
	table.insert(items, button(Text.text(locale, "exp_stay"), "DepartStay", actions.stay))
	if card and not card.ok then
		table.insert(items, label(Text.reason(locale, card.reason), BODY, "DepartRefusal"))
	end
	return Text.text(locale, "exp_depart_title", route), items
end

-- ui.travel: connecting state; a refusal or failure keeps the same operation for Retry.
-- After arrival the restored expedition identity and a left/arrived reconciliation show.
function M.travel(
	locale: string,
	route: number,
	failure: string?,
	retry: () -> (),
	back: () -> (),
	arrival: any?
): (string, { any })
	if arrival then
		local items = {
			label(
				Text.text(locale, "travel_arrived", arrival.route, arrival.stage, arrival.id),
				BODY,
				"TravelIdentity"
			),
		}
		if arrival.party then
			table.insert(items, label(Text.text(locale, "travel_crew", #arrival.party.members), LINE, "TravelCrew"))
		end
		local left, came = arrival.left, arrival.arrived
		if left and came then
			table.insert(
				items,
				label(
					Text.text(locale, "travel_reconcile", left.items, left.coins, came.items, came.coins),
					BODY,
					"TravelReconcile"
				)
			)
			local refund = math.max(0, came.coins - left.coins)
			table.insert(
				items,
				label(
					if refund > 0
						then Text.text(locale, "travel_refund", refund)
						elseif came.items < left.items then Text.text(
							locale,
							"travel_missing",
							left.items - came.items
						)
						else Text.text(locale, "travel_match"),
					LINE,
					"TravelRefund"
				)
			)
		end
		table.insert(items, button(Text.text(locale, "exp_stay"), "TravelBack", back))
		return Text.text(locale, "exp_routes"), items
	end
	local items = { label(Text.text(locale, "exp_travel", route), LINE, "TravelState") }
	if failure then
		table.insert(items, button(Text.text(locale, "exp_retry"), "TravelRetry", retry))
		table.insert(items, button(Text.text(locale, "exp_stay"), "TravelBack", back))
		table.insert(items, label(Text.reason(locale, failure), BODY, "TravelRefusal"))
	end
	return Text.text(locale, "exp_routes"), items
end

-- ui.party: roster, readiness, leader, invites, remove/leave/share.
function M.party(
	locale: string,
	state: any,
	me: string,
	others: { any },
	send: (string, string) -> ()
): (string, { any })
	local party = state.party
	local items = {}
	local leader = party.id == nil or party.leader == me
	if party.id == nil then
		table.insert(items, label(Text.text(locale, "party_empty"), BODY, "PartyEmpty"))
	else
		table.insert(items, label(Text.text(locale, "party_members", #party.members, party.capacity), LINE))
	end
	-- Actions first so the primary control stays above the fold on a 339 px landscape phone.
	if leader then
		for _, other in others do
			if not table.find(party.members, other.id) then
				table.insert(
					items,
					button(Text.text(locale, "party_invite", other.name), "Invite-" .. other.id, function()
						send("invite", other.id)
					end)
				)
			end
		end
	end
	if party.id ~= nil then
		if leader then
			for _, card in state.routes do
				if card.ok then
					table.insert(
						items,
						button(Text.text(locale, "party_share", card.route), "Share-" .. card.route, function()
							send("share", tostring(card.route))
						end)
					)
				end
			end
			for _, member in party.members do
				if member ~= me then
					table.insert(
						items,
						button(Text.text(locale, "party_remove", member), "Remove-" .. member, function()
							send("remove", member)
						end)
					)
				end
			end
		end
		table.insert(
			items,
			button(Text.text(locale, "party_leave"), "PartyLeave", function()
				send("leave", "")
			end)
		)
		if party.route then
			table.insert(items, label(Text.text(locale, "party_shared", party.route), LINE, "PartyRoute"))
		end
		for _, row in party.roster or {} do
			local tags = Text.text(locale, if row.ready then "party_ready" else "party_not_ready_tag")
			if row.leader then
				tags = Text.text(locale, "party_leader") .. ", " .. tags
			end
			table.insert(items, label((row.name or row.id) .. " (" .. tags .. ")", LINE, "Member-" .. row.id))
		end
	end
	table.insert(items, label(Text.text(locale, "party_note"), BODY, "PartyNote"))
	return Text.text(locale, "exp_party"), items
end

-- ui.route-invite: inviter, route, validity, expiry, own gate and capacity.
function M.invite(locale: string, state: any, invite: any, send: (string, string) -> ()): (string, { any })
	local card = if invite.route then state.routes[invite.route] else nil
	local gate = if card == nil
		then Text.text(locale, "invite_any")
		elseif card.ok then Text.text(locale, "party_ready")
		else Text.reason(locale, card.reason)
	return Text.text(locale, "invite_title", invite.from),
		{
			label(
				Text.text(
					locale,
					"invite_body",
					if invite.route then tostring(invite.route) else Text.text(locale, "invite_any"),
					invite.members,
					invite.capacity,
					Text.duration(invite.expiresAt - state.now),
					gate
				),
				BODY + 16,
				"InviteBody"
			),
			button(Text.text(locale, "invite_accept"), "InviteAccept", function()
				send("accept", invite.from)
			end),
			button(Text.text(locale, "invite_decline"), "InviteDecline", function()
				send("decline", invite.from)
			end),
			label(Text.text(locale, "party_note"), BODY, "InviteNote"),
		}
end

-- ui.expedition: stage 1-4, both objectives, expiry, locked next stage, return.
function M.expedition(locale: string, state: any, names: any, ask: (string) -> ()): (string, { any })
	local tracker = state.tracker
	local items = {
		label(Text.text(locale, "exp_expires", Text.duration(tracker.expiresAt - state.now)), LINE, "Expiry"),
	}
	-- Actions before the objective rows keep them above the fold on short landscape phones.
	if tracker.unlocked then
		table.insert(
			items,
			button(Text.text(locale, "exp_next"), "ExpeditionNext", function()
				ask("next")
			end)
		)
	else
		table.insert(items, label(Text.text(locale, "exp_next_locked"), BODY, "NextLocked"))
	end
	table.insert(
		items,
		button(Text.text(locale, "exp_home"), "ExpeditionHome", function()
			ask("home")
		end)
	)
	for _, objective in tracker.objectives do
		local target = if names and names[objective.target] then names[objective.target] else objective.target
		table.insert(
			items,
			label(
				Text.text(locale, "exp_objective", objective.action, target, objective.progress, objective.quantity),
				LINE,
				"Objective-" .. objective.id
			)
		)
	end
	return Text.text(locale, "exp_stage", tracker.route, tracker.stage), items
end

-- ui.expedition-results: per-mission XP, coins, trust, first vs repeat, delivery, return.
function M.results(locale: string, results: any, names: any, close: () -> (), claim: (() -> ())?): (string, { any })
	local status = if results.status == "complete"
		then "exp_status_complete"
		elseif results.status == "expired" then "exp_status_expired"
		else "exp_status_return"
	local items = { label(Text.text(locale, status), LINE, "ResultStatus") }
	local delivered = true
	for _, row in results.rows do
		delivered = delivered and row.delivered
		table.insert(
			items,
			label(
				Text.text(
					locale,
					"exp_result_row",
					if names and names[row.mission] then names[row.mission] else row.mission,
					row.xp,
					row.coins,
					row.trust,
					Text.text(locale, if row.repeatClear then "exp_repeat" else "exp_first")
				),
				BODY,
				"Result-" .. row.mission
			)
		)
	end
	if #results.rows == 0 then
		table.insert(items, label(Text.text(locale, "exp_no_results"), LINE, "ResultEmpty"))
	else
		table.insert(
			items,
			label(Text.text(locale, if delivered then "exp_delivered" else "exp_pending"), LINE, "ResultDelivery")
		)
	end
	local ledger = results.ledger
	if ledger and claim and not ledger.claimed then
		table.insert(items, button(Text.text(locale, "exp_claim", ledger.coins, ledger.xp), "ResultsClaim", claim))
	elseif ledger then
		table.insert(items, label(Text.text(locale, "exp_claimed"), LINE, "ResultsClaimed"))
	end
	for _, row in results.contributors or {} do
		table.insert(
			items,
			label(
				Text.text(locale, "exp_contrib", names and names[row.id] or row.id, row.points),
				LINE,
				"Contrib-" .. row.id
			)
		)
	end
	table.insert(items, button(Text.text(locale, "exp_home"), "ResultsClose", close))
	return Text.text(locale, "exp_results"), items
end

-- ui.hazard: warning title plus details (intensity, volcano rates, boots, refuge).
function M.hazard(locale: string, hazard: any, names: any): (string, { any })
	local kind = if names and names["hazard_" .. hazard.kind] then names["hazard_" .. hazard.kind] else hazard.kind
	local items = { label(Text.text(locale, "hazard_body", hazard.intensity), BODY, "HazardBody") }
	if hazard.resist ~= nil then
		table.insert(
			items,
			label(Text.text(locale, "hazard_resist", hazard.resist, hazard.exposure), LINE, "HazardResist")
		)
	end
	if hazard.volcano then
		table.insert(
			items,
			label(
				Text.text(locale, if hazard.boots then "hazard_boots_on" else "hazard_boots_off"),
				LINE,
				"HazardBoots"
			)
		)
		table.insert(
			items,
			label(
				Text.text(locale, "hazard_volcano", hazard.volcano.health, hazard.volcano.fatigue),
				BODY * 2,
				"HazardVolcano"
			)
		)
	end
	if hazard.refuge then
		table.insert(items, label(Text.text(locale, "hazard_refuge"), LINE, "HazardRefuge"))
	end
	return Text.text(locale, "hazard_title", kind), items
end

-- ui.knockout: player recovery, retained ownership by zone, downed pets with one feed.
function M.knockout(
	locale: string,
	vitals: any,
	zone: string?,
	taming: any,
	nowMillis: number,
	feed: (string) -> (),
	home: (() -> ())?,
	cargo: any?
): (string, { any })
	local items = {
		label(Text.text(locale, "ko_wait", math.ceil((vitals.respawnWaitMillis or 0) / 1000)), LINE, "KnockoutWait"),
	}
	if home and vitals.healthMilli == 0 then
		table.insert(items, button(Text.text(locale, "exp_home"), "KnockoutHome", home))
	end
	table.insert(
		items,
		label(Text.text(locale, if zone == "danger" then "ko_danger" else "ko_safe"), BODY, "KnockoutZone")
	)
	if cargo then
		table.insert(items, label(Text.text(locale, "ko_cargo", cargo.item, cargo.quantity), LINE, "KnockoutCargo"))
	end
	local companions = taming and taming.companions
	local ids = {}
	for id, pet in (companions and companions.pets) or {} do
		if pet.phase == "Downed" then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	for _, id in ids do
		local pet = companions.pets[id]
		table.insert(
			items,
			label(
				Text.text(locale, "ko_pet", pet.species, math.max(0, math.ceil((pet.injuredUntil - nowMillis) / 1000))),
				BODY,
				"KnockoutPet-" .. id
			)
		)
		table.insert(
			items,
			button(Text.text(locale, "ko_feed"), "KnockoutFeed-" .. id, function()
				feed(id)
			end)
		)
	end
	return Text.text(locale, "ko_title"), items
end

-- Downed state lives in the survival vitals; a downed pet counts on its own.
function M.downed(vitals: any?, taming: any?): boolean
	if vitals and vitals.healthMilli == 0 then
		return true
	end
	for _, pet in (taming and taming.companions and taming.companions.pets) or {} do
		if pet.phase == "Downed" then
			return true
		end
	end
	return false
end

return M
