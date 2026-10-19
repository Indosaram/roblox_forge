--!strict
type Result = { ok: boolean, reason: string?, data: { [string]: any }?, stateVersion: number? }
-- Owner/consent provisioning. The membership record is complete BEFORE the settlement runtime
-- acquires its store, so what it consumes at acquisition is exactly what an actor is authorized
-- against. Nothing is appended later: a mutable "arriving actor" list never reached the settlement,
-- which is why a real positive user id could gather but not use settlement storage.
--
-- The policy is explicit; it is never inferred from an empty owner id. The permissive Studio path is
-- guarded by the ENVIRONMENT the caller passes in: `studio` is true only for a local Studio place
-- with no published experience id, so a published server can never select it.
--
-- `public` is the shipped policy: every server hosts its OWN camp. The persistence scope and the
-- tribe id derive from `environment.server` (a private/reserved server id keeps its camp across
-- restarts; any other server instance gets a fresh one), so no two servers share or lease the same
-- keys. A server-held steward owns the fresh camp; each joining player is admitted, up to the
-- camp's member limit, through the server-origin settlement invite against an explicit consent
-- record the server writes for that player (`admit`). The first admitted player receives ownership
-- and the steward leaves, so every seat belongs to a real player. Later players are visitors.
-- Studio and published servers run the identical path.
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local Journal = require(Forge.core.domain.command.Journal)
local LOCAL_OWNER = "-1"
-- Never a Roblox user id (those are numeric), so it can never collide with a real or test player.
local STEWARD = "steward"
local POLICIES = { staging = true, developmental = true, unprovisioned = true, public = true }
local INVITE = "survival-coop:settlement-invite"
local TRANSFER = "survival-coop:settlement-transfer-owner"
local LEAVE = "survival-coop:settlement-leave"
-- Admission refusals that make the player a visitor; anything else is an operational failure.
local VISITOR = { TRIBE_FULL = true, REJOIN_COOLDOWN = true, CAMP_ABANDONED = true }
return function(config: any, tribeId: string, environment: any): any
	local function userId(value: any): boolean
		if type(value) ~= "string" or not string.match(value, "^%-?[1-9][0-9]*$") then
			return false
		end
		local number = tonumber(value)
		return number ~= nil and math.abs(number) <= 9007199254740991 and string.format("%.0f", number) == value
	end
	assert(type(config) == "table", "SURVIVAL_PROVISION_REQUIRED")
	assert(POLICIES[config.policy] == true, "SURVIVAL_PROVISION_POLICY_REQUIRED")
	assert(
		type(config.provisionId) == "string"
			and #config.provisionId <= 16
			and string.match(config.provisionId, "^[a-z][a-z0-9%-]*$"),
		"SURVIVAL_PROVISION_ID_REQUIRED"
	)
	assert(type(config.acceptedInvitations) == "table", "SURVIVAL_CONSENT_RECORD_REQUIRED")
	for actor, accepted in config.acceptedInvitations do
		assert(userId(actor) and type(accepted) == "boolean", "SURVIVAL_INVALID_CONSENT_RECORD")
	end
	local actors: { string } = config.actors or {}
	assert(type(actors) == "table", "SURVIVAL_QA_ALLOWLIST_REQUIRED")
	for _, actor in actors do
		assert(userId(actor), "SURVIVAL_INVALID_QA_ACTOR")
	end
	local studio = type(environment) == "table" and environment.studio == true
	if config.policy == "unprovisioned" then
		error("SURVIVAL_OWNER_PROVISION_REQUIRED")
	end
	if config.policy == "public" then
		-- Membership comes only from players who join this server; a static record would be ignored.
		assert(next(config.acceptedInvitations) == nil and #actors == 0, "SURVIVAL_PUBLIC_RECORD_MUST_BE_EMPTY")
		local server = if type(environment) == "table" then environment.server else nil
		assert(type(server) == "string" and #server > 0, "SURVIVAL_SERVER_SCOPE_REQUIRED")
		assert(
			type(tribeId) == "string" and #tribeId <= 16 and not string.find(tribeId, ":", 1, true),
			"SURVIVAL_TRIBE_ID"
		)
		-- 64-bit digest of the scope: short enough for every leased key (<= 50 chars) and the camp key.
		local digest = Journal.fnv1a64(config.provisionId .. "\0" .. server)
		local scopedTribe = tribeId .. "-" .. digest
		local proof = "provision:public:" .. scopedTribe
		local consented: { [string]: boolean } = {}
		local function fail(reason: string): Result
			return { ok = false, reason = reason }
		end
		local function visitor(reason: string): Result
			return { ok = true, data = { role = "visitor", reason = reason } }
		end
		-- The steward leaves once a real member can own the camp. Idempotent per settlement state:
		-- request ids carry the settlement version, so a retried step replays its durable receipt.
		local function release(port: any): Result
			local state = port.state()
			if state == nil then
				return fail("SETTLEMENT_UNAVAILABLE")
			end
			if state.roles[STEWARD] == nil then
				return { ok = true }
			end
			if state.ownerId == STEWARD then
				local heirs: { string } = {}
				for actor in state.roles do
					if actor ~= STEWARD then
						table.insert(heirs, actor)
					end
				end
				if #heirs == 0 then
					return { ok = true }
				end
				table.sort(heirs)
				local handed = port.command(
					STEWARD,
					TRANSFER,
					{ heirs[1], state.version, state.membershipRevision },
					"handover:" .. heirs[1] .. ":" .. state.version
				)
				if not handed.ok then
					return handed
				end
				state = port.state()
			end
			return port.command(
				STEWARD,
				LEAVE,
				{ STEWARD, state.version, state.membershipRevision },
				"release:" .. state.version
			)
		end
		-- Admit a player who joined this server. `port.state()` is the last confirmed settlement;
		-- `port.command(actor, action, args, requestId)` runs a server-origin settlement command.
		local function attempt(actor: string, port: any): Result
			local released = release(port)
			if not released.ok then
				return released
			end
			local state = port.state()
			if state == nil then
				return fail("SETTLEMENT_UNAVAILABLE")
			end
			if state.roles[actor] ~= nil then
				return { ok = true, data = { role = state.roles[actor] } }
			end
			if state.roles[state.ownerId] == nil then
				return visitor("CAMP_ABANDONED")
			end
			local seats = 0
			for member in state.roles do
				if member ~= STEWARD then
					seats += 1
				end
			end
			if seats >= state.config.maxMembers then
				return visitor("TRIBE_FULL")
			end
			consented[actor] = true
			local ok, invited = pcall(
				port.command,
				state.ownerId,
				INVITE,
				{ actor, state.version, state.membershipRevision },
				"admit:" .. actor .. ":" .. state.version
			)
			consented[actor] = nil
			if not ok then
				error(invited, 0)
			end
			if not invited.ok then
				return if VISITOR[invited.reason] then visitor(invited.reason :: string) else invited
			end
			released = release(port)
			if not released.ok then
				return released
			end
			local current = port.state()
			return { ok = true, data = { role = if current then current.roles[actor] else "member" } }
		end
		return {
			ownerId = STEWARD,
			id = "p" .. digest,
			tribeId = scopedTribe,
			acceptedMembers = {},
			tribeFor = function(_actor)
				-- Routing grants no membership: the settlement still requires a role for every action.
				return scopedTribe
			end,
			authorize = function(actor, action, _args, origin): Result
				if actor == STEWARD then
					-- The steward never plays; it only founds the camp and hands it over.
					if origin ~= "server" or (action ~= INVITE and action ~= TRANSFER and action ~= LEAVE) then
						return { ok = false, reason = "FORBIDDEN" }
					end
					return { ok = true }
				end
				if action == INVITE and origin ~= "server" then
					return { ok = false, reason = "FORBIDDEN" }
				end
				-- The settlement domain still requires the inviter to be the current owner.
				return { ok = true }
			end,
			consent = function(_actor, target)
				return consented[target] == true
			end,
			proof = function(_actor)
				return proof
			end,
			verifyTransfer = function(_actor, value)
				return value == proof
			end,
			admit = function(actor: string, port: any): Result
				-- A concurrent member command can move the settlement version between the read and the
				-- invite; each attempt re-reads the confirmed state and uses a fresh request id.
				local last: Result = fail("SETTLEMENT_UNAVAILABLE")
				for _ = 1, 3 do
					last = attempt(actor, port)
					if last.ok or (last.reason ~= "STALE_VERSION" and last.reason ~= "STALE_MEMBERSHIP") then
						return last
					end
				end
				return last
			end,
		}
	end
	assert(config.policy ~= "staging" or userId(config.ownerId), "SURVIVAL_OWNER_PROVISION_REQUIRED")
	local owner: string = if config.policy == "staging" then tostring(config.ownerId) else LOCAL_OWNER
	local accepted: { [string]: boolean } = table.clone(config.acceptedInvitations)
	local allowed: { [string]: boolean } = {}
	for _, actor in actors do
		allowed[actor] = true
	end
	local members: { string } = {}
	local function addMember(actor: any)
		local id = tostring(actor)
		if id == owner or table.find(members, id) then
			return
		end
		table.insert(members, id)
	end
	for actor, consented in accepted do
		if consented then
			addMember(actor)
		end
	end
	if studio then
		for _, actor in actors do
			addMember(actor)
		end
	end
	-- Membership is the record above and nothing else. An empty allowlist in a local Studio place
	-- admits the routed QA actor; a published server admits only the owner and the consented members.
	local function routed(actor: string): boolean
		if actor == owner or accepted[actor] == true then
			return true
		end
		if not studio then
			return false
		end
		if next(allowed) == nil then
			return true
		end
		return allowed[actor] == true
	end
	local proof = "provision:" .. config.provisionId .. ":" .. tribeId
	return {
		ownerId = owner,
		id = config.provisionId,
		tribeId = tribeId,
		acceptedMembers = members,
		tribeFor = function(actor)
			return if routed(actor) then tribeId else nil
		end,
		authorize = function(actor, action, _args, origin): Result
			if not routed(actor) then
				return { ok = false, reason = "PROVISION_REQUIRED" }
			end
			if action == INVITE and (actor ~= owner or origin ~= "server") then
				return { ok = false, reason = "FORBIDDEN" }
			end
			return { ok = true }
		end,
		consent = function(actor, target)
			return actor == owner and accepted[target] == true
		end,
		proof = function(actor)
			return if routed(actor) then proof else nil
		end,
		verifyTransfer = function(actor, value)
			return routed(actor) and value == proof
		end,
	}
end
