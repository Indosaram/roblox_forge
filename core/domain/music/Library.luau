--!strict
-- One atomic owner aggregate. write(actor, expectedVersion, nextState) is a compare-and-set.
local Score = require("./Score")
local M = {}

function M.new(ports: any): any
	local api = {}
	function api.save(actor: string, scoreId: string?, score: any): any
		local state = ports.read(actor) or { version = 0, scores = {} }
		local changed = Score.copy(state)
		local id = scoreId or (actor .. ":score:" .. tostring(state.version + 1))
		if scoreId and not changed.scores[id] then
			return { ok = false, reason = "score.owner" }
		end
		local entry = changed.scores[id] or { revisions = {}, readers = {} }
		local revision = #entry.revisions + 1
		entry.revisions[revision] = Score.copy(score)
		changed.scores[id] = entry
		changed.version += 1
		local ok = ports.write(actor, state.version, changed)
		return if ok
			then { ok = true, data = { scoreId = id, revision = revision } }
			else { ok = false, reason = "score.conflict" }
	end
	local function find(scoreId: any): (any, string?)
		if type(scoreId) ~= "string" then
			return nil, nil
		end
		local owner = string.match(scoreId, "^(.-):score:%d+$")
		local state = if owner then ports.read(owner) else nil
		return if state then state.scores[scoreId] else nil, owner
	end
	function api.load(scoreId: string, revision: number): any
		local entry = find(scoreId)
		return if entry then Score.copy(entry.revisions[revision]) else nil
	end
	function api.canRead(actor: string, scoreId: string, revision: number): boolean
		local entry, owner = find(scoreId)
		return entry ~= nil
			and entry.revisions[revision] ~= nil
			and (actor == owner or (entry.readers[actor] ~= nil and entry.readers[actor][revision] == true))
	end
	function api.share(actor: string, scoreId: string, revision: number, recipient: string): any
		local entry, owner = find(scoreId)
		if
			not entry
			or owner ~= actor
			or not entry.revisions[revision]
			or type(recipient) ~= "string"
			or recipient == ""
		then
			return { ok = false, reason = "score.owner" }
		end
		local state = ports.read(actor)
		local changed = Score.copy(state)
		local readers = changed.scores[scoreId].readers
		readers[recipient] = readers[recipient] or {}
		readers[recipient][revision] = true
		changed.version += 1
		return if ports.write(actor, state.version, changed)
			then { ok = true, data = { scoreId = scoreId, revision = revision } }
			else { ok = false, reason = "score.conflict" }
	end
	return api
end

return M
