--!strict
-- licenses: allow/deny registry for asset tools (see AGENTS.md hard rules).
--
-- A tool entry answers two separate questions, and the asset gate keeps them
-- separate on purpose:
--   1. may we use this tool commercially at all (allow/deny, `resolve`), and
--   2. where do the commercial rights to its output come from, and who owns
--      the resulting artifact (`rights`).
-- Neither answer says anything about whether the artifact *looks* good: that
-- verdict lives in the quality report, never here.

local M = {}

export type Ownership = "first-party" | "licensed" | "platform" | "commissioned"

export type Rights = {
	license: string,
	rightsSource: string,
	ownership: Ownership,
}

-- Ownership classes a manifest may declare. `commissioned` has no registry tool
-- yet (no commissioned artist pipeline exists); it is listed so a manifest can
-- declare it for an imported artifact without the schema having to change.
local OWNERSHIPS: { [string]: boolean } = {
	["first-party"] = true,
	["licensed"] = true,
	["platform"] = true,
	["commissioned"] = true,
}

local rights: { [string]: Rights } = {
	["studio-mcp"] = {
		license = "Roblox Terms of Use",
		rightsSource = "Roblox Creator Terms of Use (Studio generation)",
		ownership = "platform",
	},
	["trellis"] = {
		license = "MIT",
		rightsSource = "TRELLIS MIT license",
		ownership = "first-party",
	},
	["roblox-audio-library"] = {
		license = "Roblox Audio Library",
		rightsSource = "Roblox Audio Library terms",
		ownership = "platform",
	},
	["elevenlabs"] = {
		license = "ElevenLabs commercial API plan",
		rightsSource = "ElevenLabs commercial plan terms",
		ownership = "licensed",
	},
	["creator-store"] = {
		license = "Roblox Creator Store terms",
		rightsSource = "Roblox Creator Store license",
		ownership = "licensed",
	},
	["forge-procgen"] = {
		license = "first-party, commercial ok",
		rightsSource = "first-party generator in this repository",
		ownership = "first-party",
	},
}

-- Derived from `rights` so the allow-list and the rights records can never
-- disagree about which tools are usable.
local allowed: { [string]: string } = {}
for name, record in rights do
	allowed[name] = record.license
end

local denied: { [string]: string } = {
	["audiocraft"] = "denied: audiocraft weights are CC-BY-NC (non-commercial)",
	["roblox-cube"] = "denied: roblox-cube is research only",
	["hunyuan3d-2"] = "denied: hunyuan3d-2 excludes KR/EU/UK",
}

M.allowed = allowed
M.denied = denied
M.rightsByTool = rights
M.ownerships = OWNERSHIPS

--- True when `value` is one of the declarable artifact ownership classes.
function M.isOwnership(value: string): boolean
	return OWNERSHIPS[value] == true
end

--- The commercial rights record for an allowed tool, or nil when the tool is
--- denied or unknown (use `resolve` for the refusal reason).
function M.rights(tool: string): Rights?
	return rights[tool]
end

local function sortedNames(values: { [string]: string }): { string }
	local names: { string } = {}
	for name in values do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--- Allowed tool names in sorted order, for error messages.
function M.allowedTools(): { string }
	return sortedNames(allowed)
end

export type Classification = "allowed" | "denied" | "unregistered"

--- Classifies a tool without deciding whether it may be used:
---   allowed      - a known tool whose commercial rights this repo records,
---   denied       - a banned model/weight (never usable, whatever a manifest claims),
---   unregistered - not known here. Lawfulness then has to come from recorded
---                  rights evidence on the artifact itself, not from this list.
function M.classify(tool: string): Classification
	if rights[tool] ~= nil then
		return "allowed"
	end
	if denied[tool] ~= nil then
		return "denied"
	end
	return "unregistered"
end

--- The deny reason for a banned tool, or nil when it is not banned. A denial
--- is absolute: no amount of recorded rights evidence can lift it, because the
--- weights themselves are not licensed for commercial use here.
function M.denialReason(tool: string): string?
	return denied[tool]
end

--- Resolves a tool name to (true, license) when allowed, or (false, reason) when
--- denied or unknown.
---
--- This is the legacy registry verdict: it refuses anything it does not know.
--- The versioned provenance gate uses `classify`/`denialReason` instead, so a
--- lawful tool outside this registry can be accepted on recorded rights
--- evidence; `resolve` is kept for the v1 manifest path and for callers that
--- must route through a known provider (gen's provider routing).
function M.resolve(tool: string): (boolean, string)
	local license = allowed[tool]
	if license ~= nil then
		return true, license
	end
	local deniedReason = denied[tool]
	if deniedReason ~= nil then
		return false, deniedReason
	end
	return false, "unknown tool '" .. tool .. "'; allowed tools: " .. table.concat(sortedNames(allowed), ", ")
end

return M
