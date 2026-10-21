--!strict
-- DataStore owner aggregate. Every mutation runs inside UpdateAsync's CAS retry;
-- receipts survive ambiguous commits and are never inferred from a callback side effect.
local Score = require("../../../core/domain/music/Score")
local Hash = require("../../../core/domain/music/ChunkHash")
local M = {}
function M.new(config: any): any
	local store = config.dataStoreService:GetDataStore(config.storeName)
	local api = {}
	local function read(owner: string): any
		local ok, value = pcall(function()
			return store:GetAsync(owner)
		end)
		return if ok then value else nil
	end
	local function mutate(owner: string, requestId: string?, fingerprint: string, change: (any) -> any): any
		local ok, state = pcall(function()
			return store:UpdateAsync(owner, function(old: any): any
				local nextState = Score.copy(old or { version = 0, scores = {}, receipts = {} })
				nextState.receipts = nextState.receipts or {}
				if requestId and nextState.receipts[requestId] then
					return nextState
				end
				local result = change(nextState)
				if not result.ok then
					error(result.reason)
				end
				nextState.version += 1
				nextState.lastResult = result
				if requestId then
					nextState.receipts[requestId] = { fingerprint = fingerprint, result = result }
				end
				if #config.encode(nextState) > config.maxStoreBytes then
					error("score.library_full")
				end
				return nextState
			end)
		end)
		if not ok then
			return { ok = false, reason = "score.store_unavailable" }
		end
		if requestId then
			local receipt = state.receipts[requestId]
			if receipt.fingerprint ~= fingerprint then
				return { ok = false, reason = "score.request_conflict" }
			end
			return Score.copy(receipt.result)
		end
		return Score.copy(state.lastResult)
	end
	function api.save(actor: string, scoreId: string?, value: any, requestId: string?): any
		local score, reason = Score.validate(value, config.rules)
		if not score then
			return { ok = false, reason = reason }
		end
		-- JSON object key iteration order is not a receipt identity contract.
		local canonical = { tostring(score.version), tostring(score.tempo) }
		for _, part in score.parts do
			table.insert(canonical, part.instrumentId)
			for _, note in part.notes do
				table.insert(
					canonical,
					string.format("%d,%d,%d,%d", note.startTick, note.durationTicks, note.pitch, note.velocity)
				)
			end
			table.insert(canonical, ";")
		end
		local fingerprint = "save:" .. (scoreId or "") .. ":" .. Hash.digest(table.concat(canonical, "|"))
		return mutate(actor, requestId, fingerprint, function(state)
			local id = scoreId or (actor .. ":score:" .. tostring(state.version + 1))
			if scoreId and not state.scores[id] then
				return { ok = false, reason = "score.owner" }
			end
			local entry = state.scores[id] or { revisions = {}, readers = {} }
			local revision = #entry.revisions + 1
			entry.revisions[revision] = Score.copy(score)
			state.scores[id] = entry
			return { ok = true, data = { scoreId = id, revision = revision } }
		end)
	end
	local function find(scoreId: string): (any, string?)
		local owner = string.match(scoreId, "^(.-):score:%d+$")
		local state = if owner then read(owner) else nil
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
			and (owner == actor or (entry.readers[actor] ~= nil and entry.readers[actor][tostring(revision)] == true))
	end
	function api.share(actor: string, scoreId: string, revision: number, recipient: string, requestId: string?): any
		if type(recipient) ~= "string" or recipient == "" then
			return { ok = false, reason = "score.owner" }
		end
		return mutate(
			actor,
			requestId,
			"share:" .. scoreId .. ":" .. tostring(revision) .. ":" .. recipient,
			function(state)
				local entry = state.scores[scoreId]
				if not entry or not entry.revisions[revision] then
					return { ok = false, reason = "score.owner" }
				end
				entry.readers[recipient] = entry.readers[recipient] or {}
				entry.readers[recipient][tostring(revision)] = true
				return { ok = true, data = { scoreId = scoreId, revision = revision } }
			end
		)
	end
	function api.list(actor: string): any
		local state = read(actor)
		local result = {}
		if state then
			for id, entry in state.scores do
				table.insert(result, { scoreId = id, revision = #entry.revisions })
			end
		end
		table.sort(result, function(a, b)
			return a.scoreId < b.scoreId
		end)
		return result
	end
	return api
end
return M
