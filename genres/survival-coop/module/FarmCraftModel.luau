--!strict
-- Pure view models for the farming and crafting screens. Inputs are the client packet
-- (`snapshots["survival-coop"]`), the extension snapshots (`home`, `market`) and the
-- generated survival content; nothing here touches the engine.
local Farming = require("../../../core/domain/home/Farming")
local HomeContent = require("../../../core/domain/home/HomeContent")
local HudModel = require("./SurvivalHUDModel")
local M = {}
M.PROCESSES = { "dry", "tan", "polish", "smelt", "ferment", "compost" }
M.INBOX_PAGE = 5
M.MAX_COUNT = 15

function M.genre(packet: any): any
	local snapshots = if type(packet) == "table" then packet.snapshots else nil
	return if type(snapshots) == "table" and type(snapshots["survival-coop"]) == "table"
		then snapshots["survival-coop"]
		else {}
end

function M.bagRows(packet: any): { any }
	return HudModel.items(HudModel.bag(M.genre(packet)))
end

local function count(storage: any, catalogId: string): (number, string?)
	local total = 0
	local ids = {}
	for id, item in (storage and storage.items) or {} do
		if item.catalogId == catalogId then
			total += item.quantity
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return total, ids[1]
end
M.count = count

function M.crops(content: any): { any }
	local list = {}
	for name, crop in HomeContent.crops(content) do
		table.insert(
			list,
			{ id = name, seed = crop.seed, output = crop.output, seconds = crop.seconds, quantity = crop.quantity }
		)
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

-- Placed farm plots in stable id order with their planted state.
function M.plots(home: any, now: number): { any }
	local rows = {}
	for id, placed in (home and home.structures) or {} do
		if placed.kind == "farm-plot" then
			local planted = home.plots and home.plots[id]
			table.insert(rows, {
				id = id,
				position = placed.position,
				planted = planted,
				ready = planted ~= nil and now >= planted.readyAt,
				remaining = if planted then math.max(0, planted.readyAt - now) else 0,
			})
		end
	end
	table.sort(rows, function(a, b)
		return a.id < b.id
	end)
	return rows
end

-- Plots inside the sprayer radius of `center`, nearest first, capped at nine.
function M.areaPlots(plots: { any }, center: any): { any }
	local rows = {}
	for _, plot in plots do
		local dx, dz = plot.position.x - center.position.x, plot.position.z - center.position.z
		local distance = math.sqrt(dx * dx + dz * dz)
		if distance <= Farming.AREA_RADIUS then
			table.insert(rows, { plot = plot, distance = distance })
		end
	end
	table.sort(rows, function(a, b)
		return if a.distance == b.distance then a.plot.id < b.plot.id else a.distance < b.distance
	end)
	while #rows > Farming.AREA_MAX do
		table.remove(rows)
	end
	return rows
end

function M.book(home: any, content: any): { any }
	local rows = {}
	for _, crop in M.crops(content) do
		local entry = Farming.entry(home or {}, crop.id)
		local chosen, open = {}, {}
		for _, effect in Farming.EFFECTS do
			table.insert(if entry.effects[effect] then chosen else open, effect)
		end
		local nextAt = Farming.nextAt(entry.harvests)
		table.insert(rows, {
			crop = crop,
			harvests = entry.harvests,
			rank = Farming.rank(entry.harvests),
			toNext = if nextAt then nextAt - entry.harvests else nil,
			chosen = chosen,
			open = open,
			choices = Farming.choices(entry),
		})
	end
	return rows
end

-- Next-crop preview with one more effect applied.
function M.preview(home: any, crop: any, effect: string): (number, number, number)
	local trial = { cropBook = table.clone((home and home.cropBook) or {}) }
	local entry = Farming.entry(trial, crop.id)
	local effects = table.clone(entry.effects)
	effects[effect] = true
	trial.cropBook[crop.id] = { harvests = entry.harvests, effects = effects }
	return Farming.growSeconds(trial, crop.id, crop.seconds),
		Farming.yield(trial, crop.id, crop.quantity),
		Farming.quality(trial, crop.id)
end

local function find(rows: any, id: string): any
	for _, row in rows or {} do
		if row.id == id then
			return row
		end
	end
	return nil
end

-- Processing rows for one process: each recipe whose primary input the bag holds,
-- with budget and the attribute deltas the processing policy applies.
function M.processing(content: any, packet: any, process: string): { any }
	local policy = find(content.operations, "processing-policy-" .. process)
	local rows = {}
	for _, recipe in content.recipes do
		if string.match(recipe.id, "^([a-z]+)%-") == process then
			local input = recipe.inputs[1]
			for _, bagRow in M.bagRows(packet) do
				local item = bagRow.item
				if item.catalogId == input.item and bagRow.available >= input.quantity then
					local material = item.material
					local budget = if material then material.budget else 3
					local deltas, spend = {}, 0
					for _, effect in (policy and policy.effects) or {} do
						if effect.id == "processing-budget-consumed" then
							spend = effect.value
						elseif effect.unit == "attribute-clamp-0-10" then
							local before = if material then material.attributes[effect.id] or 0 else 0
							table.insert(deltas, {
								id = effect.id,
								before = before,
								after = math.clamp(before + effect.value, 0, 10),
							})
						end
					end
					table.insert(rows, {
						recipe = recipe,
						item = item,
						budget = budget,
						after = budget - spend,
						deltas = deltas,
						history = if material then material.history else "",
						seconds = recipe.craftMillis / 1000,
					})
					break
				end
			end
		end
	end
	return rows
end

-- Recipe preview: the stacks the server reserves (ascending item id), split into main
-- (primary) and support inputs, plus the deterministic output level and return bonus.
function M.recipePreview(content: any, packet: any, recipe: any): any
	local detail = find(content.recipeDetails, recipe.id) or {}
	local primary = detail.primaryInputs or {}
	local rows, ready = {}, true
	local levels, weight = 0, 0
	for _, input in recipe.inputs do
		local need, stacks = input.quantity, {}
		local have = 0
		for _, bagRow in M.bagRows(packet) do
			if bagRow.item.catalogId == input.item and bagRow.available > 0 and need > 0 then
				local take = math.min(need, bagRow.available)
				need -= take
				have += bagRow.available
				table.insert(stacks, { item = bagRow.item, take = take })
			end
		end
		local main = table.find(primary, input.item) ~= nil
		if main then
			for _, stack in stacks do
				local level = if stack.item.material
					then stack.item.material.level
					else tonumber(stack.item.attributes.level) or 0
				levels += level * stack.take
				weight += stack.take
			end
		end
		ready = ready and need == 0
		table.insert(rows, { input = input, main = main, stacks = stacks, missing = need, have = have })
	end
	local bonus = 0
	local paid = (M.genre(packet).progression or {}).paid or {}
	if string.match(recipe.id, "^([a-z]+)%-") and paid.processing_6 then
		bonus = 10
	end
	return {
		rows = rows,
		ready = ready,
		level = if weight > 0 then math.floor(levels / weight) else 0,
		seconds = recipe.craftMillis / 1000,
		output = recipe.outputs[1],
		bonus = bonus,
	}
end

-- Inbox ledger: market claims (returned listings, bought items, sale proceeds) and
-- crafting results (ready output to collect, committed output, cancelled refunds).
function M.inbox(packet: any, market: any): { any }
	local rows = {}
	local claims = (market and market.claims) or {}
	for _, claim in claims do
		local value = claim.value or {}
		table.insert(rows, {
			id = "market:" .. claim.id,
			kind = if value.item then "item" else "coins",
			claim = claim.id,
			catalogId = value.item and value.item.catalogId,
			quantity = value.item and value.item.quantity,
			coins = value.coins,
		})
	end
	local workshop = M.genre(packet).workshop
	local ids = {}
	for id in (workshop and workshop.entries) or {} do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local job = workshop.entries[id].job
		local kind = if job.state == "Ready"
			then "ready"
			elseif job.state == "Committed" then "crafted"
			elseif job.state == "Cancelled" then "refund"
			elseif job.state == "Running" then "running"
			else nil
		if kind then
			local first = job.outputs[1] or job.inputs[1] or {}
			table.insert(rows, {
				id = "job:" .. id,
				kind = kind,
				job = id,
				catalogId = first.catalogId,
				quantity = first.quantity,
				finishAt = job.finishAt,
			})
		end
	end
	return rows
end

function M.page(rows: { any }, page: number): ({ any }, number, number)
	local pages = math.max(1, math.ceil(#rows / M.INBOX_PAGE))
	page = ((page - 1) % pages) + 1
	local out = {}
	for index = (page - 1) * M.INBOX_PAGE + 1, math.min(#rows, page * M.INBOX_PAGE) do
		table.insert(out, rows[index])
	end
	return out, page, pages
end

return M
