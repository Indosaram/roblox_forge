--!strict
-- Topology: island place kinds, their per-server capacity, and the travel
-- transitions allowed between kinds (plan §5.1, §11.1). Engine-free.

local Topology = {}

-- Place roles are separate from the legacy allocation kinds below. A zero id
-- is an authored placeholder, never an alias for the onboarding world.
Topology.ROLES = {
	onboarding = "onboarding",
	home = "home",
	harbor = "harbor",
	archipelago = "archipelago",
	explore10 = "explore10",
	explore20 = "explore20",
	frontier30 = "frontier30",
	frontier40 = "frontier40",
	frontier50 = "frontier50",
	frontier60 = "frontier60",
	brawl = "brawl",
	["team-outpost"] = "team-outpost",
}
local ROLE_EDGES: { [string]: { [string]: boolean } } = {
	onboarding = { home = true },
	home = { harbor = true },
	harbor = {
		home = true,
		archipelago = true,
		explore10 = true,
		explore20 = true,
		frontier30 = true,
		frontier40 = true,
		frontier50 = true,
		frontier60 = true,
		brawl = true,
		["team-outpost"] = true,
	},
	archipelago = { archipelago = true, home = true, harbor = true },
	explore10 = { harbor = true, home = true },
	explore20 = { harbor = true, home = true },
	frontier30 = { harbor = true, home = true },
	frontier40 = { harbor = true, home = true },
	frontier50 = { harbor = true, home = true },
	frontier60 = { harbor = true, home = true },
	brawl = { harbor = true },
	["team-outpost"] = { harbor = true },
}

function Topology.resolveRole(places: { [string]: number }, placeId: number): (string?, string?)
	if type(places) ~= "table" then
		return nil, "missing_role_config"
	end
	local selected: string? = nil
	for role, id in places do
		if Topology.ROLES[role] == nil then
			return nil, "unknown_role:" .. role
		end
		if type(id) ~= "number" or id < 0 or id ~= math.floor(id) then
			return nil, "invalid_place_id:" .. role
		end
		if id > 0 and id == placeId then
			if selected then
				return nil, "duplicate_place_id"
			end
			selected = role
		end
	end
	if selected == nil then
		return nil, "unconfigured_place_id:" .. tostring(placeId)
	end
	return selected, nil
end

function Topology.validateRoleTransition(from: string, to: string, level: number): (boolean, string?)
	if ROLE_EDGES[from] == nil then
		return false, "unknown_source_role"
	end
	if ROLE_EDGES[to] == nil then
		return false, "unknown_target_role"
	end
	if not ROLE_EDGES[from][to] then
		return false, "transition_not_allowed"
	end
	local minimum = tonumber(string.match(to, "^frontier(%d+)$") or string.match(to, "^explore(%d+)$")) or 1
	if level < minimum then
		return false, "level_gate"
	end
	return true, nil
end

-- One of "landing" | "homestead" | "harbor" | "expedition" | "contested";
-- kept as string because kinds arrive from data and are checked by isKind.
export type Kind = string
export type Topology = { capacity: { [Kind]: number } }

-- forge policy cap per server (plan §5.1, ADR-04); overrides may only lower it.
Topology.POLICY_CAPACITY = 8

-- Sorted list of every kind. "contested" is a P2 kind (opt-in camp siege).
local KINDS: { Kind } = { "contested", "expedition", "harbor", "homestead", "landing" }

local PHASE: { [Kind]: string } = {
	landing = "P0",
	homestead = "P0",
	harbor = "P0",
	expedition = "P0",
	contested = "P2",
}

-- Directed edges. The onboarding landing is one-way; the harbor is the hub.
local TRANSITIONS: { [Kind]: { [Kind]: boolean } } = {
	landing = { homestead = true, harbor = true },
	homestead = { harbor = true },
	harbor = { homestead = true, expedition = true, contested = true },
	expedition = { harbor = true },
	contested = { harbor = true },
}

function Topology.kinds(): { Kind }
	return table.clone(KINDS)
end

function Topology.isKind(value: any): boolean
	return type(value) == "string" and PHASE[value :: Kind] ~= nil
end

function Topology.phase(kind: Kind): string
	if not Topology.isKind(kind) then
		error("invalid kind")
	end
	return PHASE[kind]
end

-- Builds a topology. `capacity` overrides are optional per kind and must be
-- integers in [1, POLICY_CAPACITY]; unknown kinds are rejected.
function Topology.new(capacity: { [string]: number }?): Topology
	local result: { [Kind]: number } = {}
	for _, kind in KINDS do
		result[kind] = Topology.POLICY_CAPACITY
	end
	if capacity ~= nil then
		if type(capacity) ~= "table" then
			error("invalid capacity table")
		end
		for kind, value in capacity do
			if not Topology.isKind(kind) then
				error("invalid capacity kind")
			end
			if
				type(value) ~= "number"
				or value ~= math.floor(value)
				or value < 1
				or value > Topology.POLICY_CAPACITY
			then
				error("invalid capacity for " .. kind)
			end
			result[kind :: Kind] = value
		end
	end
	return { capacity = result }
end

function Topology.capacity(t: Topology, kind: Kind): number
	if not Topology.isKind(kind) then
		error("invalid kind")
	end
	return t.capacity[kind]
end

function Topology.canTransition(from: Kind, to: Kind): boolean
	if not Topology.isKind(from) or not Topology.isKind(to) then
		return false
	end
	return TRANSITIONS[from][to] == true
end

-- Returns (true, nil) for an allowed transition, else (false, code) where code
-- is a stable machine-readable reason.
function Topology.validateTransition(from: any, to: any): (boolean, string?)
	if not Topology.isKind(from) then
		return false, "unknown_source_kind"
	end
	if not Topology.isKind(to) then
		return false, "unknown_target_kind"
	end
	if from == to then
		return false, "same_kind"
	end
	if not TRANSITIONS[from :: Kind][to :: Kind] then
		return false, "transition_not_allowed"
	end
	return true, nil
end

return Topology
