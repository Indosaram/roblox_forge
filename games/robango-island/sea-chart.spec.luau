--!strict
-- C7 sea chart and drift isles (G20, G25): chart layout at phone and PC sizes, the live gates
-- (locked islands refused), drift-isle seeds (reset = new recorded seed, same seed = same layout)
-- and the drift camp with its rift on every archipelago stage.
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local SeaChart = require("./src/shared/SeaChart")
local Dressing = require("./src/server/WorldDressing")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local Archipelago = require("../../core/domain/island/Archipelago")
local Fit = require("../../core/ui-kit/genre/HudFit")
local Fixture = require("./PackText.fixture")

local VIEWPORTS = { { 800, 360, 0 }, { 850, 411, 58 }, { 1920, 1080, 0 } }

local function overlaps(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

local function inside(inner: any, outer: any): boolean
	return inner.x >= outer.x
		and inner.y >= outer.y
		and inner.x + inner.width <= outer.x + outer.width
		and inner.y + inner.height <= outer.y + outer.height
end

local function text(locale: string): (string, ...any) -> string
	return function(key: string, ...: any): string
		local row = Fixture.packText(locale, "cli.chart." .. key)
		assert(row, "missing cli.chart." .. key)
		return if select("#", ...) > 0 then string.format(row, ...) else row
	end
end

local function layoutOf(id: string): any
	for _, layout in Content.layouts do
		if layout.id == id then
			return layout
		end
	end
	error("layout " .. id)
end

local function harborView(level: number, access: number): any
	return {
		role = "harbor",
		level = level,
		facts = { level = level, developmentRank = 10, instabilityAccess = access },
	}
end

local function openTrip(now: number): any
	local state = assert(Archipelago.open(Content, {
		id = "trip-1",
		actor = "1",
		index = 1,
		seed = SeaChart.departureSeed(now, "1"),
		revision = "robango-route-v1",
		ttl = SeaChart.TTL,
		entryBuffer = 60,
	}, { level = 60, developmentRank = 10, instabilityAccess = 5 }, now))
	return state
end

return {
	["chart layout: no overlap, touch >= 44 px, text >= 13 px at 800x360, 850x411 and 1920x1080"] = function()
		for _, v in VIEWPORTS do
			local width, height, top = v[1], v[2], v[3]
			local tag = width .. "x" .. height
			local layout = SeaChart.layout(width, height, top)
			local screen = { x = 0, y = top, width = width, height = height - top }
			for key, size in layout.text do
				assert(size >= 13, tag .. " text " .. key .. " " .. size)
			end
			assert(layout.close.width >= 44 and layout.close.height >= 44, tag .. " close touch")
			assert(not overlaps(layout.title, layout.close), tag .. " title vs close")
			local blocks: { { any } } = { { "header", layout.header }, { "compass", layout.compass } }
			for _, island in SeaChart.ISLANDS do
				local tile = layout.tiles[island.id]
				assert(tile.marker.width >= 44 and tile.marker.height >= 44, tag .. " " .. island.id .. " touch")
				assert(inside(tile.tile, layout.chart), tag .. " " .. island.id .. " leaves the chart")
				for _, part in { tile.marker, tile.name, tile.chip } do
					assert(inside(part, tile.tile), tag .. " " .. island.id .. " part outside its tile")
				end
				table.insert(blocks, { island.id, tile.tile })
			end
			assert(inside(layout.chart, screen) and inside(layout.compass, layout.chart), tag .. " chart on screen")
			for i, a in blocks do
				for j = i + 1, #blocks do
					local b = blocks[j]
					assert(not overlaps(a[2], b[2]), tag .. " " .. a[1] .. " overlaps " .. b[1])
				end
			end
			-- Bottom sheet: 0.28H or taller, on screen, its lines never under the primary button.
			local sheet = layout.sheet
			assert(sheet.frame.height >= math.floor(0.28 * layout.safeHeight), tag .. " sheet height")
			assert(inside(sheet.frame, screen), tag .. " sheet on screen")
			assert(sheet.sail.width >= 44 and sheet.sail.height >= 44, tag .. " sail touch")
			for _, line in { sheet.name, sheet.info, sheet.status } do
				assert(inside(line, sheet.frame) and not overlaps(line, sheet.sail), tag .. " sheet line")
			end
			assert(not overlaps(sheet.name, sheet.info) and not overlaps(sheet.info, sheet.status), tag .. " lines")
			assert(inside(layout.timer, screen) and layout.timer.height >= 28, tag .. " HUD timer")
			-- Island names and band chips fit their tile in both languages.
			for _, locale in { "en-us", "ko-kr" } do
				local copyText = text(locale)
				for _, card in SeaChart.islands(Content, harborView(60, 5)) do
					local copy = SeaChart.copy(card, copyText, 0)
					local tile = layout.tiles[card.id]
					assert(
						Fit.textWidth(copy.name, layout.text.name) <= tile.name.width,
						tag .. " " .. locale .. " name overflows: " .. copy.name
					)
					assert(
						Fit.textWidth(copy.chip, layout.text.chip) <= tile.chip.width,
						tag .. " " .. locale .. " chip overflows: " .. copy.chip
					)
				end
				local sail = copyText("sail")
				assert(Fit.textWidth(sail, layout.text.heading) <= sheet.sail.width, tag .. " sail label")
				assert(Fit.textWidth(copyText("step"), layout.text.heading) <= sheet.sail.width, tag .. " step label")
			end
		end
	end,
	["chart islands: an archipelago of distinct biomes with level bands; Korean and English copy"] = function()
		local cards = SeaChart.islands(Content, harborView(60, 5))
		local biomes: { [string]: boolean } = {}
		local drift = 0
		for _, card in cards do
			for _, biome in card.biomes do
				biomes[biome] = true
			end
			drift += if card.drift then 1 else 0
			if card.role and card.role ~= "home" and card.role ~= "harbor" then
				assert(card.band and card.band.min >= 10, card.id .. " band")
			end
		end
		local count = 0
		for _ in biomes do
			count += 1
		end
		assert(#cards >= 13 and drift == 5, "13 chart islands, 5 drift isles")
		assert(count >= 6, "at least six biomes on the chart, got " .. count)
		local band = SeaChart.band(Content, { role = "explore10" })
		assert(band.min == 10 and band.max == 19, "explore10 band 10-19")
		assert(SeaChart.band(Content, { role = "frontier60" }).max == nil, "open-ended top band")
		local en, ko = text("en-us"), text("ko-kr")
		assert(en("band", 10, 19) == "Lv 10-19" and ko("band", 10, 19) == "레벨 10-19", "band chip copy")
		assert(en("sail") == "Set sail" and ko("sail") == "출항", "dock button copy")
		assert(en("step") == "Step through" and ko("step") == "균열 통과", "rift button copy")
		assert(ko("hud_timer", "1:38") == "표류섬 남은 시간 1:38", "HUD timer copy")
		assert(
			SeaChart.clock(98) == "1:38" and SeaChart.clock(-5) == "0:00" and SeaChart.clock(3725) == "1:02:05",
			"countdown format"
		)
	end,
	["NEGATIVE: a locked island is refused by the chart gate and shown locked"] = function()
		-- Level 59 at the harbor: frontier60 is locked (level_gate) and the voyage is refused.
		local ok, reason = SeaChart.sail("frontier60", "harbor", 59, "dock")
		assert(not ok and reason == "level_gate", "frontier60 at level 59: " .. tostring(reason))
		ok, reason = SeaChart.sail("frontier60", "harbor", 60, "dock")
		assert(ok, "frontier60 at level 60 sails: " .. tostring(reason))
		-- No dock or rift in reach, an unknown island, the current island, a non-edge.
		assert(select(2, SeaChart.sail("explore10", "harbor", 60, nil)) == "sail_unreachable", "needs a sail point")
		assert(select(2, SeaChart.sail("archipelago", "harbor", 60, "dock")) == "invalid_route", "drift via party")
		assert(select(2, SeaChart.sail("harbor", "harbor", 60, "rift")) == "transition_not_allowed", "same island")
		assert(select(2, SeaChart.sail("explore10", "home", 60, "dock")) == "transition_not_allowed", "home edges")
		assert(select(2, SeaChart.sail("harbor", "archipelago", 60, "rift")) == "transition_not_allowed", "rift home")
		assert(SeaChart.sail("home", "archipelago", 1, "rift"), "a drift-isle rift leads home")
		local locked: { [string]: string } = {}
		for _, card in SeaChart.islands(Content, harborView(35, 1)) do
			if card.locked then
				locked[card.id] = card.reason
			end
		end
		assert(locked.frontier40 == "level_gate" and locked.frontier60 == "level_gate", "role islands locked")
		assert(locked.drift2 == "instability_gate", "drift2 needs route access 2: " .. tostring(locked.drift2))
		assert(locked.drift3 == "level_gate", "drift3 needs level 40: " .. tostring(locked.drift3))
		assert(locked.drift1 == nil, "drift1 open at level 35: " .. tostring(locked.drift1))
		assert(locked.explore10 == nil and locked.frontier30 == nil, "open bands stay open")
		for _, key in { "level_gate", "sail_unreachable", "invalid_route", "drift_reset" } do
			for _, locale in { "en-us", "ko-kr" } do
				assert(Fixture.packText(locale, "trv." .. key), "trv." .. key .. " " .. locale)
			end
		end
	end,
	["NEGATIVE: an expired drift isle regenerates from a different recorded seed"] = function()
		local state = openTrip(3600)
		local first, expiresAt = state.seed, state.expiresAt
		local ok, reason = SeaChart.driftReset(state, expiresAt - 1, SeaChart.TTL)
		assert(not ok and reason == "not_expired" and state.seed == first, "a live isle keeps its seed")
		assert(
			Archipelago.admit(
				state,
				Content,
				{ level = 60, developmentRank = 10, instabilityAccess = 5 },
				expiresAt,
				60
			) == false,
			"an expired isle refuses entry"
		)
		ok = SeaChart.driftReset(state, expiresAt, SeaChart.TTL)
		assert(ok and state.seed ~= first, "reset takes a new seed")
		assert(state.driftSeeds[1].from == first and state.driftSeeds[1].to == state.seed, "seed change recorded")
		assert(state.expiresAt == expiresAt + SeaChart.TTL, "a fresh window from the explicit clock")
		assert(
			Archipelago.admit(
				state,
				Content,
				{ level = 60, developmentRank = 10, instabilityAccess = 5 },
				expiresAt,
				60
			),
			"the regenerated isle admits again"
		)
		local second = state.seed
		ok = SeaChart.driftReset(state, state.expiresAt, SeaChart.TTL)
		assert(ok and state.seed ~= second and state.seed ~= first and state.driftGeneration == 2, "every reset is new")
		-- Determinism: the same recorded history reproduces the same seeds.
		local replay = openTrip(3600)
		SeaChart.driftReset(replay, expiresAt, SeaChart.TTL)
		assert(replay.seed == second, "same seed history, same reset seed")
		state.status = "complete"
		assert(
			select(2, SeaChart.driftReset(state, state.expiresAt + 1, SeaChart.TTL)) == "expedition_inactive",
			"a finished route never resets"
		)
		assert(SeaChart.departureSeed(100, "1") == SeaChart.departureSeed(100, "1"), "departure seed recorded")
		assert(SeaChart.departureSeed(100, "1") ~= SeaChart.departureSeed(101, "1"), "departure seed follows clock")
	end,
	["same seed same layout; a reset seed regenerates the drift isle"] = function()
		local layout = layoutOf("rw.a1.s1")
		local state = openTrip(3600)
		local function shape(seed: number): string
			local parts = {}
			for _, column in Terrain.columns(layout, seed, 32) do
				table.insert(parts, string.format("%d,%d,%.3f", column.x, column.z, column.top))
			end
			local plan = Dressing.plan(layout, Terrain.columns(layout, seed, 32), Terrain)
			for _, part in plan.parts do
				table.insert(parts, string.format("%s@%.2f,%.2f", part.id, part.position.x, part.position.z))
			end
			return table.concat(parts, ";")
		end
		local before = shape(state.seed)
		assert(shape(state.seed) == before, "same seed, same layout")
		SeaChart.driftReset(state, state.expiresAt, SeaChart.TTL)
		assert(shape(state.seed) ~= before, "new seed, regenerated layout")
	end,
	["drift camp: clear spots on every drift isle; the rift and chart table open the chart"] = function()
		local checked = 0
		for _, layout in Content.layouts do
			local camp = Dressing.driftCamp(layout)
			if not camp then
				continue
			end
			checked += 1
			local head = Dressing.trailhead(layout).position
			for _, key in { "fire", "tent", "rift" } do
				local p = camp[key]
				local d = math.sqrt((p.x - head.x) ^ 2 + (p.z - head.z) ^ 2)
				assert(d <= 50, layout.id .. " " .. key .. " is " .. d .. " studs from arrival")
				for _, node in layout.resourceNodes do
					local gap = math.sqrt((node.position.x - p.x) ^ 2 + (node.position.z - p.z) ^ 2)
					assert(gap >= 10, layout.id .. " camp " .. key .. " on node " .. node.id)
				end
				for _, path in layout.paths do
					for i = 2, #path.points do
						local gap = Terrain.distance(p.x, p.z, path.points[i - 1], path.points[i])
						assert(gap > path.width / 2 + 4, layout.id .. " camp " .. key .. " on trail " .. path.id)
					end
				end
			end
		end
		assert(checked == 20, "all 20 drift-isle layouts have a camp, got " .. checked)
		assert(Dressing.driftCamp(layoutOf("rw.harbor")) == nil, "no drift camp in town")
		for _, id in { "rw.a1.s1", "rw.harbor" } do
			local engine = Engine.new()
			local world = engine.role.build(Content, Source, Policy, function()
				return 0
			end, id, 1776)
			world.bind({} :: any)
			local root = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld")
			local panels: { [string]: boolean } = {}
			for _, prompt in root:GetDescendants() do
				if prompt:IsA("ProximityPrompt") and prompt.Name == "ForgeSeaChart" then
					panels[prompt:GetAttribute("ForgePanel")] = true
					assert(prompt.MaxActivationDistance >= 8, "sail point reach")
				end
			end
			if id == "rw.a1.s1" then
				assert(root:FindFirstChild("DriftCamp.fire") and root:FindFirstChild("DriftCamp.tent"), "camp built")
				assert(root:FindFirstChild("DriftCamp.rift.fissure"), "rift fissure built")
				assert(panels["sea-chart-rift"], "drift isle rift opens the chart")
			else
				assert(panels["sea-chart-dock"] and panels["sea-chart-rift"], "harbor chart table and rift")
				assert(root:FindFirstChild("HarborRift.fissure"), "harbor rift fissure")
			end
			-- NEGATIVE: away from every sail point the server refuses the voyage.
			world.nearPart = function()
				return false
			end
			assert(world.sailPoint("1") == nil, id .. " no sail point out of reach")
			world.nearPart = function(_, target)
				return target:GetAttribute("ForgeSailPoint") == "rift"
			end
			assert(world.sailPoint("1") == "rift", id .. " rift in reach")
			world.destroy()
		end
	end,
}
