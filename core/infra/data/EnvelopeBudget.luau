--!strict
-- Check the entire final persisted value, including aggregate transfer receipts
-- and storage wrapper metadata. Checking only an envelope does not bound a key.
-- Inject HttpService:JSONEncode in Roblox or serde.encode("json", value) in Lune.
-- Encoding failures intentionally propagate to the persistence boundary's pcall.
local M = {}

M.DEFAULT_MAX_BYTES = 4000000 -- Conservative policy below the published per-key maximum.
M.MAX_BYTES = 4194304
export type Result = { accepted: boolean, errorCode: string?, byteCount: number, maxBytes: number }

function M.check(value: any, encode: (any) -> string, maxBytes: number?): Result
	local maximum = if maxBytes == nil then M.DEFAULT_MAX_BYTES else maxBytes
	assert(
		type(maximum) == "number" and maximum >= 1 and maximum <= M.MAX_BYTES and maximum % 1 == 0,
		"INVALID_BYTE_BUDGET"
	)
	local encoded = encode(value)
	assert(type(encoded) == "string", "INVALID_ENCODED_VALUE")
	local count = #encoded
	return {
		accepted = count <= maximum,
		errorCode = if count > maximum then "PERSISTED_VALUE_TOO_LARGE" else nil,
		byteCount = count,
		maxBytes = maximum,
	}
end

return M
