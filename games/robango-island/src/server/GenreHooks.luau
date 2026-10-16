--!strict
-- forge-hooks:1:survival-coop
type Event = { genre: string, name: string, playerId: string?, data: { [string]: any } }
local hooks: { [string]: (Event) -> () } = {}
hooks["survival-coop:OnWaveSpawn"] = function(event)
	print(event.genre, event.name)
end
hooks["survival-coop:OnWaveResolved"] = function(event)
	print(event.genre, event.name)
end
hooks["survival-coop:DefenseBought"] = function(event)
	print(event.genre, event.name)
end
return hooks
