--!strict
-- Broadcast: cross-server LiveOps events over a topic transport.
--
-- Servers announce JSON envelopes on the "forge-liveops" topic; every server
-- subscribed to that topic decodes them and dispatches to handlers registered
-- with on(kind, handler). Messages from the announcing server itself are
-- ignored (the origin already handled the event locally). Malformed payloads,
-- wrong versions, and unknown kinds are dropped and counted in `dropped`.
--
-- The JSON encoder/decoder is pure Luau (no HttpService) so the module and its
-- specs run under Lune, and the transport is injected: memoryTransport() for
-- tests, messagingServiceTransport() for live Roblox servers.

local Broadcast = {}
Broadcast.__index = Broadcast

export type Transport = {
	publish: (topic: string, payload: string) -> (boolean, string?),
	subscribe: (topic: string, handler: (payload: string) -> ()) -> () -> (),
}

export type Handler = (data: { [string]: any }) -> ()

export type Envelope = {
	v: number,
	kind: string,
	from: string,
	data: { [string]: any },
}

export type Broadcast = typeof(setmetatable(
	{} :: {
		transport: Transport,
		serverId: string,
		handlers: { [string]: { Handler } },
		dropped: number,
	},
	Broadcast
))

local TOPIC = "forge-liveops"
local MAX_PAYLOAD_BYTES = 1000

-- Pure JSON encoding -------------------------------------------------------

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\b"] = "\\b",
	["\f"] = "\\f",
}

local function encodeString(value: string): string
	local out = string.gsub(value, '[%c"\\]', function(ch: string): string
		local mapped = ESCAPES[ch]
		if mapped ~= nil then
			return mapped
		end
		return string.format("\\u%04x", string.byte(ch))
	end)
	return '"' .. out .. '"'
end

local function encodeNumber(value: number): string
	if value ~= value or value == math.huge or value == -math.huge then
		return "null"
	end
	if value == math.floor(value) and math.abs(value) <= 9007199254740991 then
		return string.format("%d", value)
	end
	return string.format("%.17g", value)
end

local function isArray(value: any): boolean
	local count = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return false
		end
		count += 1
	end
	return count == #value
end

local function encodeValue(value: any): string
	local valueType = type(value)
	if valueType == "nil" then
		return "null"
	elseif valueType == "boolean" then
		return if value then "true" else "false"
	elseif valueType == "number" then
		return encodeNumber(value)
	elseif valueType == "string" then
		return encodeString(value)
	elseif valueType == "table" then
		if isArray(value) then
			local items: { string } = {}
			for _, item in value do
				table.insert(items, encodeValue(item))
			end
			return "[" .. table.concat(items, ",") .. "]"
		end
		local keys: { string } = {}
		for key in value do
			if type(key) == "string" then
				table.insert(keys, key)
			end
		end
		table.sort(keys)
		local fields: { string } = {}
		for _, key in keys do
			table.insert(fields, encodeString(key) .. ":" .. encodeValue(value[key]))
		end
		return "{" .. table.concat(fields, ",") .. "}"
	end
	return "null"
end

-- Pure JSON decoding -------------------------------------------------------

type Cursor = { i: number }

local function skipWhitespace(text: string, cursor: Cursor): ()
	while true do
		local ch = string.sub(text, cursor.i, cursor.i)
		if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
			cursor.i += 1
		else
			break
		end
	end
end

local function decodeString(text: string, cursor: Cursor): string
	cursor.i += 1
	local out: { string } = {}
	while cursor.i <= #text do
		local ch = string.sub(text, cursor.i, cursor.i)
		if ch == '"' then
			cursor.i += 1
			return table.concat(out)
		elseif ch == "\\" then
			local esc = string.sub(text, cursor.i + 1, cursor.i + 1)
			cursor.i += 2
			if esc == "n" then
				table.insert(out, "\n")
			elseif esc == "t" then
				table.insert(out, "\t")
			elseif esc == "r" then
				table.insert(out, "\r")
			elseif esc == "b" then
				table.insert(out, "\b")
			elseif esc == "f" then
				table.insert(out, "\f")
			elseif esc == '"' then
				table.insert(out, '"')
			elseif esc == "\\" then
				table.insert(out, "\\")
			elseif esc == "/" then
				table.insert(out, "/")
			elseif esc == "u" then
				local hex = string.sub(text, cursor.i, cursor.i + 3)
				cursor.i += 4
				local code = tonumber(hex, 16)
				if code == nil then
					error("invalid json: bad unicode escape", 0)
				end
				table.insert(out, utf8.char(code))
			else
				error("invalid json: bad escape", 0)
			end
		else
			table.insert(out, ch)
			cursor.i += 1
		end
	end
	error("invalid json: unterminated string", 0)
end

local function decodeNumber(text: string, cursor: Cursor): number
	local startIndex, endIndex = string.find(text, "^-?%d+%.?%d*[eE]?[+-]?%d*", cursor.i)
	if startIndex == nil or endIndex == nil then
		error("invalid json: bad number", 0)
	end
	local value = tonumber(string.sub(text, startIndex, endIndex))
	if value == nil then
		error("invalid json: bad number", 0)
	end
	cursor.i = endIndex + 1
	return value
end

local function decodeValue(text: string, cursor: Cursor): any
	skipWhitespace(text, cursor)
	local ch = string.sub(text, cursor.i, cursor.i)
	if ch == "{" then
		cursor.i += 1
		local object: { [string]: any } = {}
		skipWhitespace(text, cursor)
		if string.sub(text, cursor.i, cursor.i) == "}" then
			cursor.i += 1
			return object
		end
		while true do
			skipWhitespace(text, cursor)
			if string.sub(text, cursor.i, cursor.i) ~= '"' then
				error("invalid json: expected key", 0)
			end
			local key = decodeString(text, cursor)
			skipWhitespace(text, cursor)
			if string.sub(text, cursor.i, cursor.i) ~= ":" then
				error("invalid json: expected colon", 0)
			end
			cursor.i += 1
			object[key] = decodeValue(text, cursor)
			skipWhitespace(text, cursor)
			local separator = string.sub(text, cursor.i, cursor.i)
			if separator == "," then
				cursor.i += 1
			elseif separator == "}" then
				cursor.i += 1
				return object
			else
				error("invalid json: expected , or }", 0)
			end
		end
	elseif ch == "[" then
		cursor.i += 1
		local array: { any } = {}
		skipWhitespace(text, cursor)
		if string.sub(text, cursor.i, cursor.i) == "]" then
			cursor.i += 1
			return array
		end
		while true do
			table.insert(array, decodeValue(text, cursor))
			skipWhitespace(text, cursor)
			local separator = string.sub(text, cursor.i, cursor.i)
			if separator == "," then
				cursor.i += 1
			elseif separator == "]" then
				cursor.i += 1
				return array
			else
				error("invalid json: expected , or ]", 0)
			end
		end
	elseif ch == '"' then
		return decodeString(text, cursor)
	elseif string.sub(text, cursor.i, cursor.i + 3) == "true" then
		cursor.i += 4
		return true
	elseif string.sub(text, cursor.i, cursor.i + 4) == "false" then
		cursor.i += 5
		return false
	elseif string.sub(text, cursor.i, cursor.i + 3) == "null" then
		cursor.i += 4
		return nil
	end
	return decodeNumber(text, cursor)
end

local function decodeJson(text: string): any
	local cursor: Cursor = { i = 1 }
	local value = decodeValue(text, cursor)
	skipWhitespace(text, cursor)
	if cursor.i <= #text then
		error("invalid json: trailing data", 0)
	end
	return value
end

-- Envelope API -------------------------------------------------------------

--- Encodes the v1 broadcast envelope. Exposed so the CLI can publish the exact
--- same shape Broadcast speaks.
function Broadcast.encodeEnvelope(kind: string, from: string, data: { [string]: any }): string
	return encodeValue({ v = 1, kind = kind, from = from, data = data })
end

--- Decodes a broadcast envelope, returning (nil, reason) for anything that is
--- not exactly the shape encodeEnvelope produces.
function Broadcast.decodeEnvelope(payload: string): (Envelope?, string?)
	local ok, decoded = pcall(decodeJson, payload)
	if not ok then
		return nil, "malformed json"
	end
	if type(decoded) ~= "table" then
		return nil, "not an object"
	end
	if decoded.v ~= 1 then
		return nil, "wrong version"
	end
	if type(decoded.kind) ~= "string" then
		return nil, "missing kind"
	end
	if type(decoded.from) ~= "string" then
		return nil, "missing from"
	end
	if type(decoded.data) ~= "table" then
		return nil, "missing data"
	end
	return { v = 1, kind = decoded.kind, from = decoded.from, data = decoded.data }, nil
end

-- Instance API -------------------------------------------------------------

function Broadcast._receive(self: Broadcast, payload: string): ()
	local envelope = Broadcast.decodeEnvelope(payload)
	if envelope == nil then
		self.dropped += 1
		return
	end
	if envelope.from == self.serverId then
		return
	end
	local handlers = self.handlers[envelope.kind]
	if handlers == nil then
		self.dropped += 1
		return
	end
	-- Snapshot before dispatch: a handler that unsubscribes itself (or another
	-- handler for the same kind) during this loop must not shift the live
	-- array and skip the next handler.
	for _, handler in table.clone(handlers) do
		handler(envelope.data)
	end
end

--- Creates a broadcast bound to one transport and server id.
function Broadcast.new(transport: Transport, serverId: string): Broadcast
	local self = setmetatable({
		transport = transport,
		serverId = serverId,
		handlers = {},
		dropped = 0,
	}, Broadcast)
	transport.subscribe(TOPIC, function(payload: string)
		Broadcast._receive(self, payload)
	end)
	return self
end

--- Registers a handler for a kind and returns a function that unregisters it.
function Broadcast.on(self: Broadcast, kind: string, handler: Handler): () -> ()
	local handlers = self.handlers[kind]
	if handlers == nil then
		handlers = {}
		self.handlers[kind] = handlers
	end
	table.insert(handlers, handler)
	local active = true
	return function()
		if not active then
			return
		end
		active = false
		for index, registered in handlers do
			if registered == handler then
				table.remove(handlers, index)
				break
			end
		end
	end
end

--- Encodes and publishes {v=1, kind, from=serverId, data}. Refuses payloads
--- over 1000 bytes before they reach the transport.
function Broadcast.announce(self: Broadcast, kind: string, data: { [string]: any }): (boolean, string?)
	local payload = Broadcast.encodeEnvelope(kind, self.serverId, data)
	if #payload > MAX_PAYLOAD_BYTES then
		return false, "payload too large"
	end
	local ok, err = self.transport.publish(TOPIC, payload)
	if ok then
		return true, nil
	end
	return false, err or "publish failed"
end

-- Transports ---------------------------------------------------------------

--- In-process transport: publish delivers synchronously to every subscriber
--- of the topic, shared by all Broadcast instances built on this transport.
function Broadcast.memoryTransport(): Transport
	local subscribers: { [string]: { (payload: string) -> () } } = {}
	return {
		publish = function(topic: string, payload: string): (boolean, string?)
			local handlers = subscribers[topic]
			if handlers ~= nil then
				for _, handler in table.clone(handlers) do
					handler(payload)
				end
			end
			return true, nil
		end,
		subscribe = function(topic: string, handler: (payload: string) -> ()): () -> ()
			local handlers = subscribers[topic]
			if handlers == nil then
				handlers = {}
				subscribers[topic] = handlers
			end
			table.insert(handlers, handler)
			return function()
				for index, registered in handlers do
					if registered == handler then
						table.remove(handlers, index)
						break
					end
				end
			end
		end,
	}
end

--- Engine adapter over Roblox MessagingService. Both calls are wrapped in
--- pcall so a Studio session without messaging access degrades gracefully.
--- Not exercised by specs (no Roblox runtime under Lune).
function Broadcast.messagingServiceTransport(messagingService: any): Transport
	return {
		publish = function(topic: string, payload: string): (boolean, string?)
			local ok, err = pcall(function()
				messagingService:PublishAsync(topic, payload)
			end)
			if ok then
				return true, nil
			end
			return false, tostring(err)
		end,
		subscribe = function(topic: string, handler: (payload: string) -> ()): () -> ()
			local connection: any = nil
			pcall(function()
				connection = messagingService:SubscribeAsync(topic, function(message: any)
					handler(message.Data)
				end)
			end)
			return function()
				if connection ~= nil then
					pcall(function()
						connection:Disconnect()
					end)
				end
			end
		end,
	}
end

return Broadcast
