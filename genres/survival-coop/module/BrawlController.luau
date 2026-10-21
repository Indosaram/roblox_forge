--!strict
-- One durable arena key, one fenced owner. MemoryStore and messages are advisory;
-- a lost notification never changes match ownership or reward eligibility.
local FencedStore = require("../../../core/infra/data/FencedStore")
local Match = require("../../../core/domain/brawl/Match")
local Data = require("../../../core/domain/genre/SerializedData")
local Combat = require("./Combat")
local M = {}

function M.new(env: any): any
	local store = FencedStore.new({
		update = function(key: string, transform: any): (boolean, any)
			return pcall(function()
				return env.store:UpdateAsync(key, transform)
			end)
		end,
	}, { sessionId = env.owner, leaseSeconds = env.leaseSeconds, now = env.utc })
	local profile: any = nil
	local api = {}
	local function lease(): boolean
		if not env.lease then
			return true
		end
		local now = env.utc()
		local ok, value = pcall(function()
			return env.lease:UpdateAsync(env.key, function(old: any): any
				if old and old.owner ~= env.owner and old.expiresAt > now then
					return old
				end
				return { owner = env.owner, expiresAt = now + env.leaseSeconds }
			end, env.leaseSeconds)
		end)
		return ok and value ~= nil and value.owner == env.owner
	end
	local function publish()
		local state = Data.clone(profile.data.match)
		env.publish(state)
		-- These hints carry no authority. Both services may throttle or be unavailable.
		if env.directory then
			pcall(function()
				env.directory:SetAsync(env.key, { id = state.id, phase = state.phase }, env.leaseSeconds)
			end)
		end
		if env.messaging then
			pcall(function()
				env.messaging:PublishAsync(env.topic, { key = env.key, id = state.id })
			end)
		end
	end
	function api.acquire(): any
		if not lease() then
			return { ok = false, reason = "ARENA_LEASE_BUSY" }
		end
		local loaded, reason = store:acquire(env.key, function(document: any): any
			if not document.match then
				document.match = Match.new(env.matchId, env.policy)
				document.settled = {}
			end
			return document
		end)
		if not loaded then
			return { ok = false, reason = reason }
		end
		profile = loaded
		publish()
		return { ok = true }
	end
	local function change(transform: any): any
		if not profile then
			return { ok = false, reason = "NOT_OWNER" }
		end
		if not lease() then
			return { ok = false, reason = "ARENA_LEASE_LOST" }
		end
		local result: any = nil
		local loaded, reason = store:update(profile, function(document: any): any
			local candidate = Data.clone(document.match)
			result = transform(candidate)
			if result.ok then
				document.match = candidate
			end
			return document
		end)
		if not loaded then
			return { ok = false, reason = reason }
		end
		profile = loaded
		if result.ok then
			publish()
		end
		return result
	end
	local function snapshot(): any
		assert(profile, "NOT_OWNER")
		return Data.clone(profile.data.match)
	end
	api.ports = {
		match = { snapshot = snapshot, transaction = change },
		personal = env.ledger,
		now = env.now,
		utc = env.utc,
		facts = env.facts,
		action = env.action,
		apply = env.apply,
	}
	function api.command(actor: string, action: string, args: any): any
		local now = env.now()
		if action == "brawl-reward" then
			return env.ledger.claim(actor, snapshot(), env.utc())
		end
		local facts = if action == "brawl-queue" then Data.clone(env.facts(actor)) else nil
		local fact = if action == "brawl-action" then Data.clone(env.action(actor, args[1], snapshot())) else nil
		return change(function(state: any): any
			local ok, reason
			if action == "brawl-queue" then
				ok, reason = Match.join(state, actor, facts)
			elseif action == "brawl-leave" then
				ok, reason = Match.leave(state, actor)
			elseif action == "brawl-action" then
				if not fact then
					return { ok = false, reason = "UNVERIFIED_ACTION" }
				end
				local allowed = Match.action(state, actor, fact.kind, fact.range, now)
				if not allowed.ok then
					return allowed
				end
				return env.apply(state, actor, Data.clone(fact), allowed)
			else
				return { ok = false, reason = "UNKNOWN_ACTION" }
			end
			return { ok = ok, reason = reason }
		end)
	end
	function api.start(): any
		local now = env.now()
		return change(function(state: any): any
			local ok, reason = Match.start(state, now)
			return { ok = ok, reason = reason }
		end)
	end
	api.snapshot = snapshot
	function api.claim(actor: string): any
		local state = snapshot()
		if not state.actors[actor] then
			return { ok = true }
		end
		return env.ledger.claim(actor, state, env.utc())
	end
	function api.disconnect(actor: string): any
		return api.command(actor, "brawl-leave", {})
	end
	function api.tick(): any
		local now = env.now()
		-- Capture service facts once, outside replayable CAS callbacks.
		local frame = env.frame(snapshot(), now)
		return change(function(state: any): any
			if not state.startsAt or now < state.startsAt then
				return { ok = false, reason = "NOT_ACTIVE" }
			end
			if state.phase == "finished" then
				return { ok = true }
			end
			local weather = Match.weather(state, now)
			local damage = {}
			for _, actor in state.order do
				local player = state.actors[actor]
				if player.alive then
					if frame.connected[actor] ~= true then
						Match.leave(state, actor)
					elseif not frame.positions[actor] then
						return { ok = false, reason = "MISSING_POSITION" }
					end
				end
				if weather.noMount then
					player.mounted = false
				end
			end
			-- Resolve every pending attack against the same pre-damage participant set.
			-- begin/apply stores Combat.begin attacks only in snapshot combat.attacks.
			for actor, player in state.actors do
				if player.alive and player.combat then
					for index, attack in player.combat.attacks or {} do
						local target = state.actors[attack.target]
						if target and target.alive then
							local permitted = Match.action(state, actor, attack.mode, attack.range, now)
							if permitted.ok then
								local nextAttack, milli = Combat.resolve(
									attack,
									math.floor(now * 1000),
									attack.target,
									frame.positions[attack.target],
									frame.sight[attack.id] == true,
									target.defense or Combat.defense()
								)
								player.combat.attacks[index] = nextAttack
								damage[attack.target] = (damage[attack.target] or 0) + milli / 1000
							else
								attack.resolved = true
							end
						end
					end
				end
			end
			local ok, reason = Match.tick(state, now, frame.positions, damage)
			return { ok = ok, reason = reason }
		end)
	end
	function api.settle(): any
		local state = snapshot()
		if state.phase ~= "finished" then
			return { ok = false, reason = "NOT_FINISHED" }
		end
		for _, actor in state.order do
			local result = env.ledger.claim(actor, state, env.utc())
			if not result.ok then
				return result
			end
		end
		-- All receipts are durable before this marker; a crash simply replays them.
		local loaded, reason = store:update(profile, function(document: any): any
			document.settled[state.id] = true
			return document
		end)
		if not loaded then
			return { ok = false, reason = reason }
		end
		profile = loaded
		return { ok = true }
	end
	function api.release(): any
		if not profile then
			return { ok = false, reason = "NOT_OWNER" }
		end
		local released, reason = store:release(profile)
		if not released then
			return { ok = false, reason = reason }
		end
		profile = nil
		return { ok = true }
	end
	function api.nextMatch(id: string): any
		if not profile then
			return { ok = false, reason = "NOT_OWNER" }
		end
		local result: any = nil
		local loaded, reason = store:update(profile, function(document: any): any
			local state = document.match
			if
				state.phase ~= "finished"
				or not document.settled[state.id]
				or document.settled[id]
				or id == state.id
			then
				result = { ok = false, reason = "UNSETTLED_MATCH" }
				return document
			end
			document.match = Match.new(id, env.policy)
			result = { ok = true }
			return document
		end)
		if not loaded then
			return { ok = false, reason = reason }
		end
		profile = loaded
		if result.ok then
			publish()
		end
		return result
	end
	return api
end

return M
