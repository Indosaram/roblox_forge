--!strict
-- Merge: plans and applies fusing owned kaiju of one rarity into a higher-rarity result.

export type Rule = { from: string, to: string, count: number, resultId: string }

local Merge = {}

function Merge.plan(owned: { string }, rarityOf: (string) -> string?, rule: Rule): (boolean, { number }?, string?)
	local count = rule.count
	if type(count) ~= "number" or count ~= count or count <= 0 or count % 1 ~= 0 then
		return false, nil, "invalid rule"
	end

	local chosen: { number } = {}
	for index, id in owned do
		if rarityOf(id) == rule.from then
			table.insert(chosen, index)
			if #chosen == count then
				break
			end
		end
	end

	if #chosen < count then
		return false, nil, "not enough"
	end
	return true, chosen, nil
end

function Merge.apply(owned: { string }, indices: { number }, resultId: string): { string }
	local consumed: { [number]: boolean } = {}
	for _, index in indices do
		consumed[index] = true
	end

	local result: { string } = {}
	for index, id in owned do
		if not consumed[index] then
			table.insert(result, id)
		end
	end
	table.insert(result, resultId)
	return result
end

return Merge
