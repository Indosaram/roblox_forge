--!strict
-- Topology: island place kinds, their per-server capacity, and the travel
-- transitions allowed between kinds (plan §5.1, §11.1). Engine-free.

local Topology = {}

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
