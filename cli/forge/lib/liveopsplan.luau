--!strict
-- LiveOpsPlan: pure payload planning for `forge liveops push`. Builds the
-- Open Cloud PublishMessage request (URL + JSON body) and validates the
-- universe id and the 1024-byte message limit. No IO or network happens here;
-- the command owns reading a pack's YAML and calling net.request.

local serde = require("@lune/serde")

local M = {}

export type Publish = {
	url: string,
	body: string,
}

local MAX_MESSAGE_BYTES = 1024

--- Open Cloud PublishMessage endpoint for a universe. Exposed so the dry-run
--- can render the URL even when the universe id is still unset (0).
function M.publishUrl(universeId: number): string
	return string.format("https://apis.roblox.com/cloud/v2/universes/%d/:publishMessage", universeId)
end

--- JSON body for PublishMessage: {"topic":..., "message":...}.
function M.buildBody(topic: string, message: string): string
	return serde.encode("json", { topic = topic, message = message })
end

--- Builds the publish request. Returns (nil, reason) for a non-positive or
--- non-integer universe id, or when the message exceeds 1024 bytes.
function M.buildPublish(universeId: number, topic: string, message: string): (Publish?, string?)
	if type(universeId) ~= "number" or universeId <= 0 or universeId >= math.huge or universeId % 1 ~= 0 then
		return nil, "universeId must be a positive integer"
	end
	if type(message) ~= "string" then
		return nil, "message must be a string"
	end
	if type(topic) ~= "string" or topic == "" or #topic > 80 then
		return nil, "topic must contain 1 to 80 bytes"
	end
	if #message > MAX_MESSAGE_BYTES then
		return nil, "message exceeds 1024 bytes"
	end
	return { url = M.publishUrl(universeId), body = M.buildBody(topic, message) }, nil
end

return M
