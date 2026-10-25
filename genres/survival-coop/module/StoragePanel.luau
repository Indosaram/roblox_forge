--!strict
-- ui.storage: the camp warehouse beside the bag. Capacity (slots and weight) of both containers,
-- who may move items, a category filter, item pick, quantity stepper and Store / Take through the
-- existing transfer-deposit / transfer-withdraw {itemId, quantity} commands; the server re-checks
-- membership, reach and capacity. Reserved stacks and an unsettled transfer lock the move.
-- Rows render through the shared SocialSheet; copy is the scr.storage.* rows of strings.csv.
local Sheet = require("./SocialSheet")
local L = require("./ScreenText")
local HUDModel = require("./SurvivalHUDModel")
local Market = require("./CrossServerMarketPanel")
local M = {}

M.FILTERS = { "all", "material", "food", "gear", "building" }
M.STEPS = { 1, 5, 10, 50, 100 }
-- TransferRuntime accepts 1..1000 units per request.
M.MAX_MOVE = 1000

--- Next quantity on the stepper: the fixed steps up to the stack, then the whole stack, then 1.
function M.nextQuantity(current: number, available: number): number
	local all = math.min(available, M.MAX_MOVE)
	if current >= all then
		return 1
	end
	for _, step in M.STEPS do
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
function M.rows(locale: string, state: any, act: any): { any }
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
		local category = Market.category(definitions[row.item.catalogId])
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
				local amount = math.clamp(state.quantity or 1, 1, math.min(row.available, M.MAX_MOVE))
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
			table.insert(rows, {
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
	table.insert(rows, { text = L.text(locale, "scr.storage.note") })
	return rows
end

local opener: (() -> ())? = nil

--- Opens the storage sheet once a factory has mounted it; false lets the caller fall back.
function M.show(): boolean
	if opener then
		opener()
	end
	return opener ~= nil
end

function M.factory(ctx: any): any
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
			return M.rows(ctx.locale, full, {
				mode = function()
					view.mode = if view.mode == "deposit" then "withdraw" else "deposit"
					view.selected, view.quantity, view.status = nil, 1, nil
					rerender()
				end,
				filter = function()
					view.filter = M.FILTERS[(table.find(M.FILTERS, view.filter) or 1) % #M.FILTERS + 1]
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
							view.quantity = M.nextQuantity(view.quantity, row.available)
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
