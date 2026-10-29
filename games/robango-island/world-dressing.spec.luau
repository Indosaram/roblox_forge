--!strict
local Content = require("./src/shared/SurvivalContent")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local Dressing = require("./src/server/WorldDressing")
local HomeWorld = require("./src/server/HomeWorld")
local HomeContent = require("../../core/domain/home/HomeContent")
local Home = require("../../core/domain/home/HomeState")
local serde = require("@lune/serde")

local function validate(layout: any, plan: any)
	assert(#plan.parts <= 768, "world art budget")
	for _, p in plan.kits do
		for _, path in layout.paths do
			for i = 2, #path.points do
				assert(
					Terrain.distance(p.x, p.z, path.points[i - 1], path.points[i]) > path.width / 2,
					p.id .. " stands on path " .. path.id
				)
			end
		end
	end
end

return {
	["every buildable structure has a volumetric kit and campfire emits fire and light"] = function()
		local engine = require("../../cli/forge/fixtures/production-worlds/engine").new()
		for _, definition in Content.structures do
			local model = engine.dressing.structure(nil, definition, 4)
			local count, height, flame, light = 0, 0, false, false
			for _, part in model:GetDescendants() do
				if part:IsA("BasePart") then
					count += 1
					height = math.max(height, part.CFrame.Position.Y + part.Size.Y / 2)
				elseif part:IsA("Fire") then
					flame = part.Size <= 3 and part.Heat <= 5
				elseif part:IsA("PointLight") then
					light = part.Range <= 12 and part.Brightness <= 1
				end
			end
			assert(count > 1 and height > 0.5, definition.id .. " must not be a flat slab")
			if definition.id == "campfire" then
				assert(count > 8 and flame and light, "stone ring logs fire and light")
			end
		end
	end,
	["art kits have pitched thatch rounded foliage and grounded supports within budget"] = function()
		local palette = Dressing.palette({ biomes = { "grassland" } })
		for _, kind in { "shelter", "bush", "fern", "rock", "workbench", "campfire" } do
			local parts = {}
			Dressing.kit(parts, kind, { x = 0, y = 0, z = 0 }, kind, palette)
			assert(#parts > 0 and #parts <= 90, "kit part budget: " .. kind)
			local roof, lash, ring = 0, 0, 0
			for _, p in parts do
				if string.find(p.id, ".roof", 1, true) then
					roof += 1
					assert(p.shape == "Wedge" and math.abs(p.roll) >= 45, "steep layered thatch")
				elseif string.find(p.id, ".lash", 1, true) then
					lash += 1
				elseif string.find(p.id, ".ring", 1, true) then
					ring += 1
				end
				if kind == "bush" then
					assert(p.shape == "Ball", "rounded bush lobes")
				elseif kind == "fern" then
					assert(p.shape == "Wedge" and p.size.x <= 0.35, "thin fan fronds")
				elseif kind == "rock" then
					assert((p.material == "Slate" or p.material == "Rock") and p.yaw ~= 0, "irregular stone cluster")
				end
				if
					string.find(p.id, ".post", 1, true)
					or string.find(p.id, ".leg", 1, true)
					or string.find(p.id, ".skirt", 1, true)
					or string.find(p.id, ".ring", 1, true)
					or kind == "rock"
					or kind == "bush"
					or kind == "fern"
				then
					local roll = math.rad(p.roll or 0)
					local height = math.abs(math.sin(roll)) * p.size.x + math.abs(math.cos(roll)) * p.size.y
					assert(p.position.y - height / 2 <= 0.5, "ground contact: " .. p.id)
				end
			end
			if kind == "shelter" then
				assert(roof == 40 and lash == 12, "complete thatched frame")
				for _, p in parts do
					local roll = math.rad(p.roll or 0)
					assert(
						p.position.y + (math.abs(math.sin(roll)) * p.size.x + math.abs(math.cos(roll)) * p.size.y) / 2
							<= 15,
						"shelter under three humanoid heights"
					)
				end
			elseif kind == "workbench" then
				assert(lash == 6, "lashed workbench logs")
			elseif kind == "campfire" then
				assert(ring == 8, "stone fire ring")
			end
		end
	end,
	["B1 kit placements name real rows of the role's own kits"] = function()
		local BiomeKits = require("./src/shared/BiomeKits")
		for _, layout in Content.layouts :: any do
			local columns = if layout.id == "rw.home" then {} else Terrain.columns(layout, 79, 32)
			local plan = Dressing.plan(layout, columns, Terrain)
			local allowed = BiomeKits.kitsFor(layout)
			for _, p in plan.kits do
				assert(table.find(allowed, p.kit), layout.id .. " " .. p.id .. " uses kit " .. p.kit)
				local found = false
				for _, row in BiomeKits.kits[p.kit] do
					found = found or (row.key == p.key and row.family == p.family)
				end
				assert(found, layout.id .. " " .. p.id .. " names unknown row " .. p.key)
				assert(p.scale > 0 and p.scale <= 3, p.id .. " scale")
			end
		end
	end,
	["authored landmarks reach the production dressing plan as hero B1 rows"] = function()
		local count = 0
		for _, layout in Content.layouts :: any do
			if layout.art then
				count += 1
				local landmark = layout.art.landmark
				local plan = Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)
				local found = 0
				for _, p in plan.kits do
					if p.id == landmark.id or string.sub(p.id, 1, #landmark.id + 1) == landmark.id .. "." then
						found += 1
						assert(
							p.family == landmark.kind,
							landmark.id .. " is a " .. landmark.kind .. ", got " .. p.family
						)
						local d = math.sqrt((p.x - landmark.position.x) ^ 2 + (p.z - landmark.position.z) ^ 2)
						assert(
							d <= math.max(landmark.size.x, landmark.size.z) / 2,
							landmark.id .. " left its footprint"
						)
					end
				end
				assert(found >= 1, "authored landmark omitted: " .. layout.id)
			end
		end
		assert(count == 20, "all authored expedition landmarks must ship")
	end,
	["paths are painted into terrain, never laid as parts"] = function()
		for _, layout in Content.layouts :: any do
			if layout.id == "rw.home" then
				continue
			end
			local plan = Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)
			local strokes = 0
			for _, stroke in plan.paint do
				if stroke.shape == "segment" and stroke.material == "Ground" then
					strokes += 1
				end
			end
			local low, high = layout.bounds.min, layout.bounds.max
			local function within(p: any): boolean
				return p.x >= low.x and p.x <= high.x and p.z >= low.z and p.z <= high.z
			end
			local inside = 0
			for _, path in layout.paths do
				for i = 2, #path.points do
					local a, b = path.points[i - 1], path.points[i]
					local from = { x = math.clamp(a.x, low.x, high.x), z = math.clamp(a.z, low.z, high.z) }
					local to = { x = math.clamp(b.x, low.x, high.x), z = math.clamp(b.z, low.z, high.z) }
					if (within(a) or within(b)) and (from.x ~= to.x or from.z ~= to.z) then
						inside += 1
					end
				end
			end
			assert(strokes == inside, layout.id .. " paints " .. strokes .. " of " .. inside .. " path segments")
		end
	end,
	-- L10 (R03-3: worn earth, moss and scree break up the arrival ground): variety patches paint
	-- flat inland ground around the arrival, never beach, paths, nodes or the home/town roles.
	["arrival ground carries seeded variety patches off paths beaches and nodes"] = function()
		local function find(id: string): any
			for _, layout in Content.layouts :: any do
				if layout.id == id then
					return layout
				end
			end
			return nil
		end
		local layout = assert(find("rw.onboarding"), "onboarding layout")
		local columns = Terrain.columns(layout, 79, 16)
		local plan = Dressing.plan(layout, columns, Terrain)
		local again = Dressing.plan(layout, columns, Terrain)
		local count, materials = 0, {}
		for i, stroke in plan.paint do
			if not stroke.patch then
				continue
			end
			count += 1
			materials[stroke.material] = true
			assert(stroke.shape == "disc" and stroke.position.y > 0.5, stroke.id .. " on land")
			assert(again.paint[i].id == stroke.id and again.paint[i].position.x == stroke.position.x, "deterministic")
			for _, node in layout.resourceNodes do
				local d =
					math.sqrt((stroke.position.x - node.position.x) ^ 2 + (stroke.position.z - node.position.z) ^ 2)
				assert(d >= stroke.radius, stroke.id .. " covers node " .. node.id)
			end
			for _, path in layout.paths do
				for j = 2, #path.points do
					local gap =
						Terrain.distance(stroke.position.x, stroke.position.z, path.points[j - 1], path.points[j])
					assert(gap > path.width / 2, stroke.id .. " paints path " .. path.id)
				end
			end
		end
		assert(count >= 24 and count <= Dressing.PATCH.count * 2, "onboarding patches: " .. count)
		assert(materials.LeafyGrass and materials.Ground, "moss and bare earth both appear")
		for _, id in { "rw.home", "rw.town" } do
			local other = find(id)
			if other then
				for _, stroke in Dressing.plan(other, Terrain.columns(other, 79, 32), Terrain).paint do
					assert(not stroke.patch, id .. " keeps its authored ground")
				end
			end
		end
	end,
	["volcano has luminous flows ash and hot spring effects"] = function()
		local lava, ash, steam, crust = false, false, false, false
		for _, layout in Content.layouts :: any do
			local plan = Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)
			for _, effect in plan.effects do
				lava = lava or effect.effect == "lava"
				ash = ash or effect.effect == "ash"
				steam = steam or effect.effect == "steam"
			end
			for _, stroke in plan.paint do
				crust = crust or stroke.material == "CrackedLava"
			end
		end
		assert(lava and ash and steam and crust, "volcanic effects missing")
	end,
	["home camp includes crops storage fire and path without repeated awnings"] = function()
		local rules = HomeContent.rules(Content)
		local parts = HomeWorld.plan(Content, Home.new("owner", rules, 79), rules)
		local ids = {}
		for _, part in parts do
			ids[part.id] = true
			assert(not string.find(part.id, ".awning", 1, true), "duplicated starter shelters")
		end
		assert(
			ids["home.fire.embers"] and ids["home.farm.soil"] and ids["home.storage.basket0"] and ids["home.path"],
			"home camp components missing"
		)
	end,
	["world dressing is deterministic budgeted and preserves catalog clearance for every role"] = function()
		for _, layout in Content.layouts :: any do
			local columns = Terrain.columns(layout, 79, 32)
			local plan = Dressing.plan(layout, columns, Terrain)
			validate(layout, plan)
			assert(
				serde.encode("json", plan)
					== serde.encode("json", Dressing.plan(layout, Terrain.columns(layout, 79, 32), Terrain)),
				layout.id
			)
			local wet, dry = false, false
			for _, column in columns do
				wet = wet or column.top < -4
				dry = dry or column.top > 0
			end
			if string.match(layout.id, "^rw%.a%d+%.s%d+$") then
				-- Organic coasts leave offshore cells to the sea fill instead of emitting wet
				-- columns, so the shore shows as authored-bounds cells with no land column.
				local full = 0
				for _ = layout.bounds.min.x + 16, layout.bounds.max.x - 16, 32 do
					for _ = layout.bounds.min.z + 16, layout.bounds.max.z - 16, 32 do
						full += 1
					end
				end
				local inside = 0
				for _, column in columns do
					if
						column.x > layout.bounds.min.x
						and column.x < layout.bounds.max.x
						and column.z > layout.bounds.min.z
						and column.z < layout.bounds.max.z
					then
						inside += 1
					end
				end
				wet = wet or inside < full
				assert(wet and dry, "archipelago must have shore and dry land: " .. layout.id)
			end
		end
	end,
	["world dressing negative mutation rejects kit rows on a path and over budget"] = function()
		local layout: any = (Content.layouts :: any)[1]
		local on = layout.paths[1].points[1]
		local plan: any = { parts = {}, kits = { { id = "mutant", x = on.x, z = on.z } } }
		assert(not pcall(validate, layout, plan), "clearance mutation must fail")
		plan.kits = {}
		for i = 1, 769 do
			plan.parts[i] = {}
		end
		assert(not pcall(validate, layout, plan), "part budget mutation must fail")
		assert(not pcall(Terrain.columns, layout, 79, 0), "zero cell must fail instead of looping")
	end,
	["home art expands fenced shelter without replacing durable land"] = function()
		local rules = HomeContent.rules(Content)
		local home = Home.new("owner", rules, 79)
		for _, rank in { 1, 5 } do
			home.landRank = rank
			local parts = HomeWorld.plan(Content, home, rules)
			local shelter, fence = false, false
			for _, part in parts do
				shelter = shelter or part.id == "home.shelter.bedroll"
				fence = fence or string.find(part.id, "home.fence.", 1, true) ~= nil
			end
			assert(shelter and fence and parts[1].size.x == rules.landSizes[rank], "home visual rank projection")
			for _, part in parts do
				if string.find(part.id, "home.tree", 1, true) then
					assert(math.sqrt(part.position.x ^ 2 + part.position.z ^ 2) >= 24, "tall prop inside camp radius")
				end
			end
		end
	end,
}
