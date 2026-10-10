--!strict
local RaidTarget = {}

function RaidTarget.resolve(teams: { string }, attacker: string, target: any): string?
	local attackerIndex = table.find(teams, attacker)
	if attackerIndex == nil or #teams < 2 then
		return nil
	end
	if target == nil then
		return teams[attackerIndex % #teams + 1]
	end
	if type(target) ~= "string" or target == attacker or table.find(teams, target) == nil then
		return nil
	end
	return target
end

return RaidTarget
