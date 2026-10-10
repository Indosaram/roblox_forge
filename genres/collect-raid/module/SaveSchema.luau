--!strict
local Contract = require("../../../core/domain/genre/Contract")
local Executor = require("../../../core/domain/genre/Executor")
local Schema = require("./Schema")
local bounded, dense, id, keys = Schema.bounded, Schema.dense, Schema.id, Schema.keys
local M = {}
function M.validateSave(saved: Contract.StateData): { string }
	if
		not Executor.data(saved)
		or not keys(saved, { "loop", "team", "tokens" })
		or not id(saved.team)
		or not dense(saved.tokens, 1024)
	then
		return { "save: invalid slice" }
	end
	local data = saved.loop
	if
		not keys(data, {
			"version",
			"coins",
			"creatures",
			"vaultedCreatures",
			"passes",
			"processedPurchases",
			"incubators",
			"tutorial",
			"shieldUntil",
			"lastSeen",
			"questDay",
			"quest",
		}) or data.version ~= 1
	then
		return { "loop: unsupported/invalid save" }
	end
	if not bounded(data.coins, 0, 2 ^ 53 - 1, true) then
		return { "loop: invalid coins" }
	end
	for _, field in { "shieldUntil", "lastSeen", "questDay" } do
		if not bounded(data[field], 0, 1e12) then
			return { "loop: invalid " .. field }
		end
	end
	for _, field in { "creatures", "vaultedCreatures", "processedPurchases", "incubators" } do
		if not dense(data[field], 1024) then
			return { "loop: invalid " .. field }
		end
	end
	for _, field in { "creatures", "vaultedCreatures" } do
		for _, value in data[field] do
			if not id(value) then
				return { "loop: invalid creature" }
			end
		end
	end
	for _, value in data.processedPurchases do
		if type(value) ~= "string" or #value == 0 then
			return { "loop: invalid purchase" }
		end
	end
	for _, inc in data.incubators do
		if not keys(inc, { "sourceId", "readyAt" }) or not id(inc.sourceId) or not bounded(inc.readyAt, 0, 1e12) then
			return { "loop: invalid incubator" }
		end
	end
	if type(data.passes) ~= "table" then
		return { "loop: invalid passes" }
	end
	for key, value in data.passes do
		if type(key) ~= "string" or type(value) ~= "boolean" then
			return { "loop: invalid pass" }
		end
	end
	if
		not keys(data.tutorial, { "index", "completed" })
		or not bounded(data.tutorial.index, 1, 65, true)
		or type(data.tutorial.completed) ~= "boolean"
	then
		return { "loop: invalid tutorial" }
	end
	if
		not keys(data.quest, { "progress", "claimed" })
		or type(data.quest.progress) ~= "table"
		or type(data.quest.claimed) ~= "table"
	then
		return { "loop: invalid quest" }
	end
	for key, value in data.quest.progress do
		if not id(key) or not bounded(value, 0, 1e9, true) then
			return { "loop: invalid quest progress" }
		end
	end
	for key, value in data.quest.claimed do
		if not id(key) or type(value) ~= "boolean" then
			return { "loop: invalid quest claim" }
		end
	end
	for _, token in saved.tokens do
		if not keys(token, { "id", "locked" }) or not id(token.id) or type(token.locked) ~= "boolean" then
			return { "save: invalid token" }
		end
	end
	return {}
end
return M
