--!strict
-- p134 v40: after a force-stop the previous server's personal lease (lockTimeout 120 s) stays
-- live, and a rejoin on a new server was refused "locked" until it expired, so the HUD showed
-- but every action answered "still connecting" for about two minutes. Plan D1 budgets 10 s
-- from join to the first accepted action. Real Session + PersonalAggregate + FencedStore over
-- the memory backend, driven by a fake clock and Server.join's retry cadence.
local Session = require("./Session")
local Memory = require("../data/MemoryBackend")
local Survival = require("../../../genres/survival-coop/module/Contract")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local ACTION = "survival-coop:defend-active"
local ACTOR = "11734795308"
local BUDGET = 10

local function server(backend: any, clock: { value: number }, sessionId: string, takeoverSeconds: number?)
	local extension = {
		id = "fixture",
		handles = function(action: string): boolean
			return action == ACTION
		end,
		command = function(_actor, _action, _args, _context, _origin, admit)
			local admitted = admit()
			if not admitted.ok then
				return admitted
			end
			return { ok = true, stateVersion = 1, data = {} }
		end,
	}
	local policy: any = {
		actions = { ACTION },
		personal = { namespace = "personal", inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" } },
	}
	local now = function()
		return clock.value
	end
	return Session.new(
		{
			packConfig = luau.load(fs.readFile("games/robango-island/src/shared/GenreConfig.luau"))(),
			contracts = { Survival },
			controls = {},
			storeName = "TakeoverSpec",
			durable = policy,
			services = { survivalExtensions = { extension } },
		} :: any,
		backend,
		{
			sessionId = sessionId,
			lockTimeout = 120,
			retries = 0,
			now = now,
			-- What Server.start passes.
			leasedReads = true,
			suppressIdentityUpdates = true,
			takeoverSeconds = takeoverSeconds,
		},
		{
			now = now,
			roll = function()
				return 0
			end,
			emit = function() end,
			encode = function(value)
				return serde.encode("json", value)
			end,
			survivalExtensions = { extension } :: { any },
		},
		policy
	)
end

-- Server.join's loop: retry a refused join, then act as soon as an epoch is offered. Returns
-- seconds from the first join attempt to the first accepted action (nil: none within limit).
local function timeToAction(session: any, clock: { value: number }, limit: number): number?
	local started = clock.value
	local joined = false
	local request = 0
	while clock.value - started <= limit do
		if not joined then
			local result = session.join(ACTOR)
			joined = result.ok
			assert(joined or result.reason == "locked", "join refused: " .. tostring(result.reason))
		end
		if joined then
			local epoch = session.commandEpoch(ACTOR, ACTION)
			if epoch ~= nil then
				request += 1
				local result = session.command(
					ACTOR,
					{ requestId = "r" .. request, sessionEpoch = epoch, action = ACTION, args = {} }
				)
				if result.ok then
					return clock.value - started
				end
			end
		end
		clock.value += 2
	end
	return nil
end

-- The previous server held the player and was force-stopped: no close, its lease still live.
local function forceStopped(backend: any, clock: { value: number }): any
	local old = server(backend, clock, "old-server", 5)
	assert(old.join(ACTOR).ok, "old server join")
	clock.value += 10
	assert(old.save(ACTOR).ok, "old server saves (lease renewed)")
	clock.value += 3
	return old
end

return {
	["rejoin after a force-stop is playable within the D1 budget despite the stale lease"] = function()
		local backend = Memory.new()
		local clock = { value = 1000 }
		local old = forceStopped(backend, clock)
		local seconds = timeToAction(server(backend, clock, "new-server", 5), clock, 150)
		assert(seconds ~= nil and seconds <= BUDGET, "time to first accepted action: " .. tostring(seconds))
		-- The superseded server is fenced and its close finishes instead of retrying forever.
		local saved = old.save(ACTOR)
		assert(not saved.ok and saved.reason == "lease lost", "old server fenced: " .. tostring(saved.reason))
		assert(old.close(ACTOR).ok, "old server close tolerates the takeover")
	end,
	["a still-closing holder gets the grace before its lease is taken over"] = function()
		local backend = Memory.new()
		local clock = { value = 1000 }
		-- The holder wrote the record just now (its acquire): it may still be closing.
		assert(server(backend, clock, "old-server", 5).join(ACTOR).ok, "old server join")
		local fresh = server(backend, clock, "new-server", 5)
		local first = fresh.join(ACTOR)
		assert(not first.ok and first.reason == "locked", "first attempt waits for the holder")
		clock.value += 4
		assert(fresh.join(ACTOR).reason == "locked", "still inside the grace")
		clock.value += 1
		assert(fresh.join(ACTOR).ok, "taken over once the grace has passed")
	end,
	["a holder quiet for the grace is taken over on the first attempt"] = function()
		local backend = Memory.new()
		local clock = { value = 1000 }
		forceStopped(backend, clock)
		assert(server(backend, clock, "new-server", 5).join(ACTOR).ok, "no refused write slot")
	end,
	["without takeoverSeconds the lease is still honoured until it expires"] = function()
		local backend = Memory.new()
		local clock = { value = 1000 }
		forceStopped(backend, clock)
		local seconds = timeToAction(server(backend, clock, "new-server", nil), clock, 150)
		assert(seconds ~= nil and seconds > 100, "waits for lease expiry: " .. tostring(seconds))
	end,
}
