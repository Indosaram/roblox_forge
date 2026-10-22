--!strict
-- Home farm rules beyond plant/harvest: crop encyclopedia ranks and specialization,
-- optional fertilizer and the area sprayer. The crop encyclopedia is a separate record
-- from farming proficiency. Thresholds and effect sizes are RECONSTRUCTED
-- (robango-ui-assets-spec ui.crop-book / ui.crop-specialize / ui.farm-area,
-- auxiliary-material-spec "Optional fertilizer").
local M = {}

M.RANKS = { 1, 3, 6, 10, 15 }
M.CHOICE_RANKS = { 1, 3, 5 }
M.EFFECTS = { "yield", "time", "quality" }
M.TIME_FACTOR = 0.9
M.QUALITY_BONUS = 250
M.AREA_RADIUS = 12
M.AREA_MAX = 9
M.AREA_TOOL = "sprinkler"
M.FERTILIZERS = {
	["liquid-fertilizer"] = { crops = nil },
	["fruit-fertilizer"] = { crops = { banana = true, fig = true, apple = true } },
	["stem-fertilizer"] = { crops = { flax = true } },
}
M.FERTILIZER_ORDER = { "liquid-fertilizer", "fruit-fertilizer", "stem-fertilizer" }

function M.rank(harvests: number): number
	local rank = 0
	for index, need in M.RANKS do
		if harvests >= need then
			rank = index
		end
	end
	return rank
end

function M.nextAt(harvests: number): number?
	for _, need in M.RANKS do
		if harvests < need then
			return need
		end
	end
	return nil
end

function M.entry(state: any, crop: string): any
	local book = state.cropBook or {}
	return book[crop] or { harvests = 0, effects = {} }
end

-- Unused specialization choices: one per reached rank 1/3/5 minus effects already chosen.
function M.choices(entry: any): number
	local rank, unlocked, used = M.rank(entry.harvests), 0, 0
	for _, need in M.CHOICE_RANKS do
		if rank >= need then
			unlocked += 1
		end
	end
	for _ in entry.effects do
		used += 1
	end
	return unlocked - used
end

function M.growSeconds(state: any, crop: string, seconds: number): number
	return if M.entry(state, crop).effects.time then math.floor(seconds * M.TIME_FACTOR) else seconds
end

function M.yield(state: any, crop: string, quantity: number): number
	return if M.entry(state, crop).effects.yield then quantity + 1 else quantity
end

function M.quality(state: any, crop: string): number
	return if M.entry(state, crop).effects.quality then 1000 + M.QUALITY_BONUS else 1000
end

function M.recordHarvest(out: any, crop: string)
	local book = table.clone(out.cropBook or {})
	local entry = M.entry(out, crop)
	book[crop] = { harvests = entry.harvests + 1, effects = table.clone(entry.effects) }
	out.cropBook = book
end

function M.handles(action: string): boolean
	return action == "fertilize" or action == "area" or action == "specialize"
end

-- One plot's fertilizer: validates, takes one unit through `take`, applies the effect.
local function fertilize(out: any, plotId: string, kind: string, ctx: any, take: any): string?
	local plot = out.plots[plotId]
	local rule = M.FERTILIZERS[kind]
	if not plot then
		return "EMPTY_PLOT"
	elseif not rule then
		return "UNKNOWN_FERTILIZER"
	elseif plot.fertilizer then
		return "ALREADY_FERTILIZED"
	elseif ctx.now >= plot.readyAt then
		return "ALREADY_READY"
	elseif rule.crops and not rule.crops[plot.crop] then
		return "FERTILIZER_NOT_APPLICABLE"
	end
	local storage, reason = take(out.storage, ctx.catalog, kind, 1)
	if not storage then
		return reason
	end
	out.storage = storage
	local nextPlot = table.clone(plot)
	nextPlot.fertilizer = kind
	if kind == "liquid-fertilizer" then
		nextPlot.readyAt = plot.readyAt - math.floor((plot.readyAt - ctx.now) * 0.2)
	else
		nextPlot.quantity = plot.quantity + 1
	end
	local plots = table.clone(out.plots)
	plots[plotId] = nextPlot
	out.plots = plots
	return nil
end

local function available(storage: any, catalogId: string): number
	local count = 0
	for _, item in storage.items do
		if item.catalogId == catalogId then
			count += item.quantity
		end
	end
	return count
end

-- `out` is already a private copy owned by HomeState.apply.
function M.apply(out: any, action: string, args: any, ctx: any, take: any): (any?, string?)
	if action == "specialize" then
		local effect = args.effect
		if not ctx.crops[args.crop] then
			return nil, "UNKNOWN_CROP_OR_PLOT"
		elseif not table.find(M.EFFECTS, effect) then
			return nil, "UNKNOWN_EFFECT"
		end
		local entry = M.entry(out, args.crop)
		if entry.effects[effect] then
			return nil, "DUPLICATE_EFFECT"
		elseif M.choices(entry) <= 0 then
			return nil, "RANK_LOCKED"
		end
		local book = table.clone(out.cropBook or {})
		local effects = table.clone(entry.effects)
		effects[effect] = true
		book[args.crop] = { harvests = entry.harvests, effects = effects }
		out.cropBook = book
		return out, nil
	elseif action == "fertilize" then
		local refused = fertilize(out, args.plot, args.fertilizer, ctx, take)
		if refused then
			return nil, refused
		end
		return out, nil
	end
	-- area: explicit selection around a center plot, per-plot water + fertilizer.
	local center = out.structures[args.plot]
	if not center or center.kind ~= "farm-plot" then
		return nil, "UNKNOWN_CROP_OR_PLOT"
	end
	if available(out.storage, M.AREA_TOOL) < 1 then
		return nil, "TOOL_REQUIRED"
	end
	local selected, seen = {}, {}
	for id in string.gmatch(type(args.plots) == "string" and args.plots or "", "[^,]+") do
		if not seen[id] then
			seen[id] = true
			table.insert(selected, id)
		end
	end
	if #selected == 0 or #selected > M.AREA_MAX then
		return nil, "AREA_LIMIT"
	end
	local results, applied, first = {}, 0, nil
	for _, id in selected do
		local placed = out.structures[id]
		local reason: string? = nil
		if not placed or placed.kind ~= "farm-plot" then
			reason = "UNKNOWN_CROP_OR_PLOT"
		else
			local dx, dz = placed.position.x - center.position.x, placed.position.z - center.position.z
			if math.sqrt(dx * dx + dz * dz) > M.AREA_RADIUS then
				reason = "OUT_OF_AREA"
			end
		end
		if not reason then
			local trial = table.clone(out)
			local storage, waterReason = take(trial.storage, ctx.catalog, "water", 1)
			if not storage then
				reason = waterReason
			else
				trial.storage = storage
				reason = fertilize(trial, id, args.fertilizer, ctx, take)
				if not reason then
					out.storage, out.plots = trial.storage, trial.plots
					applied += 1
				end
			end
		end
		first = first or reason
		table.insert(results, { plot = id, ok = reason == nil, reason = reason })
	end
	if applied == 0 then
		return nil, first
	end
	out.areaResults = results
	return out, nil
end

return M
