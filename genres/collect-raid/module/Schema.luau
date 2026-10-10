--!strict
local Executor = require("../../../core/domain/genre/Executor")
local M = {}
function M.bounded(value: any, min: number, max: number, integer: boolean?): boolean
	return Executor.finite(value) and value >= min and value <= max and (not integer or value % 1 == 0)
end
function M.dense(value: any, limit: number): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > limit then
			return false
		end
		count += 1
	end
	for i = 1, count do
		if value[i] == nil then
			return false
		end
	end
	return true
end
function M.id(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 64
end
function M.keys(value: any, allowed: { string }): boolean
	if type(value) ~= "table" then
		return false
	end
	for key in value do
		if not table.find(allowed, key) then
			return false
		end
	end
	return true
end
return M
