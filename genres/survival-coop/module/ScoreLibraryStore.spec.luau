--!strict
local Store = require("./ScoreLibraryStore")
local Score = require("../../../core/domain/music/Score")
local Rules = require("../../../core/domain/music/TestCatalog")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local function setup(): (any, any, any)
	local state: any =
		{ values = {}, failRead = false, failWrite = false, ambiguous = false, concurrent = nil, callbacks = 0 }
	local dataStore = {}
	function dataStore:GetAsync(key: string): any
		if state.failRead then
			error("read outage")
		end
		return Score.copy(state.values[key])
	end
	function dataStore:UpdateAsync(key: string, transform: (any) -> any): any
		if state.failWrite then
			error("write outage")
		end
		-- Roblox may retry a transform after a competing commit; the first candidate is discarded.
		state.callbacks += 1
		local nextState = transform(Score.copy(state.values[key]))
		if state.concurrent then
			local compete = state.concurrent
			state.concurrent = nil
			compete()
			state.callbacks += 1
			nextState = transform(Score.copy(state.values[key]))
		end
		state.values[key] = Score.copy(nextState)
		if state.ambiguous then
			state.ambiguous = false
			error("committed but response lost")
		end
		return Score.copy(nextState)
	end
	local service = {
		GetDataStore = function(_self: any, name: string): any
			assert(name == "scores", "named store")
			return dataStore
		end,
	}
	local config = {
		dataStoreService = service,
		storeName = "scores",
		rules = Rules,
		maxStoreBytes = 4000000,
		encode = function(value: any)
			return serde.encode("json", value)
		end,
	}
	return Store.new(config), state, config
end
local function value(): any
	return { version = 1, tempo = 120, parts = { { instrumentId = "piano", notes = {} } } }
end
return {
	["negative ACL and receipt assertions kill removed guards"] = function()
		local source = fs.readFile("genres/survival-coop/module/ScoreLibraryStore.luau")
		local function mutant(old: string, replacement: string): any
			local first, last = string.find(source, old, 1, true)
			assert(first and last, "mutation anchor")
			return luau.load(string.sub(source, 1, first - 1) .. replacement .. string.sub(source, last + 1), {
				environment = {
					require = function(path: string)
						return if string.find(path, "ChunkHash", 1, true)
							then require("../../../core/domain/music/ChunkHash")
							else Score
					end,
				},
			})()
		end
		local store, state, config = setup()
		local id = store.save("a", nil, value(), "original").data.scoreId
		local public = mutant("owner == actor", "true").new(config)
		assert(not store.canRead("b", id, 1) and public.canRead("b", id, 1), "ACL mutant killed")
		local noReceipt = mutant("if requestId and nextState.receipts[requestId] then", "if false then").new(config)
		local before = state.values.a.version
		assert(
			noReceipt.save("a", nil, value(), "original").ok and state.values.a.version == before + 1,
			"receipt mutant duplicates commit"
		)
	end,
	["UpdateAsync retries preserve concurrent revisions and exact revision sharing"] = function()
		local store, state = setup()
		local first = store.save("a", nil, value(), "first")
		assert(first.ok, "initial save")
		local id = first.data.scoreId
		state.concurrent = function()
			assert(store.save("a", id, value(), "competitor").ok, "competing commit")
		end
		local saved = store.save("a", id, value(), "second")
		assert(saved.ok and saved.data.revision == 3 and state.callbacks == 4, "CAS uses latest state")
		assert(not store.canRead("b", id, 1), "private by default")
		assert(store.share("a", id, 2, "b", "share").ok, "owner share")
		assert(
			store.canRead("b", id, 2) and not store.canRead("b", id, 1) and not store.canRead("b", id, 3),
			"exact revision ACL"
		)
		assert(not store.share("b", id, 2, "c").ok and not store.save("b", id, value()).ok, "nonowner refused")
		local copy = store.load(id, 1)
		copy.tempo = 40
		assert(store.load(id, 1).tempo == 120 and #store.list("a") == 1, "detached and list")
	end,
	["ambiguous commit retries once and conflicting receipts cannot overwrite"] = function()
		local store, state = setup()
		state.ambiguous = true
		assert(not store.save("a", nil, value(), "request").ok, "lost response reported")
		local retried = store.save("a", nil, value(), "request")
		assert(
			retried.ok and retried.data.revision == 1 and state.values.a.version == 1,
			"same receipt not another write"
		)
		local changed = value()
		changed.tempo = 150
		assert(
			not store.save("a", nil, changed, "request").ok and state.values.a.version == 1,
			"receipt payload conflict"
		)
		state.failRead = true
		assert(not store.canRead("a", retried.data.scoreId, 1), "read outage fails closed")
		state.failWrite = true
		assert(not store.save("a", nil, value(), "other").ok and state.values.a.version == 1, "write outage no success")
	end,
	["invalid scores and full aggregates refuse without commits"] = function()
		local store, state, config = setup()
		local invalid = value()
		invalid.tempo = 999
		assert(not store.save("a", nil, invalid).ok and state.callbacks == 0, "validate before datastore")
		config.maxStoreBytes = 1
		assert(not store.save("a", nil, value(), "full").ok and state.values.a == nil, "size cap atomic abort")
	end,
}
