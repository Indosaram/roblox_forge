--!strict
-- p134 v50 (SM-N981N): a herd of three horned herbivores (protoceratops) walked up to an unarmed new
-- player near the onboarding spawn and downed them in ~20 s (HP 100 -> 58 -> 0) without one swing
-- from the player. Durango's early herbivores are passive or fight back only, and a fresh player
-- can always get away. This drives the real onboarding role build (RoleWorld via the production
-- world fixture) and the real wildlife AI (Wildlife.step) with the runtime rows it hands the world.
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content: any = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local Onboarding = require("./src/shared/OnboardingWildlife")
local Wildlife = require("../../genres/survival-coop/module/Wildlife")
local Archetype = require("../../core/domain/survival/Archetype")

local PLAYER_HEALTH_MILLI = 100000
local PLAYER_WALK = 16 -- baseWalkSpeed (RoleWorld World.new)

local function build(layout: string): any
	local engine = Engine.new(nil, true)
	return engine.role.build(Content, Source, Policy, function()
		return 0
	end, layout, 1776)
end

local function rows(world: any): ({ [string]: any }, { [string]: any })
	local byId: { [string]: any } = {}
	for _, row in world.roleContent.wildlife do
		byId[row.id] = row
	end
	return byId, world.roleWildlife.catalog.species
end

local function details(): { [string]: any }
	local out: { [string]: any } = {}
	for _, detail in Content.wildlifeDetails do
		out[detail.id] = detail
	end
	return out
end

-- One AI frame of `spawn` with the player standing `gap` studs from it (and maybe provoking it).
local function step(world: any, spawn: any, gap: number, provoked: boolean): (any, any)
	local byId, species = rows(world)
	local catalog = Wildlife.catalog(world.roleContent, world.roleWildlife.catalog)
	local state = Wildlife.new(spawn.id, spawn.catalogId, spawn.position, catalog)
	local actor = {
		id = "11734795308",
		alive = true,
		position = { x = spawn.position.x + gap, y = spawn.position.y, z = spawn.position.z },
	}
	local observation: any = {
		position = spawn.position,
		actors = { actor },
		pathFailed = false,
		lineOfSight = function()
			return true
		end,
		provokedBy = if provoked then actor.id else nil,
	}
	local now = 1000
	local nextState, intent = Wildlife.step(state, byId[spawn.catalogId], species[spawn.catalogId], now, observation)
	-- Walk the warn -> chase -> telegraph -> strike cycle to its first strike, if any.
	for _ = 1, 8 do
		if intent.damage then
			break
		end
		now += 1500
		observation.provokedBy = nil
		nextState, intent = Wildlife.step(nextState, byId[spawn.catalogId], species[spawn.catalogId], now, observation)
	end
	return nextState, intent
end

return {
	-- D2 R07 (p134 v63 lb_d1): at the default 50-stud camera the protoceratops herd read grey on grey
	-- ground. Every onboarding herd wears a species coat that stands off the painted onboarding ground
	-- (luminance or hue) and off every other herd's coat.
	["D2 R07: onboarding herds wear species coats that read against the onboarding ground"] = function()
		local engine = Engine.new(nil, true)
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.onboarding", 1776)
		local function luma(c: Color3): number
			return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B
		end
		local function hsv(c: Color3): (number, number)
			local high, low = math.max(c.R, c.G, c.B), math.min(c.R, c.G, c.B)
			local d = high - low
			local h = 0
			if d > 0 then
				h = if high == c.R
					then ((c.G - c.B) / d) % 6
					elseif high == c.G then (c.B - c.R) / d + 2
					else (c.R - c.G) / d + 4
			end
			return h * 60, if high > 0 then d / high else 0
		end
		local function apart(a: Color3, b: Color3): (boolean, string)
			local ha, sa = hsv(a)
			local hb = hsv(b)
			local dh = math.abs(ha - hb)
			dh = math.min(dh, 360 - dh)
			local dl = math.abs(luma(a) - luma(b))
			return dl >= 0.15 or (dh >= 60 and sa >= 0.4), string.format("dLuma %.3f dHue %.0f sat %.2f", dl, dh, sa)
		end
		local kinds = details()
		local herds: { [string]: Color3 } = {}
		local members: { [string]: number } = {}
		for _, spawn in world.roleWildlife.spawns do
			local detail = kinds[spawn.catalogId]
			if detail and detail.behaviour ~= "predator" then
				members[spawn.catalogId] = (members[spawn.catalogId] or 0) + 1
				if spawn.coat then
					herds[spawn.catalogId] = spawn.coat
				end
			end
		end
		local herdCount = 0
		for species, count in members do
			if count > 1 then
				herdCount += 1
				assert(typeof(herds[species]) == "Color3", species .. " herd wears a coat tint")
			end
		end
		assert(herdCount >= 4 and herds.protoceratops, "the onboarding herds (protoceratops first) were checked")
		local grounds = 0
		for material, ground in engine.terrainColors do
			grounds += 1
			for species, coat in herds do
				local ok, why = apart(coat, ground)
				assert(ok, species .. " coat reads as " .. material .. " ground: " .. why)
			end
		end
		assert(grounds >= 3 and engine.terrainColors.Grass, "the onboarding ground colours were read")
		for a, coatA in herds do
			for b, coatB in herds do
				if a < b then
					local ha, hb = hsv(coatA), hsv(coatB)
					local dh = math.min(math.abs(ha - hb), 360 - math.abs(ha - hb))
					local dl = math.abs(luma(coatA) - luma(coatB))
					assert(dh >= 30 or dl >= 0.15, a .. " and " .. b .. " share a coat")
				end
			end
		end
		world.destroy()
		-- Off onboarding nothing is tinted.
		local other = build("rw.explore10")
		for _, spawn in other.roleWildlife.spawns do
			assert(spawn.coat == nil, spawn.id .. " keeps its authored look off onboarding")
		end
		other.destroy()
	end,
	["onboarding herbivores never engage a player who walks up to them"] = function()
		local world = build("rw.onboarding")
		local kinds = details()
		local checked: { [string]: boolean } = {}
		for _, spawn in world.roleWildlife.spawns do
			local detail = kinds[spawn.catalogId]
			if detail and detail.behaviour ~= "predator" then
				local state, intent = step(world, spawn, 3, false)
				local hostile = state.mode == "warn" or state.mode == "chase" or state.mode == "telegraph"
				assert(
					intent.damage == nil and not hostile,
					spawn.id .. " (" .. spawn.catalogId .. ") engaged a player standing 3 studs away: " .. state.mode
				)
				checked[spawn.catalogId] = true
			end
		end
		assert(checked.protoceratops, "the v50 protoceratops herd is on the onboarding island and was checked")
		assert(checked.triceratops and checked.boar, "territorial triceratops and boar were checked")
		world.destroy()
	end,
	["a provoked onboarding herd strikes back but cannot down a fleeing new player"] = function()
		local world = build("rw.onboarding")
		local _, species = rows(world)
		local herd = 0
		local fastest = 0
		local kinds = details()
		for _, spawn in world.roleWildlife.spawns do
			if spawn.catalogId == "protoceratops" then
				herd += 1
			end
			local _, intent = step(world, spawn, 3, true)
			local detail = kinds[spawn.catalogId]
			if intent.damage then
				assert(
					intent.damage.damageMilli <= Onboarding.DAMAGE_CAP_MILLI,
					spawn.id .. " struck for " .. intent.damage.damageMilli
				)
			end
			if detail and detail.behaviour ~= "flee" then
				fastest = math.max(fastest, detail.runSpeed)
			end
		end
		for id, rule in species do
			assert(rule.damageMilli <= Onboarding.DAMAGE_CAP_MILLI, id .. " is capped on onboarding")
		end
		-- A whole provoked protoceratops herd, each striking once per warn + cooldown cycle, needs
		-- more than the v50 20 s to down a full-health player.
		local row: any = nil
		for _, entry in world.roleContent.wildlife do
			if entry.id == "protoceratops" then
				row = entry
			end
		end
		local cycle = (row.telegraphMillis + row.cooldownMillis) / 1000
		local seconds = PLAYER_HEALTH_MILLI / (herd * species.protoceratops.damageMilli) * cycle
		assert(seconds > 20, string.format("a provoked herd of %d downs a player in %.1f s", herd, seconds))
		assert(kinds.protoceratops.runSpeed < PLAYER_WALK, "a walking player outpaces the herd")
		assert(fastest > 0, "speeds read from content")
		world.destroy()
	end,
	["the onboarding rule leaves predators and every other island as authored"] = function()
		local kinds = details()
		for _, detail in Content.wildlifeDetails do
			if detail.behaviour == "predator" then
				local list = { { id = detail.id, behavior = "hunter" } }
				local species = { [detail.id] = { healthMilli = 1, damageMilli = 50000, drops = {} } }
				Onboarding.apply(Content, "rw.onboarding", list, species)
				assert(list[1].flag == nil, detail.id .. " keeps its own flag")
				assert(species[detail.id].damageMilli == Onboarding.DAMAGE_CAP_MILLI, "predators are capped too")
			end
		end
		local world = build("rw.explore10")
		local byId, species = rows(world)
		for _, entry in Content.wildlife do
			if byId[entry.id] then
				assert(byId[entry.id].flag == entry.flag, entry.id .. " flag unchanged off onboarding")
			end
		end
		for _, detail in Content.wildlifeDetails do
			assert(species[detail.id].damageMilli == detail.damage * 1000, detail.id .. " damage unchanged")
		end
		assert(kinds.triceratops.behaviour == "territorial", "content keeps triceratops territorial elsewhere")
		local flag = Archetype.get("hunter")
		assert(flag and flag.flag == "aggressive", "the hunter archetype default is aggressive")
		world.destroy()
	end,
}
