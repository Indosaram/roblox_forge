--!strict
local M = {}
function M.finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end
function M.id(value: any): boolean
	return type(value) == "string" and #value <= 64 and string.match(value, "^[a-z][a-z0-9%-]*$") ~= nil
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
function M.validateRuntime(raw: any): { string }
	if type(raw) ~= "table" then
		return { "runtime: expected descriptor" }
	end
	local errors: { string } = {}
	if raw.api ~= 1 or raw.configVersion ~= 1 or raw.saveVersion ~= 1 then
		table.insert(errors, "runtime: unsupported version")
	end
	if not M.id(raw.id) then
		table.insert(errors, "runtime: invalid id")
	end
	for _, field in { "validateConfig", "validateSave", "create" } do
		if type(raw[field]) ~= "function" then
			table.insert(errors, "runtime: missing " .. field)
		end
	end
	local sets: { [string]: { [string]: boolean } } = {}
	for _, field in { "events", "hooks" } do
		local seen: { [string]: boolean } = {}
		sets[field] = seen
		if not M.dense(raw[field], 1024) then
			table.insert(errors, field .. ": expected dense list")
		else
			for _, name in raw[field] do
				if type(name) ~= "string" or #name > 64 or string.match(name, "^[%a][%w%-]*$") == nil or seen[name] then
					table.insert(errors, field .. ": invalid/duplicate identity")
				else
					seen[name] = true
				end
			end
		end
	end
	for hook in sets.hooks do
		if not sets.events[hook] then
			table.insert(errors, "hooks: undeclared event " .. hook)
		end
	end
	local seen: { [string]: boolean } = {}
	if not M.dense(raw.actions, 1024) then
		table.insert(errors, "actions: expected dense list")
	else
		for _, action in raw.actions do
			if type(action) ~= "table" then
				table.insert(errors, "actions: invalid descriptor")
				continue
			end
			if not M.id(action.id) or seen[action.id] then
				table.insert(errors, "actions: invalid/duplicate id")
			else
				seen[action.id] = true
			end
			if action.origin ~= "client" and action.origin ~= "server" then
				table.insert(errors, "actions: invalid origin")
			end
			if not M.dense(action.args, 1024) then
				table.insert(errors, "actions: invalid tuple")
			else
				for _, arg in action.args do
					if not M.validateValidator(arg, 1) then
						table.insert(errors, "actions: invalid schema")
					end
				end
			end
			local rate = action.rate
			if
				type(rate) ~= "table"
				or not M.finite(rate.capacity)
				or not M.finite(rate.refillPerSecond)
				or rate.capacity < 1
				or rate.capacity > 100
				or rate.refillPerSecond <= 0
				or rate.refillPerSecond > 100
			then
				table.insert(errors, "actions: invalid rate")
			end
		end
	end
	if raw.recipe ~= nil then
		local r = raw.recipe
		if
			type(r) ~= "table"
			or not M.id(r.id)
			or type(r.create) ~= "function"
			or (r.validateConfig ~= nil and type(r.validateConfig) ~= "function")
			or not M.dense(r.partners, 64)
			or #r.partners < 2
		then
			table.insert(errors, "recipe: invalid descriptor")
		else
			local partners: { [string]: boolean } = {}
			for _, id in r.partners do
				if not M.id(id) or partners[id] then
					table.insert(errors, "recipe: invalid/duplicate partner")
				else
					partners[id] = true
				end
			end
			if not partners[raw.id] then
				table.insert(errors, "recipe: owner must be partner")
			end
		end
	end
	table.sort(errors)
	return errors
end
function M.validateValidator(v: any, depth: number): boolean
	if type(v) ~= "table" or depth > 16 then
		return false
	end
	if v.kind == "optional" then
		return M.validateValidator(v.inner, depth + 1)
	end
	if v.kind == "boolean" then
		return true
	end
	if v.kind == "object" and type(v.properties) == "table" then
		local count = 0
		for key, descriptor in v.properties do
			if type(key) ~= "string" or #key == 0 or #key > 128 or not M.validateValidator(descriptor, depth + 1) then
				return false
			end
			count += 1
		end
		return count <= 64
	end
	if v.kind == "number" then
		return (v.min == nil or M.finite(v.min))
			and (v.max == nil or M.finite(v.max))
			and (v.min == nil or v.max == nil or v.min <= v.max)
			and (v.integer == nil or type(v.integer) == "boolean")
	end
	if v.kind == "string" then
		return (v.maxLen == nil or (M.finite(v.maxLen) and v.maxLen >= 0 and v.maxLen <= 256 and v.maxLen % 1 == 0))
			and (v.pattern == nil or (type(v.pattern) == "string" and pcall(string.match, "", v.pattern)))
	end
	if v.kind == "enum" and type(v.values) == "table" then
		local count = 0
		for key, enabled in v.values do
			if type(key) ~= "string" or #key > 256 or enabled ~= true then
				return false
			end
			count += 1
		end
		return count > 0 and count <= 1024
	end
	return false
end
return M
