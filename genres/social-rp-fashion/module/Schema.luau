--!strict
local Types = require("../../../core/domain/genre/Contract")
local M = {}
local slots = { hat = true, top = true, bottom = true, shoes = true, accessory = true }
local function number(value: any, min: number, max: number, integer: boolean): boolean
	return type(value) == "number"
		and value == value
		and value >= min
		and value <= max
		and (not integer or value % 1 == 0)
end
local function id(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 64 and string.match(value, "^[a-z][a-z0-9%-]*$") ~= nil
end
local function keys(data: any, allowed: { [string]: boolean }): boolean
	if type(data) ~= "table" then
		return false
	end
	for key in data do
		if not allowed[key] then
			return false
		end
	end
	return true
end
local function list(data: any, min: number, max: number): boolean
	if type(data) ~= "table" or #data < min or #data > max then
		return false
	end
	local count = 0
	for key in data do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #data then
			return false
		end
		count += 1
	end
	return count == #data
end
function M.validateConfig(data: Types.ConfigData): { string }
	local errors: { string } = {}
	if not keys(data, { round = true, themes = true, catalog = true, startingOwned = true, resultReward = true }) then
		table.insert(errors, "config: unknown fields")
	end
	local round = data.round
	if not keys(round, { minPlayers = true, dressingSeconds = true, votingSeconds = true, resultsSeconds = true }) then
		table.insert(errors, "round: invalid fields")
	end
	if type(round) ~= "table" then
		round = {}
	end
	if not number(round.minPlayers, 2, 32, true) then
		table.insert(errors, "round.minPlayers: invalid")
	end
	for _, key in { "dressingSeconds", "votingSeconds", "resultsSeconds" } do
		if not number(round[key], 0, 86400, false) or round[key] == 0 then
			table.insert(errors, "round." .. key .. ": invalid")
		end
	end
	local themes: { [string]: boolean } = {}
	if not list(data.themes, 1, 64) then
		table.insert(errors, "themes: invalid list")
	else
		for _, theme in data.themes do
			if not id(theme) or themes[theme] then
				table.insert(errors, "themes: invalid or duplicate id")
			else
				themes[theme] = true
			end
		end
	end
	local catalog: { [string]: boolean } = {}
	if not list(data.catalog, 1, 64) then
		table.insert(errors, "catalog: invalid list")
	else
		for _, item in data.catalog do
			if not keys(item, { id = true, slot = true }) then
				table.insert(errors, "catalog: invalid item")
			elseif not id(item.id) or not slots[item.slot] or catalog[item.id] then
				table.insert(errors, "catalog: invalid or duplicate item")
			else
				catalog[item.id] = true
			end
		end
	end
	local owned: { [string]: boolean } = {}
	if not list(data.startingOwned, 0, 64) then
		table.insert(errors, "startingOwned: invalid list")
	else
		for _, itemId in data.startingOwned do
			if not id(itemId) or not catalog[itemId] or owned[itemId] then
				table.insert(errors, "startingOwned: invalid reference")
			else
				owned[itemId] = true
			end
		end
	end
	if not number(data.resultReward, 0, 1e9, true) then
		table.insert(errors, "resultReward: invalid")
	end
	return errors
end
function M.validateSave(data: Types.StateData): { string }
	if not keys(data, { owned = true, equipped = true, balance = true }) then
		return { "save: unknown fields" }
	end
	if not number(data.balance, 0, 1e9, true) then
		return { "balance: invalid" }
	end
	if not list(data.owned, 0, 64) then
		return { "owned: invalid" }
	end
	local owned: { [string]: boolean } = {}
	for _, itemId in data.owned do
		if not id(itemId) or owned[itemId] then
			return { "owned: invalid" }
		end
		owned[itemId] = true
	end
	if not keys(data.equipped, slots) then
		return { "equipped: invalid slots" }
	end
	for _, itemId in data.equipped do
		if not id(itemId) or not owned[itemId] then
			return { "equipped: not owned" }
		end
	end
	return {}
end

return M
