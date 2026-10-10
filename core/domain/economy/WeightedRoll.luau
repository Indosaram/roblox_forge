--!strict
-- WeightedRoll: deterministic weighted selection over ordered (id, weight) entries.

export type Entry = { id: string, weight: number }

local WeightedRoll = {}

-- Double-precision relative rounding scale, not a gameplay-sized epsilon.
local MACHINE_EPSILON = 2 ^ -52

local function validateEntries(entries: { Entry }): number
	if #entries == 0 then
		error("invalid entries: empty")
	end
	local total = 0
	for _, entry in entries do
		if type(entry) ~= "table" or type(entry.id) ~= "string" then
			error("invalid entry")
		end
		local weight = entry.weight
		if type(weight) ~= "number" or weight ~= weight or weight <= 0 or weight == math.huge then
			error("invalid weight")
		end
		total += weight
	end
	if total ~= total or total == math.huge then
		error("invalid entries: weight sum is not finite")
	end
	return total
end

local function checkRoll(roll: number): ()
	if type(roll) ~= "number" or roll ~= roll or roll < 0 or roll >= 1 then
		error("invalid roll")
	end
end

function WeightedRoll.pick(entries: { Entry }, roll: number): string
	local total = validateEntries(entries)
	checkRoll(roll)
	-- Forgive arithmetic drift at decimal boundaries by one relative machine
	-- epsilon. Cap it by both adjacent interval widths: forgiveness cannot
	-- consume an interval or move its boundary past an interior midpoint.
	local cumulative = 0
	for i, entry in entries do
		cumulative += entry.weight
		local share = cumulative / total
		local nextWeight = if i < #entries then entries[i + 1].weight else entry.weight
		local tolerance = math.min(share * MACHINE_EPSILON, math.min(entry.weight, nextWeight) / total / 4)
		if share - tolerance > roll then
			return entry.id
		end
	end
	return entries[#entries].id
end

function WeightedRoll.odds(entries: { Entry }): { [string]: number }
	local total = validateEntries(entries)
	local result: { [string]: number } = {}
	for _, entry in entries do
		result[entry.id] = (result[entry.id] or 0) + entry.weight / total
	end
	return result
end

function WeightedRoll.boost(entries: { Entry }, luckMultiplier: number): { Entry }
	validateEntries(entries)
	if
		type(luckMultiplier) ~= "number"
		or luckMultiplier ~= luckMultiplier
		or luckMultiplier <= 0
		or luckMultiplier == math.huge
	then
		error("invalid luckMultiplier")
	end
	local boosted: { Entry } = {}
	for i, entry in entries do
		-- Index 1 is considered common (base rate); higher indices receive scaled weight.
		local factor = if i == 1 then 1 else luckMultiplier
		local weight = entry.weight * factor
		if weight ~= weight or weight == math.huge then
			error("invalid luckMultiplier: boosted weight is not finite")
		end
		table.insert(boosted, { id = entry.id, weight = weight })
	end
	return boosted
end

return WeightedRoll
