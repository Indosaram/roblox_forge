--!strict
-- QA-TP-01: 20% injected teleport failure over 100 teleports (seeded Rng).
-- Every player either arrives or falls back to the origin server, and the
-- inventory hash is unchanged. No real sleeps: backoff runs on a fake clock.

local Rng = require("../../domain/random/Rng")
local Teleport = require("./Teleport")

local SEED = 20261016

local function hash(inventory: { [string]: number }): string
	local keys = {}
	for key in inventory do
		table.insert(keys, key)
	end
	table.sort(keys)
	local parts = {}
	for _, key in keys do
		table.insert(parts, key .. "=" .. inventory[key])
	end
	return table.concat(parts, ";")
end

type Harness = {
	teleport: Teleport.Teleport,
	slept: { number },
	calls: { number },
	committed: { [number]: { [string]: number } },
	live: { [number]: { [string]: number } },
}

local function harness(fail: (attempt: number) -> boolean, commitOk: boolean?): Harness
	local slept: { number } = {}
	local calls: { number } = {}
	local committed: { [number]: { [string]: number } } = {}
	local live: { [number]: { [string]: number } } = {}
	local teleport = Teleport.new({
		port = {
			teleport = function(_placeId: number, ids: { number }, accessCode: string): (boolean, string?)
				assert(accessCode == "code-1", "reserved server access code is forwarded")
				table.insert(calls, ids[1])
				if fail(#calls) then
					return false, "Teleport failed: injected"
				end
				return true, nil
			end,
		},
		commit = function(playerId: number): (boolean, string?)
			if commitOk == false then
				return false, "throttled"
			end
			committed[playerId] = table.clone(live[playerId])
			return true, nil
		end,
		sleep = function(seconds: number)
			table.insert(slept, seconds)
		end,
	})
	return { teleport = teleport, slept = slept, calls = calls, committed = committed, live = live }
end

return {
	["QA-TP-01 20 percent failure over 100 teleports: arrive or fall back, hash unchanged"] = function()
		local rng = Rng.new(SEED):fork("teleport-failure")
		local h = harness(function(): boolean
			return rng:nextNumber() < 0.2
		end)
		local arrived, fallback, injected = 0, 0, 0
		for playerId = 1, 100 do
			h.live[playerId] = { wood = playerId, stone = playerId * 2, gold = playerId % 7 }
			local before = hash(h.live[playerId])
			local callsBefore = #h.calls
			local result = h.teleport:send(playerId, 4242, "code-1")
			injected += (#h.calls - callsBefore) - (if result.status == "arrived" then 1 else 0)
			-- Arrived players are rebuilt from the committed record; fallbacks keep live state.
			local after = if result.status == "arrived"
				then hash(Teleport.arrive(function(id)
					return h.committed[id]
				end, playerId))
				else hash(h.live[playerId])
			assert(after == before, "inventory hash unchanged for player " .. playerId)
			if result.status == "arrived" then
				arrived += 1
				assert(result.attempts >= 1 and result.attempts <= 3, "arrived within 3 attempts")
			else
				fallback += 1
				assert(result.attempts == 3, "fallback only after exhausting retries")
			end
		end
		assert(arrived + fallback == 100, "every player accounted for")
		assert(injected >= 10, "failure injection actually exercised retries, injected " .. injected)
		assert(arrived >= 90, "retries recover most failures, arrived " .. arrived)
	end,

	["backoff is exponential and capped at 3 attempts then falls back"] = function()
		local h = harness(function(): boolean
			return true
		end)
		h.live[7] = { wood = 3 }
		local result = h.teleport:send(7, 4242, "code-1")
		assert(result.status == "fallback" and result.attempts == 3, "falls back after 3 tries")
		assert(#h.calls == 3, "exactly 3 teleport calls")
		assert(#h.slept == 2 and h.slept[1] == 1 and h.slept[2] == 2, "sleeps 1s then 2s")
		assert(result.reason == "Teleport failed: injected", "last error surfaced")
	end,

	["NEGATIVE: commit failure blocks the teleport entirely"] = function()
		local h = harness(function(): boolean
			return false
		end, false)
		h.live[1] = { wood = 1 }
		local result = h.teleport:send(1, 4242, "code-1")
		assert(result.status == "fallback" and result.attempts == 0, "no hop without a commit")
		assert(#h.calls == 0, "TeleportAsync never called")
	end,

	["NEGATIVE: tampered TeleportData is ignored on arrival"] = function()
		local committed = { [5] = { gold = 1 } }
		local state = Teleport.arrive(function(id)
			return committed[id]
		end, 5, { inventory = { gold = 999999 } })
		assert(hash(state) == "gold=1", "destination state comes from the store, not TeleportData")
	end,

	["missing access code falls back without calling the port"] = function()
		local h = harness(function(): boolean
			return false
		end)
		local result = h.teleport:send(1, 4242, "")
		assert(result.status == "fallback" and #h.calls == 0, "no teleport without reserved access code")
	end,
}
