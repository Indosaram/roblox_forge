--!strict
-- Client panels for the expedition lane. Reached by real input: Menu tiles (Routes, Party,
-- Expedition), a received invite, a hazard banner, a downed state and the return from an
-- expedition. Every decision is the server's: panels send survival-coop:party-action (or the
-- taming companion feed) and render survivalExtensions.expedition from the next snapshot.
local Models = require("./ExpeditionModels")
local Sheet = require("./ExpeditionSheet")
local Text = require("./ExpeditionText")
local M = {}

local function others(): { any }
	local players = game:GetService("Players")
	local list = {}
	for _, other in players:GetPlayers() do
		if other ~= players.LocalPlayer then
			table.insert(list, { id = tostring(other.UserId), name = other.DisplayName })
		end
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

function M.factory(ctx: any): { destroy: () -> () }?
	local locale = ctx.locale
	local players = game:GetService("Players")
	local me = tostring(players.LocalPlayer.UserId)
	local latest: any = nil
	local packet: any = {}
	local routes =
		Sheet.mount(ctx, { name = "ForgeRoutes", title = Text.text(locale, "exp_routes"), dock = "routes", order = 8 })
	local party =
		Sheet.mount(ctx, { name = "ForgeParty", title = Text.text(locale, "exp_party"), dock = "party", order = 9 })
	local expedition = Sheet.mount(
		ctx,
		{ name = "ForgeExpedition", title = Text.text(locale, "exp_routes"), dock = "expedition", order = 10 }
	)
	local popup = Sheet.mount(ctx, { name = "ForgeExpeditionPopup", title = "" })
	local view: { kind: string, route: number?, failure: string?, verb: string? } = { kind = "list" }
	local popupKind: string? = nil
	local seenResults: string? = nil
	local seenArrival: string? = nil
	local shownArrival: string? = nil
	local seenInvites: { [string]: boolean } = {}
	local render: () -> ()

	local function act(verb: string, arg: string): any
		local result = ctx.send(Models.PARTY_ACTION, { verb, arg })
		return if type(result) == "table" then result else { ok = false }
	end
	local function depart(route: number)
		view = { kind = "travel", route = route }
		render()
		local result = act("depart", tostring(route))
		if not result.ok then
			view = { kind = "travel", route = route, failure = result.reason or "travel_failed" }
		end
		render()
	end
	render = function()
		if type(latest) ~= "table" then
			return
		end
		local arrival = latest.arrival
		local arrivalKey = if arrival then arrival.id .. ":" .. arrival.stage else nil
		shownArrival = nil
		if view.kind == "list" and arrivalKey and seenArrival ~= arrivalKey then
			shownArrival = arrivalKey
			-- The arrival names its route's biome (never the raw expedition id).
			local card = (latest.routes or {})[arrival.route]
			arrival = table.clone(arrival)
			arrival.biome = arrival.biome or (if card then card.biome else nil)
			routes.render(Models.travel(locale, arrival.route, nil, function() end, function()
				seenArrival = arrivalKey
				routes.open(false)
				render()
			end, arrival))
			if seenArrival ~= arrivalKey and not routes.gui.Enabled then
				routes.open(true)
			end
		elseif view.kind == "confirm" and view.route then
			local route = view.route :: number
			routes.render(Models.confirm(locale, latest, route, {
				confirm = function()
					depart(route)
				end,
				stay = function()
					view = { kind = "list" }
					render()
				end,
			}))
		elseif view.kind == "travel" and view.route then
			local route = view.route :: number
			routes.render(Models.travel(locale, route, view.failure, function()
				depart(route)
			end, function()
				view = { kind = "list" }
				render()
			end))
		else
			routes.render(Models.routes(locale, latest, ctx.names, function(route)
				view = { kind = "confirm", route = route }
				render()
			end))
		end
		party.render(Models.party(locale, latest, me, others(), function(verb, arg)
			local result = act(verb, arg)
			if not result.ok then
				party.render(Text.text(locale, "exp_party"), {
					{
						kind = "label",
						text = Text.reason(locale, result.reason),
						height = 56,
						name = "PartyRefusal",
					},
				})
			end
		end))
		if latest.tracker then
			if expedition.dock then
				expedition.dock.setAvailable(true)
			end
			if view.verb then
				local verb = view.verb :: string
				expedition.render(Text.text(locale, if verb == "next" then "exp_next" else "exp_home"), {
					{
						kind = "button",
						text = Text.text(locale, "exp_confirm"),
						height = 44,
						name = "TravelConfirm",
						onClick = function()
							view.verb = nil
							local result = act(verb, "")
							if not result.ok then
								expedition.render(Text.text(locale, "exp_routes"), {
									{
										kind = "label",
										text = Text.reason(locale, result.reason),
										height = 56,
										name = "TravelRefusal",
									},
								})
								return
							end
							render()
						end,
					},
					{
						kind = "button",
						text = Text.text(locale, "exp_stay"),
						height = 44,
						name = "TravelStay",
						onClick = function()
							view.verb = nil
							render()
						end,
					},
				})
			else
				expedition.render(Models.expedition(locale, latest, ctx.names, function(verb)
					view.verb = verb
					render()
				end))
			end
		elseif expedition.dock then
			expedition.dock.setAvailable(false)
		end
		-- Popups, highest priority first: knockout, received invite, results, hazard.
		local snapshots = packet.snapshots or {}
		local vitals = snapshots["survival-coop"] and snapshots["survival-coop"].vitals
		local extensions = snapshots.survivalExtensions or {}
		local taming = extensions.taming
		local zone = extensions["death-zone"] and extensions["death-zone"].zone
		local invite = latest.party and latest.party.invites[1]
		local results = latest.results
		if Models.downed(vitals, taming) then
			popupKind = "knockout"
			popup.render(Models.knockout(
				locale,
				vitals or {},
				zone,
				taming,
				latest.now * 1000,
				function(id)
					ctx.send(Models.COMPANION_ACTION, { "feed", id })
				end,
				if latest.tracker
					then function()
						local result = act("home", "")
						if not result.ok then
							popup.render(Text.text(locale, "ko_title"), {
								{
									kind = "label",
									text = Text.reason(locale, result.reason),
									height = 56,
									name = "KnockoutRefusal",
								},
							})
						end
					end
					else nil,
				latest.cargo
			))
			popup.open(true)
		elseif invite and not seenInvites[invite.from .. ":" .. invite.expiresAt] then
			popupKind = "invite"
			popup.render(Models.invite(locale, latest, invite, function(verb, from)
				seenInvites[invite.from .. ":" .. invite.expiresAt] = true
				local result = act(verb, from)
				if result.ok then
					popup.open(false)
				else
					popup.render(Text.text(locale, "exp_party"), {
						{
							kind = "label",
							text = Text.reason(locale, result.reason),
							height = 56,
							name = "InviteRefusal",
						},
					})
				end
			end))
			popup.open(true)
		elseif results and results.status ~= "active" and seenResults ~= results.id then
			popupKind = "results"
			-- Seen once shown: any close (header X or the return button) must not reopen it.
			seenResults = results.id
			popup.render(Models.results(locale, results, ctx.names, function()
				seenResults = results.id
				popup.open(false)
			end, function()
				local result = act("claim", results.id)
				if not result.ok then
					popup.render(Text.text(locale, "exp_results"), {
						{
							kind = "label",
							text = Text.reason(locale, result.reason),
							height = 56,
							name = "ClaimRefusal",
						},
					})
				end
			end))
			popup.open(true)
		elseif latest.hazard then
			if popupKind ~= "hazard" then
				popupKind = "hazard"
				popup.open(true)
			end
			popup.render(Models.hazard(locale, latest.hazard, ctx.names))
		elseif popupKind == "results" and results and results.id == seenResults then
			-- The shown results stay up until the player closes them (X, return, claim); a later
			-- snapshot of the same trip must not dismiss them on its own.
			return
		elseif popupKind == "knockout" or popupKind == "hazard" or popupKind == "results" then
			popupKind = nil
			popup.open(false)
		end
	end
	-- Closing the arrival sheet with its header X acknowledges the arrival exactly like Stay,
	-- so the next snapshot of the same arrival does not reopen it (p36 Studio: X reopened 0.6 s later).
	routes.onClose = function()
		if shownArrival then
			seenArrival = shownArrival
			render()
		end
	end
	local unsubscribe = ctx.onSnapshot(function(snapshot, full)
		local state = snapshot.expedition
		for _, shell in { routes, party } do
			if shell.dock then
				shell.dock.setAvailable(type(state) == "table")
			end
		end
		if type(state) ~= "table" then
			return
		end
		latest, packet = state, full or {}
		render()
	end)
	return {
		destroy = function()
			unsubscribe()
			for _, shell in { routes, party, expedition, popup } do
				shell.gui:Destroy()
			end
		end,
	}
end

return M
