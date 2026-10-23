--!strict
-- QA-PERF-01 render caps: the low render profile enforces explicit limits on decorative
-- dressing parts, effect emitters, decor shadows, articulated wildlife and runtime
-- EditableMesh builds, and the high profile keeps the uncapped behaviour. Limits come
-- from game.yml `render_profiles`; RenderBudget.luau mirrors them.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local Dressing = require("./src/server/WorldDressing")
local RenderBudget = require("./src/shared/RenderBudget")

local PACK = "games/robango-island"

local function load(): any
	return serde.decode("yaml", fs.readFile(PACK .. "/content.yml"))
end

local function layoutOf(document: any, id: string): any
	for _, layout in document.layouts do
		if layout.id == id then
			return layout
		end
	end
	error("missing layout " .. id)
end

local function entry(layout: any): any
	for _, anchor in layout.anchors do
		if anchor.id == "entry" then
			return anchor.position
		end
	end
	return layout.anchors[1].position
end

-- Applies a profile to every planned part through the same code the client runs,
-- with a plain-table stand-in for a Part and its effect children.
local function render(plan: any, origin: any, profile: RenderBudget.Profile): (number, number, number, number)
	local decor = RenderBudget.rank(plan.parts, origin)
	local effects = RenderBudget.rank(plan.parts, origin, function(d: any): boolean
		return d.effect ~= nil
	end)
	local visible, emitting, shadowed, total = 0, 0, 0, 0
	for _, definition in plan.parts do
		local emitter = { ClassName = "ParticleEmitter", Enabled = true }
		local attributes = { ForgeDecorRank = decor[definition.id], ForgeEffectRank = effects[definition.id] }
		local part: any = {
			CastShadow = true,
			LocalTransparencyModifier = 0,
			GetAttribute = function(_, name: string): any
				return attributes[name]
			end,
			GetChildren = function(): { any }
				return if definition.effect then { emitter } else {}
			end,
		}
		total += 1
		if RenderBudget.applyPart(part, profile) then
			visible += 1
			assert(part.LocalTransparencyModifier == 0, "kept decor is visible")
		else
			assert(part.LocalTransparencyModifier == 1, "dropped decor is hidden")
		end
		if definition.effect and emitter.Enabled then
			emitting += 1
		end
		if part.CastShadow then
			shadowed += 1
		end
	end
	return visible, emitting, shadowed, total
end

return {
	["render_profiles in game.yml equal the RenderBudget mirror"] = function()
		local game = serde.decode("yaml", fs.readFile(PACK .. "/game.yml"))
		local declared = assert(game.render_profiles, "game.yml declares render_profiles")
		for name, profile in RenderBudget.profiles do
			for key, value in profile :: any do
				assert(declared[name][key] == value, string.format("%s.%s drifted from game.yml", name, key))
			end
			for key in declared[name] do
				assert((profile :: any)[key] ~= nil, string.format("%s.%s missing from mirror", name, key))
			end
		end
		local low, high = RenderBudget.profiles.low, RenderBudget.profiles.high
		assert(low.decorPartsMax < 768 and low.effectsMax < high.effectsMax, "low caps are below the 768-part plan")
		assert(
			low.meshBuildsMax < high.meshBuildsMax and not low.decorShadows and high.decorShadows,
			"low mesh/shadow caps"
		)
	end,
	["profile selection: low quality levels and Automatic on touch are low"] = function()
		assert(RenderBudget.select(1, false) == "low" and RenderBudget.select(3, false) == "low", "levels 1-3 are low")
		assert(
			RenderBudget.select(4, false) == "high" and RenderBudget.select(10, true) == "high",
			"levels 4+ are high"
		)
		assert(RenderBudget.select(0, true) == "low" and RenderBudget.select(0, false) == "high", "Automatic by touch")
	end,
	["low profile caps decor parts, effects and shadows on the densest stages; high keeps all"] = function()
		local document = load()
		local checkedCap = 0
		for _, layout in document.layouts do
			if layout.id == "rw.home" then
				continue
			end
			local plan = Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)
			local origin = entry(layout)
			local lowVisible, lowEmitting, lowShadowed, total = render(plan, origin, RenderBudget.profiles.low)
			local highVisible, highEmitting, highShadowed = render(plan, origin, RenderBudget.profiles.high)
			local effectCount = 0
			for _, d in plan.parts do
				effectCount += if d.effect then 1 else 0
			end
			assert(lowVisible == math.min(total, RenderBudget.profiles.low.decorPartsMax), layout.id .. " low parts")
			assert(lowEmitting <= RenderBudget.profiles.low.effectsMax, layout.id .. " low effects " .. lowEmitting)
			assert(lowShadowed == 0, layout.id .. " low decor casts no shadows")
			assert(highVisible == total and highEmitting == effectCount and highShadowed == total, layout.id .. " high")
			if total > RenderBudget.profiles.low.decorPartsMax then
				checkedCap += 1
			end
		end
		assert(checkedCap > 0, "at least one stage plan exceeds the low cap, so the cap is exercised")
	end,
	["low keeps the nearest decor to the spawn and drops the farthest"] = function()
		local layout = layoutOf(load(), "rw.a1.s1")
		local plan = Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)
		local origin = entry(layout)
		local ranks = RenderBudget.rank(plan.parts, origin)
		local function d2(id: string): number
			for _, d in plan.parts do
				if d.id == id then
					local p = d.ground or d.position
					return (p.x - origin.x) ^ 2 + (p.z - origin.z) ^ 2
				end
			end
			error(id)
		end
		local farthestKept, nearestDropped = 0, math.huge
		for id, rank in ranks do
			if RenderBudget.keepDecor(rank, RenderBudget.profiles.low) then
				farthestKept = math.max(farthestKept, d2(id))
			else
				nearestDropped = math.min(nearestDropped, d2(id))
			end
		end
		assert(farthestKept <= nearestDropped, "low drops only decor farther than everything it keeps")
	end,
	["low caps articulated wildlife by range and count; telegraphs are always posed"] = function()
		local entries = {}
		for index = 1, 20 do
			table.insert(entries, { key = index, distance = index * 4, urgent = false })
		end
		table.insert(entries, { key = "far-attacker", distance = 400, urgent = true })
		local function count(set: { [any]: boolean }): number
			local n = 0
			for _ in set do
				n += 1
			end
			return n
		end
		local low = RenderBudget.poses(entries, RenderBudget.profiles.low)
		local high = RenderBudget.poses(entries, RenderBudget.profiles.high)
		assert(count(low) == RenderBudget.profiles.low.wildlifePoseMax + 1, "low pose cap + urgent: " .. count(low))
		assert(low[1] and low[6] and not low[7] and low["far-attacker"], "low poses the six nearest plus the attacker")
		assert(count(high) == 21, "high poses every creature within 100 studs plus the attacker")
	end,
	["low builds fewer runtime EditableMeshes than high"] = function()
		local placements = { "a", "b", "c", "d", "e" }
		assert(#RenderBudget.meshes(placements, RenderBudget.profiles.low) == 2, "low mesh cap")
		assert(#RenderBudget.meshes(placements, RenderBudget.profiles.high) == 5, "high builds every placement")
	end,
	["live builders wire the profile: RoleWorld stamps ranks, the client applies them"] = function()
		local role = fs.readFile(PACK .. "/src/server/RoleWorld.luau")
		assert(
			string.find(role, '"ForgeDecorRank"', 1, true) and string.find(role, '"ForgeEffectRank"', 1, true),
			"RoleWorld stamps ranks"
		)
		local client = fs.readFile(PACK .. "/src/client/RobangoIslandClient.client.luau")
		for _, call in
			{ "RenderBudget.applyPart(", "RenderBudget.poses(", "RenderBudget.meshes(", "RenderBudget.select(" }
		do
			assert(string.find(client, call, 1, true), "client calls " .. call)
		end
	end,
}
