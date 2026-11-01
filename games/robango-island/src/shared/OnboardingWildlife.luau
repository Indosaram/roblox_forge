--!strict
-- p134 v50: on onboarding, non-predators fight back only and strikes are capped (a protoceratops
-- herd downed an unarmed new player in ~20 s). Other layouts are untouched.
local M = {}

M.LAYOUT = "rw.onboarding"
-- Milli HP per strike: a provoked herd of four needs ~25 s to down a player (100 000).
M.DAMAGE_CAP_MILLI = 3000
-- D2 R07 (phone, CameraConfig distance 50): the first herds read grey on grey ground. Each onboarding
-- herbivore wears a species coat tint (SurvivalWorld spawn.coat -> DinosaurMotion fill Highlight over
-- the baked texture; no new texture). Every coat is either much brighter than the onboarding ground or
-- far from its olive hue (onboarding-wildlife.spec), and no two species share one.
M.COATS = table.freeze({
	dodo = { 120, 140, 240 },
	protoceratops = { 240, 150, 50 },
	parasaurolophus = { 60, 200, 190 },
	triceratops = { 220, 60, 140 },
	turtle = { 245, 225, 120 },
})

--- Coat tint { r, g, b } of an onboarding spawn's species, nil elsewhere (no tint).
function M.coat(layoutId: string, speciesId: string): { number }?
	return if layoutId == M.LAYOUT then M.COATS[speciesId] else nil
end

--- Rewrites runtime wildlife rows and catalog species in place; no-op off onboarding.
function M.apply(content: any, layoutId: string, wildlife: { any }, species: { [string]: any })
	if layoutId ~= M.LAYOUT then
		return
	end
	local predator: { [string]: boolean } = {}
	for _, detail in content.wildlifeDetails or {} do
		if detail.behaviour == "predator" then
			predator[detail.id] = true
		end
	end
	for index, row in wildlife do
		if not predator[row.id] and row.behavior ~= "grazer" and row.behavior ~= "herd-grazer" then
			local calm = table.clone(row)
			calm.flag = "retaliate"
			wildlife[index] = calm
		end
	end
	for id, rule in species do
		if rule.damageMilli > M.DAMAGE_CAP_MILLI then
			local capped = table.clone(rule)
			capped.damageMilli = M.DAMAGE_CAP_MILLI
			species[id] = capped
		end
	end
end

return M
