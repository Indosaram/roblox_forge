--!strict
-- Replayable command journal. Pure Luau: no Lune or Roblox APIs.
local Ledger = require("./Ledger")
local SerializedData = require("../genre/SerializedData")

local M = {}

M.schemaVersion = 1

export type Kind = "command" | "advance" | "join" | "leave" | "save" | "reload"
export type Meta = { seed: number, genre: string?, scenario: string?, pack: string? }
export type Entry = {
	kind: Kind,
	actor: string?,
	action: string?,
	args: { any }?,
	requestId: string?,
	atMillis: number,
}
export type Journal = {
	meta: Meta,
	entries: { Entry },
	stateHash: string?,
	record: (self: Journal, entry: Entry) -> (),
	finish: (self: Journal, stateHash: string) -> (),
}

local KINDS = { command = true, advance = true, join = true, leave = true, save = true, reload = true }
local ENTRY_FIELDS = { kind = true, actor = true, action = true, args = true, requestId = true, atMillis = true }
local META_FIELDS = { seed = true, genre = true, scenario = true, pack = true }
local TWO32 = 4294967296

-- FNV-1a 64 over two 32-bit lanes; returns 16 lowercase hex digits.
function M.fnv1a64(text: string): string
	local hi, lo = 0xcbf29ce4, 0x84222325
	for i = 1, #text do
		lo = bit32.bxor(lo, string.byte(text, i))
		-- prime = 2^40 + 0x1b3
		local loProduct = lo * 0x1b3
		local carry = math.floor(loProduct / TWO32)
		hi = (hi * 0x1b3 + carry + bit32.lshift(lo, 8)) % TWO32
		lo = loProduct % TWO32
	end
	return string.format("%08x%08x", hi, lo)
end

function M.hash(value: any): string
	return M.fnv1a64(Ledger.canonical(value))
end

local function optionalString(value: any): boolean
	return value == nil or (type(value) == "string" and #value <= 256)
end

local function isArray(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	for key in value do
		if type(key) ~= "number" then
			return false
		end
	end
	return true
end

local function validateMeta(meta: any)
	if type(meta) ~= "table" then
		error("journal: meta must be a table", 0)
	end
	for key in meta do
		if not META_FIELDS[key] then
			error("journal: unknown meta field " .. tostring(key), 0)
		end
	end
	if not SerializedData.finite(meta.seed) or meta.seed % 1 ~= 0 then
		error("journal: meta.seed must be a finite integer", 0)
	end
	if not optionalString(meta.genre) or not optionalString(meta.scenario) or not optionalString(meta.pack) then
		error("journal: meta.genre, meta.scenario and meta.pack must be short strings", 0)
	end
end

local function validateEntry(entry: any)
	if type(entry) ~= "table" then
		error("journal: entry must be a table", 0)
	end
	for key in entry do
		if not ENTRY_FIELDS[key] then
			error("journal: unknown entry field " .. tostring(key), 0)
		end
	end
	if not KINDS[entry.kind] then
		error("journal: invalid entry kind " .. tostring(entry.kind), 0)
	end
	if not SerializedData.finite(entry.atMillis) or entry.atMillis < 0 or entry.atMillis % 1 ~= 0 then
		error("journal: atMillis must be a non-negative integer", 0)
	end
	if not optionalString(entry.actor) or not optionalString(entry.action) or not optionalString(entry.requestId) then
		error("journal: actor, action and requestId must be short strings", 0)
	end
	if entry.args ~= nil and (not isArray(entry.args) or not SerializedData.data(entry.args)) then
		error("journal: args must be serializable array data", 0)
	end
end

local function validateStateHash(stateHash: any)
	if type(stateHash) ~= "string" or #stateHash == 0 or #stateHash > 256 then
		error("journal: stateHash must be a non-empty short string", 0)
	end
end

local Methods = {}
Methods.__index = Methods

function Methods.record(self: any, entry: any)
	if self.stateHash ~= nil then
		error("journal: cannot record after finish", 0)
	end
	validateEntry(entry)
	table.insert(self.entries, SerializedData.clone(entry))
end

function Methods.finish(self: any, stateHash: any)
	if self.stateHash ~= nil then
		error("journal: already finished", 0)
	end
	validateStateHash(stateHash)
	self.stateHash = stateHash
end

function M.new(meta: Meta): Journal
	validateMeta(meta)
	local journal = { meta = SerializedData.clone(meta), entries = {}, stateHash = nil }
	return (setmetatable(journal, Methods) :: any) :: Journal
end

-- Canonical JSON-like text (sorted keys, arrays for dense numeric tables).
local function encodeString(text: string): string
	local escaped = string.gsub(text, '[%c"\\]', function(char: string): string
		if char == '"' then
			return '\\"'
		elseif char == "\\" then
			return "\\\\"
		end
		return string.format("\\u%04x", string.byte(char))
	end)
	return '"' .. escaped .. '"'
end

local function encodeValue(value: any): string
	local kind = type(value)
	if kind == "string" then
		return encodeString(value)
	elseif kind == "boolean" then
		return if value then "true" else "false"
	elseif kind == "number" then
		if not SerializedData.finite(value) then
			error("journal: non-finite number", 0)
		end
		if value % 1 == 0 and math.abs(value) < 2 ^ 53 then
			return string.format("%d", value)
		end
		return string.format("%.17g", value)
	elseif kind == "table" then
		if isArray(value) then
			local parts = {}
			for i = 1, #value do
				table.insert(parts, encodeValue(value[i]))
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for key in value do
			if type(key) ~= "string" then
				error("journal: mixed table keys", 0)
			end
			table.insert(keys, key)
		end
		table.sort(keys)
		local parts = {}
		for _, key in keys do
			table.insert(parts, encodeString(key) .. ":" .. encodeValue(value[key]))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("journal: unsupported value type " .. kind, 0)
end

local function body(journal: any): any
	return { meta = journal.meta, entries = journal.entries, stateHash = journal.stateHash }
end

function M.encode(journal: Journal): string
	local value = body(journal)
	validateMeta(value.meta)
	for _, entry in value.entries do
		validateEntry(entry)
	end
	if value.stateHash ~= nil then
		validateStateHash(value.stateHash)
	end
	return encodeValue({ schemaVersion = M.schemaVersion, hash = M.hash(value), journal = value })
end

local function parse(text: string): any
	local pos = 1
	local function fail(message: string): never
		error("journal: decode " .. message .. " at " .. pos, 0)
	end
	local function skip()
		pos = string.find(text, "[^ \t\r\n]", pos) or #text + 1
	end
	local parseValue: () -> any
	local function parseString(): string
		pos += 1
		local parts = {}
		while true do
			local char = string.sub(text, pos, pos)
			if char == "" then
				fail("unterminated string")
			elseif char == '"' then
				pos += 1
				return table.concat(parts)
			elseif char == "\\" then
				local esc = string.sub(text, pos + 1, pos + 1)
				if esc == '"' or esc == "\\" or esc == "/" then
					table.insert(parts, esc)
					pos += 2
				elseif esc == "u" then
					local hex = string.sub(text, pos + 2, pos + 5)
					local code = if string.match(hex, "^%x%x%x%x$") then tonumber(hex, 16) else nil
					if code == nil or code > 255 then
						fail("bad escape")
					end
					table.insert(parts, string.char(code :: number))
					pos += 6
				else
					fail("bad escape")
				end
			else
				table.insert(parts, char)
				pos += 1
			end
		end
	end
	function parseValue(): any
		skip()
		local char = string.sub(text, pos, pos)
		if char == "{" then
			pos += 1
			local result = {}
			skip()
			if string.sub(text, pos, pos) == "}" then
				pos += 1
				return result
			end
			while true do
				skip()
				if string.sub(text, pos, pos) ~= '"' then
					fail("expected key")
				end
				local key = parseString()
				skip()
				if string.sub(text, pos, pos) ~= ":" then
					fail("expected colon")
				end
				pos += 1
				if result[key] ~= nil then
					fail("duplicate key")
				end
				result[key] = parseValue()
				skip()
				local sep = string.sub(text, pos, pos)
				pos += 1
				if sep == "}" then
					return result
				elseif sep ~= "," then
					fail("expected , or }")
				end
			end
		elseif char == "[" then
			pos += 1
			local result = {}
			skip()
			if string.sub(text, pos, pos) == "]" then
				pos += 1
				return result
			end
			while true do
				table.insert(result, parseValue())
				skip()
				local sep = string.sub(text, pos, pos)
				pos += 1
				if sep == "]" then
					return result
				elseif sep ~= "," then
					fail("expected , or ]")
				end
			end
		elseif char == '"' then
			return parseString()
		elseif string.sub(text, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(text, pos, pos + 4) == "false" then
			pos += 5
			return false
		end
		local number = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		local value = if number then tonumber(number) else nil
		if value == nil then
			fail("unexpected token")
		end
		pos += #(number :: string)
		return value
	end
	local value = parseValue()
	skip()
	if pos <= #text then
		fail("trailing text")
	end
	return value
end

function M.decode(text: string): Journal
	if type(text) ~= "string" then
		error("journal: decode expects text", 0)
	end
	local envelope = parse(text)
	if type(envelope) ~= "table" or envelope.schemaVersion ~= M.schemaVersion then
		error("journal: unsupported schemaVersion", 0)
	end
	for key in envelope do
		if key ~= "schemaVersion" and key ~= "hash" and key ~= "journal" then
			error("journal: unknown envelope field " .. tostring(key), 0)
		end
	end
	local value = envelope.journal
	if type(value) ~= "table" or not isArray(value.entries) then
		error("journal: malformed journal body", 0)
	end
	for key in value do
		if key ~= "meta" and key ~= "entries" and key ~= "stateHash" then
			error("journal: unknown journal field " .. tostring(key), 0)
		end
	end
	if type(envelope.hash) ~= "string" or envelope.hash ~= M.hash(value) then
		error("journal: hash mismatch", 0)
	end
	local journal = M.new(value.meta)
	for _, entry in value.entries do
		journal:record(entry)
	end
	if value.stateHash ~= nil then
		journal:finish(value.stateHash)
	end
	return journal
end

return M
