--!strict
-- Schema: pure-Luau validator descriptors for remote payloads. No Roblox APIs.
--
-- Field constructors return descriptor tables. Schema.tuple wraps a list of
-- descriptors into an argument-list validator and Schema.check runs one against
-- a payload. Schema.define builds a per-remote registry on top of that.

local Schema = {}

export type Validator = {
	kind: string,
	min: number?,
	max: number?,
	integer: boolean?,
	maxLen: number?,
	pattern: string?,
	values: { [string]: boolean }?,
	inner: Validator?,
	fields: { Validator }?,
}

export type Registry = {
	validate: (self: Registry, remoteName: string, args: { any }) -> (boolean, string?),
}

local function validateValue(v: Validator, value: any): (boolean, string?)
	local kind = v.kind
	if kind == "optional" then
		if value == nil then
			return true, nil
		end
		local inner = v.inner
		if inner == nil then
			return true, nil
		end
		return validateValue(inner, value)
	elseif kind == "number" then
		if type(value) ~= "number" then
			return false, "expected number"
		end
		-- NaN and +-inf are never valid payload numbers.
		if value ~= value or value == math.huge or value == -math.huge then
			return false, "out of range"
		end
		if v.integer == true and value % 1 ~= 0 then
			return false, "expected integer"
		end
		local min = v.min
		if min ~= nil and value < min then
			return false, "out of range"
		end
		local max = v.max
		if max ~= nil and value > max then
			return false, "out of range"
		end
		return true, nil
	elseif kind == "string" then
		if type(value) ~= "string" then
			return false, "expected string"
		end
		local maxLen = v.maxLen
		if maxLen ~= nil and #value > maxLen then
			return false, "too long"
		end
		local pattern = v.pattern
		if pattern ~= nil and string.match(value, pattern) == nil then
			return false, "pattern mismatch"
		end
		return true, nil
	elseif kind == "boolean" then
		if type(value) ~= "boolean" then
			return false, "expected boolean"
		end
		return true, nil
	elseif kind == "enum" then
		if type(value) ~= "string" then
			return false, "expected string"
		end
		local values = v.values
		if values == nil or not values[value] then
			return false, "not in enum"
		end
		return true, nil
	end
	return false, "invalid descriptor"
end

function Schema.number(opts: { min: number?, max: number?, integer: boolean? }?): Validator
	local o = opts
	return {
		kind = "number",
		min = if o ~= nil then o.min else nil,
		max = if o ~= nil then o.max else nil,
		integer = if o ~= nil then o.integer else nil,
	}
end

function Schema.string(opts: { maxLen: number?, pattern: string? }?): Validator
	local o = opts
	return {
		kind = "string",
		maxLen = if o ~= nil then o.maxLen else nil,
		pattern = if o ~= nil then o.pattern else nil,
	}
end

function Schema.boolean(): Validator
	return { kind = "boolean" }
end

function Schema.enum(values: { string }): Validator
	local set: { [string]: boolean } = {}
	for _, value in ipairs(values) do
		set[value] = true
	end
	return { kind = "enum", values = set }
end

function Schema.optional(inner: Validator): Validator
	return { kind = "optional", inner = inner }
end

function Schema.tuple(fields: { Validator }): Validator
	return { kind = "tuple", fields = fields }
end

function Schema.check(tupleSchema: Validator, args: { any }): (boolean, string?)
	local fields = tupleSchema.fields
	if fields == nil then
		return false, "invalid descriptor"
	end
	if #args > #fields then
		return false, "too many args"
	end
	for i, field in ipairs(fields) do
		local ok, reason = validateValue(field, args[i])
		if not ok then
			return false, string.format("arg %d: %s", i, reason or "invalid")
		end
	end
	return true, nil
end

function Schema.define(remotes: { [string]: Validator }): Registry
	local registry = {} :: Registry
	function registry.validate(_self: Registry, remoteName: string, args: { any }): (boolean, string?)
		local tupleSchema = remotes[remoteName]
		if tupleSchema == nil then
			return false, "unknown remote: " .. remoteName
		end
		return Schema.check(tupleSchema, args)
	end
	return registry
end

return Schema
