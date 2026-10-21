--!strict
-- One bounded upload per authenticated actor; no RemoteFunction or large command strings.
local Hash = require("./ChunkHash")
local M = {}
M.CHUNK_BYTES = 128 -- hexadecimal wire text stays within Session's 256-byte string limit
function M.hex(bytes: string): string
	return (string.gsub(bytes, ".", function(c)
		return string.format("%02x", string.byte(c))
	end))
end
local function validId(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 64 and string.match(value, "^[%w_-]+$") ~= nil
end
function M.new(rules: any, ttl: number): any
	local pending: { [string]: any } = {}
	local api = {}
	function api.clear(actor: string)
		pending[actor] = nil
	end
	function api.begin(actor: string, id: any, size: any, digest: any, scoreId: any, now: number): any
		if not validId(id) or type(size) ~= "number" or size % 1 ~= 0 or size < 1 or size > rules.maxBytes then
			return { ok = false, reason = "score.bytes" }
		end
		if
			type(digest) ~= "string"
			or #digest ~= 64
			or not string.match(digest, "^[a-f0-9]+$")
			or type(scoreId) ~= "string"
			or #scoreId > 256
		then
			return { ok = false, reason = "score.upload" }
		end
		local old = pending[actor]
		if old and old.expires > now then
			if old.id == id and old.size == size and old.digest == digest and old.scoreId == scoreId then
				return { ok = true }
			end
			return { ok = false, reason = "score.upload_busy" }
		end
		pending[actor] =
			{ id = id, size = size, digest = digest, scoreId = scoreId, expires = now + ttl, chunks = {}, received = 0 }
		return { ok = true }
	end
	local function current(actor: string, id: any, now: number): any
		local upload = pending[actor]
		if upload and upload.expires <= now then
			pending[actor] = nil
			return nil
		end
		return if upload and upload.id == id then upload else nil
	end
	function api.put(actor: string, id: any, index: any, hex: any, now: number): any
		local upload = current(actor, id, now)
		if not upload then
			return { ok = false, reason = "score.upload_missing" }
		end
		local count = math.ceil(upload.size / M.CHUNK_BYTES)
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > count then
			return { ok = false, reason = "score.chunk_index" }
		end
		local expected = math.min(M.CHUNK_BYTES, upload.size - (index - 1) * M.CHUNK_BYTES)
		if type(hex) ~= "string" or #hex ~= expected * 2 or not string.match(hex, "^[a-f0-9]+$") then
			return { ok = false, reason = "score.chunk_bytes" }
		end
		local bytes = string.gsub(hex, "..", function(pair)
			return string.char(tonumber(pair, 16) :: number)
		end)
		if upload.chunks[index] and upload.chunks[index] ~= bytes then
			return { ok = false, reason = "score.chunk_conflict" }
		end
		if not upload.chunks[index] then
			upload.chunks[index] = bytes
			upload.received += #bytes
		end
		return { ok = true }
	end
	function api.finish(actor: string, id: any, now: number): any
		local upload = current(actor, id, now)
		if not upload or upload.received ~= upload.size then
			return { ok = false, reason = "score.upload_incomplete" }
		end
		local text = table.concat(upload.chunks)
		if Hash.digest(text) ~= upload.digest then
			return { ok = false, reason = "score.upload_hash" }
		end
		return { ok = true, text = text, scoreId = upload.scoreId, digest = upload.digest }
	end
	return api
end
return M
