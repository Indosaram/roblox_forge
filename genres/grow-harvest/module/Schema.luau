--!strict
local Contract = require("../../../core/domain/genre/Contract")
local GrowHarvest = require("./GrowHarvest")
export type Config = {
	currency: string,
	startingBalance: number,
	plotCount: number,
	crops: { [string]: GrowHarvest.CropConfig },
	seedPrice: { [string]: number },
	startingSeeds: { [string]: number },
}
export type Planted = { plot: number, cropId: string, plantedAt: number }
export type Save = { balance: number, seeds: { [string]: number }, inventory: { [string]: number }, plots: { Planted } }
local M = {}
local LIMIT = 1e9
local function numeric(v: any, lo: number, hi: number, integer: boolean): boolean
	return type(v) == "number" and v == v and v >= lo and v <= hi and (not integer or v % 1 == 0)
end
local function id(v: any): boolean
	return type(v) == "string"
		and #v <= 64
		and string.match(v, "^[a-z][a-z0-9%-]*$") ~= nil
		and not string.find(v, "--", 1, true)
		and string.sub(v, -1) ~= "-"
end
local function keys(v: any, allowed: { [string]: boolean }): boolean
	if type(v) ~= "table" then
		return false
	end
	for k in v do
		if not allowed[k] then
			return false
		end
	end
	return true
end
local function catalog(v: any, check: (any) -> boolean, nonempty: boolean): boolean
	if type(v) ~= "table" then
		return false
	end
	local n = 0
	for k, item in v do
		n += 1
		if n > 64 or not id(k) or not check(item) then
			return false
		end
	end
	return not nonempty or n > 0
end
function M.validateConfig(data: Contract.ConfigData): { string }
	local errors = {}
	local function check(ok: boolean, name: string)
		if not ok then
			table.insert(errors, "grow-harvest config: " .. name)
		end
	end
	check(
		keys(data, {
			currency = true,
			startingBalance = true,
			plotCount = true,
			crops = true,
			seedPrice = true,
			startingSeeds = true,
		}),
		"unknown fields"
	)
	check(data.currency == "Coins", "currency must be Coins")
	check(numeric(data.startingBalance, 0, LIMIT, true), "startingBalance")
	check(numeric(data.plotCount, 1, 64, true), "plotCount")
	local cropsOk = catalog(data.crops, function(crop)
		return keys(crop, { growthSeconds = true, sellPrice = true })
			and numeric(crop.growthSeconds, 0, 86400, false)
			and crop.growthSeconds > 0
			and numeric(crop.sellPrice, 0, LIMIT, true)
	end, true)
	check(cropsOk, "crops")
	check(
		catalog(data.seedPrice, function(v)
			return numeric(v, 1, LIMIT, true)
		end, true),
		"seedPrice"
	)
	check(
		catalog(data.startingSeeds, function(v)
			return numeric(v, 0, LIMIT, true)
		end, false),
		"startingSeeds"
	)
	if cropsOk and type(data.seedPrice) == "table" and type(data.startingSeeds) == "table" then
		for k in data.crops do
			check(data.seedPrice[k] ~= nil, "missing seedPrice " .. k)
		end
		for k in data.seedPrice do
			check(data.crops[k] ~= nil, "unknown seedPrice crop " .. tostring(k))
		end
		for k in data.startingSeeds do
			check(data.crops[k] ~= nil, "unknown startingSeeds crop " .. tostring(k))
		end
	end
	table.sort(errors)
	return errors
end
function M.validateSave(data: Contract.StateData): { string }
	if not keys(data, { balance = true, seeds = true, inventory = true, plots = true }) then
		return { "grow-harvest save: unknown fields" }
	end
	if
		not numeric(data.balance, 0, LIMIT, true)
		or not catalog(data.seeds, function(v)
			return numeric(v, 0, LIMIT, true)
		end, false)
		or not catalog(data.inventory, function(v)
			return numeric(v, 0, LIMIT, true)
		end, false)
		or type(data.plots) ~= "table"
	then
		return { "grow-harvest save: invalid ledger" }
	end
	local n = 0
	local seen: { [number]: boolean } = {}
	for index, planted in data.plots do
		n += 1
		if
			n > 64
			or not numeric(index, 1, #data.plots, true)
			or not keys(planted, { plot = true, cropId = true, plantedAt = true })
			or not numeric(planted.plot, 1, 64, true)
			or seen[planted.plot]
			or not id(planted.cropId)
			or not numeric(planted.plantedAt, 0, 1e12, false)
		then
			return { "grow-harvest save: invalid plots" }
		end
		seen[planted.plot] = true
	end
	if n ~= #data.plots then
		return { "grow-harvest save: sparse plots" }
	end
	return {}
end
M.numeric = numeric
function M.copyConfig(data: Contract.ConfigData): Config
	local source = data :: Config
	local crops: { [string]: GrowHarvest.CropConfig } = {}
	for k, crop in source.crops do
		crops[k] = { growthSeconds = crop.growthSeconds, sellPrice = crop.sellPrice }
	end
	local config: Config = {
		currency = source.currency,
		startingBalance = source.startingBalance,
		plotCount = source.plotCount,
		crops = crops,
		seedPrice = table.clone(source.seedPrice),
		startingSeeds = table.clone(source.startingSeeds),
	}
	return config
end
return M
