--!strict
-- ui.direct-trade: invite a same-server player, edit my escrow offer (exact stack with its
-- attributes, quantity, shellmoney), see both offers and both confirmations at the current
-- revision, confirm or cancel. Any offer change clears both confirmations server-side.
local Sheet = require("./SocialSheet")
local L = require("./SocialLocale")
local M = {}

function M.describe(locale: string, offer: any, name: (string) -> string): string
	local parts = {}
	if offer and offer.item then
		local item = offer.item
		table.insert(
			parts,
			L.text(
				locale,
				"trade.item",
				name(item.catalogId),
				item.quantity,
				math.floor((item.qualityMilli or 0) / 1000),
				math.floor((item.durabilityMilli or 0) / 1000),
				(item.attributes and item.attributes.level) or 0
			)
		)
	end
	if offer and offer.coins and offer.coins > 0 then
		table.insert(parts, L.text(locale, "trade.coins", offer.coins))
	end
	return if #parts == 0 then L.text(locale, "trade.nothing") else table.concat(parts, " + ")
end

-- state = { trade, peers, last, actorId, draft = { itemId, quantity, coins, choices }, status }
function M.rows(locale: string, state: any, act: any, name: (string) -> string): { any }
	local rows: { any } = {}
	local trade = state.trade
	if state.last and not trade then
		table.insert(rows, {
			text = if state.last.status == "settled"
				then L.text(locale, "trade.settled")
				else L.text(locale, "trade.cancelled", L.refusal(locale, state.last.reason)),
		})
	end
	if not trade then
		if #(state.peers or {}) == 0 then
			table.insert(rows, { text = L.text(locale, "trade.nobody") })
		end
		for _, peer in state.peers or {} do
			table.insert(rows, {
				text = L.text(locale, "trade.invite", name(peer)),
				onClick = function()
					act.open(peer)
				end,
			})
		end
		if state.status then
			table.insert(rows, { text = state.status })
		end
		return rows
	end
	local other = if trade.participants[1] == state.actorId then trade.participants[2] else trade.participants[1]
	table.insert(rows, { text = L.text(locale, "trade.with", name(other), trade.revision) })
	table.insert(rows, { text = L.text(locale, "trade.yours", M.describe(locale, trade.offers[state.actorId], name)) })
	table.insert(rows, { text = L.text(locale, "trade.theirs", M.describe(locale, trade.offers[other], name)) })
	table.insert(rows, {
		text = L.text(
			locale,
			"trade.confirmed",
			L.text(locale, if trade.confirmed[state.actorId] then "yes" else "no"),
			L.text(locale, if trade.confirmed[other] then "yes" else "no")
		),
	})
	table.insert(rows, { text = L.text(locale, "trade.changes") })
	local draft = state.draft
	local choice = draft.choice
	table.insert(rows, {
		text = L.text(
			locale,
			"trade.pick",
			if choice then choice.label .. " x" .. choice.available else L.text(locale, "trade.nothing")
		),
		onClick = act.cycleItem,
	})
	table.insert(rows, { text = L.text(locale, "trade.qty", draft.quantity), onClick = act.moreQuantity })
	table.insert(rows, { text = L.text(locale, "trade.coins_step", draft.coins), onClick = act.moreCoins })
	table.insert(rows, { text = L.text(locale, "trade.update"), onClick = act.offer })
	if state.status then
		table.insert(rows, { text = state.status })
	end
	table.insert(rows, { text = L.text(locale, "trade.confirm"), onClick = act.confirm })
	table.insert(rows, { text = L.text(locale, "trade.cancel"), onClick = act.cancel })
	return rows
end

function M.factory(ctx: any): any
	local CampModel = require("./CampPanelModel")
	local status: string? = nil
	local draft: any = { quantity = 1, coins = 0, choice = nil }
	local choices: { any } = {}
	local panel: any
	local function name(id: string): string
		return if ctx.names and ctx.names[id] then ctx.names[id] else id
	end
	local function report(result: any)
		status = if result.ok then nil else L.refusal(ctx.locale, result.reason)
		panel.render()
	end
	panel = Sheet.mount(ctx, {
		id = "direct-trade",
		name = "DirectTrade",
		title = L.text(ctx.locale, "trade.title"),
		order = 11,
		select = function(extensions: any, packet: any): any
			choices = CampModel.choices(ctx.locale, packet)
			draft.choice = if draft.choice then CampModel.select(choices, draft.choice.itemId) else choices[1]
			return extensions.trade
		end,
		-- An incoming invitation opens the sheet for the invited player.
		autoOpen = function(state: any): boolean
			return state ~= nil
				and state.trade ~= nil
				and state.trade.revision == 0
				and state.trade.participants[2] == ctx.actorId
		end,
		rows = function(state: any): { any }
			local view = table.clone(state or { peers = {} })
			view.actorId, view.draft, view.status = ctx.actorId, draft, status
			return M.rows(ctx.locale, view, {
				open = function(peer: string)
					report(ctx.send("survival-coop:trade-open", { peer }))
				end,
				cycleItem = function()
					local nextId = CampModel.cycle(choices, if draft.choice then draft.choice.itemId else nil, 1)
					draft.choice, draft.quantity = CampModel.select(choices, nextId), 1
					panel.render()
				end,
				moreQuantity = function()
					local most = if draft.choice then draft.choice.available else 1
					draft.quantity = draft.quantity % most + 1
					panel.render()
				end,
				moreCoins = function()
					draft.coins += 10
					panel.render()
				end,
				offer = function()
					local trade = state.trade
					report(ctx.send("survival-coop:trade-offer", {
						trade.tradeId,
						{
							revision = trade.revision,
							itemId = if draft.choice then draft.choice.itemId else nil,
							quantity = if draft.choice then draft.quantity else nil,
							coins = draft.coins,
						},
					}))
				end,
				confirm = function()
					report(ctx.send("survival-coop:trade-confirm", { state.trade.tradeId, state.trade.revision }))
				end,
				cancel = function()
					report(ctx.send("survival-coop:trade-cancel", { state.trade.tradeId }))
				end,
			}, name)
		end,
	})
	return panel
end

return M
