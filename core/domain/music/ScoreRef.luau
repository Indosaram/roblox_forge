--!strict
-- A shareable score reference is "<scoreId>#<revision>", never a URL. Engine-free.
local M = {}

M.MAX_LENGTH = 160

function M.format(scoreId: string, revision: number): string
	return scoreId .. "#" .. tostring(revision)
end

-- Returns scoreId, revision; or nil, nil, reason. A link is refused with its own reason so the
-- player learns the lookup takes an ID; nothing in the text is ever opened or fetched.
function M.parse(text: any): (string?, number?, string?)
	if type(text) ~= "string" then
		return nil, nil, "score.ref"
	end
	local trimmed = string.match(text, "^%s*(.-)%s*$") :: string
	if #trimmed == 0 or #trimmed > M.MAX_LENGTH then
		return nil, nil, "score.ref"
	end
	local lower = string.lower(trimmed)
	if string.find(lower, "://", 1, true) or string.sub(lower, 1, 4) == "www." or string.find(lower, "[/\\]") then
		return nil, nil, "score.ref_url"
	end
	local scoreId, revision = string.match(trimmed, "^([^#%s]+:score:%d+)#(%d+)$")
	local number = tonumber(revision)
	if scoreId == nil or number == nil or number < 1 or number > 1000000 then
		return nil, nil, "score.ref"
	end
	return scoreId, number, nil
end

-- Share recipient: a numeric user id other than the owner's own. Server and client both apply it.
function M.recipient(actor: string, text: any): (string?, string?)
	local trimmed = if type(text) == "string" then string.match(text, "^%s*(%d+)%s*$") else nil
	if trimmed == nil or #trimmed > 20 then
		return nil, "score.recipient"
	end
	if trimmed == actor then
		return nil, "score.self"
	end
	return trimmed, nil
end

return M
