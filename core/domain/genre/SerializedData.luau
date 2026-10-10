--!strict
local Contract = require("./Contract")
local Ledger = require("../command/Ledger")
local M = {}
function M.finite(n: any): boolean
	return type(n) == "number" and n == n and math.abs(n) ~= math.huge
end
function M.clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[k] = M.clone(v)
	end
	return copy
end
function M.data(value: any): boolean
	local seen: { [any]: boolean } = {}
	local function walk(item: any, depth: number): boolean
		local kind = type(item)
		if kind == "number" then
			return M.finite(item)
		end
		if kind == "string" then
			return #item <= 256
		end
		if kind == "boolean" then
			return true
		end
		if kind ~= "table" or depth > 16 or seen[item] then
			return false
		end
		seen[item] = true
		local count, numeric, textual = 0, false, false
		for key, child in item do
			count += 1
			if count > 1024 then
				return false
			end
			if type(key) == "number" then
				if key % 1 ~= 0 or key < 1 or key > 1024 then
					return false
				end
				numeric = true
			elseif type(key) == "string" and #key <= 256 then
				textual = true
			else
				return false
			end
			if not walk(child, depth + 1) then
				return false
			end
		end
		if numeric then
			if textual then
				return false
			end
			for i = 1, count do
				if item[i] == nil then
					return false
				end
			end
		end
		seen[item] = nil
		return true
	end
	return walk(value, 1)
end
function M.validateSave(envelope: any, contracts: { Contract.RuntimeContract }): { string }
	if
		type(envelope) ~= "table"
		or not M.data({ version = envelope.version, genres = envelope.genres })
		or envelope.version ~= 1
		or type(envelope.genres) ~= "table"
	then
		return { "save: invalid envelope or unsupported version" }
	end
	local errors: { string } = {}
	local descriptors: { [string]: Contract.RuntimeContract } = {}
	for _, descriptor in contracts do
		descriptors[descriptor.id] = descriptor
	end
	for key in envelope do
		if key ~= "version" and key ~= "genres" and key ~= "commands" then
			table.insert(errors, "save: unknown field " .. tostring(key))
		end
	end
	if envelope.commands ~= nil and not Ledger.valid(envelope.commands, M.data) then
		table.insert(errors, "save: invalid command ledger")
	end
	for id, slice in envelope.genres do
		local descriptor = descriptors[id]
		if
			descriptor == nil
			or type(slice) ~= "table"
			or slice.version ~= descriptor.saveVersion
			or slice.version ~= 1
			or type(slice.data) ~= "table"
		then
			table.insert(errors, "save: invalid slice " .. tostring(id))
		else
			for key in slice do
				if key ~= "version" and key ~= "data" then
					table.insert(errors, id .. ": unknown slice field")
				end
			end
			for _, err in descriptor.validateSave(M.clone(slice.data)) do
				table.insert(errors, id .. ": " .. err)
			end
		end
	end
	table.sort(errors)
	return errors
end
return M
