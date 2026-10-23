--!strict
-- Client render caps per device profile. Source of truth: game.yml `render_profiles`
-- (render-budget.spec.luau asserts equality). Pure: Lune runs every decision here.
export type Profile = {
	qualityLevelMax: number,
	decorPartsMax: number,
	effectsMax: number,
	decorShadows: boolean,
	wildlifePoseStuds: number,
	wildlifePoseMax: number,
	decorFaunaPose: boolean,
	meshBuildsMax: number,
}
local M = {}

M.profiles = {
	low = {
		qualityLevelMax = 3,
		decorPartsMax = 160,
		effectsMax = 2,
		decorShadows = false,
		wildlifePoseStuds = 60,
		wildlifePoseMax = 6,
		decorFaunaPose = false,
		meshBuildsMax = 2,
	} :: Profile,
	high = {
		qualityLevelMax = 10,
		decorPartsMax = 100000,
		effectsMax = 100000,
		decorShadows = true,
		wildlifePoseStuds = 100,
		wildlifePoseMax = 1000,
		decorFaunaPose = true,
		meshBuildsMax = 6,
	} :: Profile,
}

--- Selects the profile name. `level` is SavedQualityLevel as a number (0 = Automatic);
--- Automatic counts as low on a touch device, where most low-end phones sit.
function M.select(level: number, touch: boolean): string
	if level == 0 then
		return if touch then "low" else "high"
	end
	return if level <= M.profiles.low.qualityLevelMax then "low" else "high"
end

--- Ranks decorative definitions (and, separately, effect hosts) by flat distance to
--- the spawn, nearest first, id as tiebreak. Returns id -> 1-based rank.
function M.rank(
	definitions: { any },
	origin: { x: number, z: number },
	filter: ((any) -> boolean)?
): { [string]: number }
	local list = {}
	for _, definition in definitions do
		if definition.decorative and (filter == nil or filter(definition)) then
			table.insert(list, definition)
		end
	end
	local function distance(d: any): number
		local p = d.ground or d.position
		return (p.x - origin.x) ^ 2 + (p.z - origin.z) ^ 2
	end
	table.sort(list, function(a, b)
		local da, db = distance(a), distance(b)
		if da ~= db then
			return da < db
		end
		return a.id < b.id
	end)
	local ranks = {}
	for index, definition in list do
		ranks[definition.id] = index
	end
	return ranks
end

--- Whether a decorative part with this rank stays on the client.
function M.keepDecor(rank: number, profile: Profile): boolean
	return rank <= profile.decorPartsMax
end

--- Whether an effect host with this rank keeps its emitters enabled.
function M.keepEffect(rank: number, profile: Profile): boolean
	return rank <= profile.effectsMax
end

--- Picks which creatures are articulated this frame: the nearest within range, up to
--- the cap. Gameplay telegraph states are always posed and do not use the cap.
function M.poses(entries: { { key: any, distance: number, urgent: boolean } }, profile: Profile): { [any]: boolean }
	local chosen: { [any]: boolean } = {}
	local near = {}
	for _, entry in entries do
		if entry.urgent then
			chosen[entry.key] = true
		elseif entry.distance <= profile.wildlifePoseStuds then
			table.insert(near, entry)
		end
	end
	table.sort(near, function(a, b)
		return a.distance < b.distance
	end)
	for index = 1, math.min(#near, profile.wildlifePoseMax) do
		chosen[near[index].key] = true
	end
	return chosen
end

--- The runtime EditableMesh placements this profile builds, in authored order.
function M.meshes<T>(placements: { T }, profile: Profile): { T }
	local kept = {}
	for index = 1, math.min(#placements, profile.meshBuildsMax) do
		table.insert(kept, placements[index])
	end
	return kept
end

local EFFECT_CLASSES = { "Fire", "Smoke", "ParticleEmitter", "Beam", "PointLight" }

--- Applies the profile to one replicated dressing part on this client only: shadows,
--- emitter enablement, and visibility (LocalTransparencyModifier, client-local).
--- Returns whether the part stays visible. Parts without a rank are left untouched.
function M.applyPart(part: any, profile: Profile): boolean
	local decor = part:GetAttribute("ForgeDecorRank")
	if type(decor) ~= "number" then
		return true
	end
	local kept = M.keepDecor(decor, profile)
	part.CastShadow = profile.decorShadows
	part.LocalTransparencyModifier = if kept then 0 else 1
	local effect = part:GetAttribute("ForgeEffectRank")
	if type(effect) == "number" then
		local enabled = kept and M.keepEffect(effect, profile)
		for _, child in part:GetChildren() do
			if table.find(EFFECT_CLASSES, child.ClassName) then
				child.Enabled = enabled
			end
		end
	end
	return kept
end

return M
