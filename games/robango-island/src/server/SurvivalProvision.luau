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
local LOCAL_OWNER = "-1"
local POLICIES = { staging = true, developmental = true, unprovisioned = true }
return function(config: any, tribeId: string, environment: any)
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
		acceptedMembers = members,
		tribeFor = function(actor)
			return if routed(actor) then tribeId else nil
		end,
		authorize = function(actor, action, _args, origin): Result
			if not routed(actor) then
				return { ok = false, reason = "PROVISION_REQUIRED" }
			end
			if action == "survival-coop:settlement-invite" and (actor ~= owner or origin ~= "server") then
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
