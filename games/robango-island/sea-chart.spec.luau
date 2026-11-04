--!strict
-- C7 sea chart and drift isles (G20, G25): chart layout at phone and PC sizes, the live gates
-- (locked islands refused), drift-isle seeds (reset = new recorded seed, same seed = same layout)
-- and the drift camp with its rift on every archipelago stage.
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local SkillTree = require("../../core/domain/progression/SkillTree")
local Content = require("./src/shared/SurvivalContent")
local Source = require("./src/shared/SurvivalWorldConfig")
local Policy = require("./src/shared/WildlifePolicy")
local SeaChart = require("./src/shared/SeaChart")
local RiftFx = require("./src/shared/RiftFx")
local Dressing = require("./src/server/WorldDressing")
local Terrain = require("../../core/domain/island/ArchipelagoTerrain")
local Archipelago = require("../../core/domain/island/Archipelago")
local Fit = require("../../core/ui-kit/genre/HudFit")
local Fixture = require("./PackText.fixture")
local Party = require("../../core/domain/island/Party")
local HudShell = require("../../genres/survival-coop/module/HudShell")
local roblox: any = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local VIEWPORTS = { { 800, 360, 0 }, { 850, 411, 58 }, { 1920, 1080, 0 } }
-- Staging v40 phone: the chart gui read ~800x360 with a 108 px top clearance (the top bar cleared
-- twice); rows were shorter than a tile and every name/band label ran over the next row's marker.
local SQUEEZED = { 800, 360, 108 }

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

-- Headless panel: SeaChart.panel on a fake Instance tree with the v40 phone numbers (an 800x360
-- IgnoreGuiInset gui at AbsolutePosition y -54 under a 54 px top bar) and a pushed snapshot.
-- `options.at` (Vector3): the character's root; `options.spots` the world's ForgeSailSpots;
-- `options.walkTo(goal, arrive)` the tap router walk.
local function mountPanel(role: string, snapshot: any, clock: (() -> number)?, options: any?): any
	local opts = options or {}
	local made: { any } = {}
	local entries: { any } = {}
	local function signal(): any
		local handlers = {}
		return {
			Connect = function(_, fn)
				table.insert(handlers, fn)
				return { Disconnect = function() end }
			end,
			Fire = function(_, ...)
				for _, fn in handlers do
					fn(...)
				end
			end,
		}
	end
	local function new(className: string): any
		local item: any = { ClassName = className, Name = className, Activated = signal() }
		if className == "ScreenGui" then
			item.AbsoluteSize, item.AbsolutePosition = roblox.Vector2.new(800, 360), roblox.Vector2.new(0, -54)
		end
		function item:IsA(kind)
			return kind == self.ClassName
		end
		function item:IsDescendantOf(parent)
			local at = self.Parent
			while at do
				if at == parent then
					return true
				end
				at = at.Parent
			end
			return false
		end
		function item:FindFirstChild(name, recursive)
			for _, other in made do
				if other.Name == name and (other.Parent == self or (recursive and other:IsDescendantOf(self))) then
					return other
				end
			end
			return nil
		end
		function item:WaitForChild(name)
			return assert(self:FindFirstChild(name), name)
		end
		function item:GetChildren()
			local list = {}
			for _, other in made do
				if other.Parent == self then
					table.insert(list, other)
				end
			end
			return list
		end
		function item:GetAttribute(key)
			return (self.attributes or {})[key]
		end
		function item:SetAttribute(key, value)
			self.attributes = self.attributes or {}
			self.attributes[key] = value
		end
		function item:Destroy()
			self.Parent = nil
		end
		table.insert(made, item)
		return item
	end
	local player = new("Player")
	new("PlayerGui").Parent = player
	player.Name = "Player"
	for _, item in made do
		if item.ClassName == "PlayerGui" then
			item.Name = "PlayerGui"
		end
	end
	local attributes = { ForgeWorldRole = role }
	local roleWorld = new("Folder")
	roleWorld.Name = "ForgeRoleWorld"
	roleWorld:SetAttribute("ForgeSailSpots", opts.spots)
	if opts.at then
		local character = new("Model")
		local root = new("Part")
		root.Name, root.Parent, root.Position = "HumanoidRootPart", character, opts.at
		player.Character = character
	end
	local stage = new("Workspace")
	local services: any = {
		Players = { LocalPlayer = player },
		RunService = { Heartbeat = signal() },
		GuiService = { TopbarInset = { Max = roblox.Vector2.new(800, 54) } },
	}
	local env: any
	env = {
		game = {
			GetService = function(_, key)
				return services[key]
			end,
		},
		workspace = setmetatable({
			GetAttribute = function(_, key)
				return attributes[key]
			end,
			FindFirstChild = function(_, name)
				return if name == "ForgeRoleWorld" then roleWorld else nil
			end,
		}, { __index = stage }),
		Instance = { new = new },
		Enum = roblox.Enum,
		Color3 = roblox.Color3,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		os = { clock = clock or os.clock },
		task = { wait = opts.wait or function() end },
		require = function(path: string): any
			if string.find(path, "Waypoint$") then
				-- The real marker module on the same fake Instance tree.
				local wenv = table.clone(env)
				wenv.require = function()
					return HudShell
				end
				return luau.load(fs.readFile("games/robango-island/src/shared/Waypoint.luau"), { environment = wenv })()
			elseif string.find(path, "Rng$") then
				return require("../../core/domain/random/Rng")
			elseif string.find(path, "Topology$") then
				return require("../../core/domain/island/Topology")
			elseif string.find(path, "Party$") then
				return Party
			elseif string.find(path, "HudShell$") then
				-- HudShell.guiClear as shipped: TopbarInset.Max.Y through HudShell.topClear.
				return {
					guiClear = function(gui: any): number
						return HudShell.topClear(services.GuiService.TopbarInset.Max.Y, gui.AbsolutePosition.Y)
					end,
				}
			end
			return {}
		end,
	}
	local Chart = luau.load(fs.readFile("games/robango-island/src/shared/SeaChart.luau"), { environment = env })()
	local copyText = text("ko-kr")
	local handle = Chart.panel({
		content = Content,
		text = copyText,
		reason = function(reason: string): string
			return reason
		end,
		biome = function(id: string): string
			return id
		end,
		send = opts.send or function()
			return { ok = false }
		end,
		walkTo = opts.walkTo,
		dock = function(entry)
			table.insert(entries, entry)
			return {
				open = function()
					entry.setOpen(true)
				end,
			}
		end,
		onSnapshot = function(callback)
			callback(snapshot, {})
			return function() end
		end,
	})
	local function find(name: string): any
		for _, item in made do
			if item.Name == name and item.Parent then
				return item
			end
		end
		return nil
	end
	local function box(item: any): any
		return {
			x = item.Position.X.Offset,
			y = item.Position.Y.Offset,
			width = item.Size.X.Offset,
			height = item.Size.Y.Offset,
		}
	end
	return {
		made = made,
		find = find,
		box = box,
		destroy = handle.destroy,
		gui = find("ForgeSeaChart"),
		player = player,
		entries = entries,
		stage = env.workspace,
		heartbeat = services.RunService.Heartbeat,
	}
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
	-- p134 v60: the close X sits over the HUD minimap spot, and a minimap tap opens the chart, so a
	-- second tap there just after closing reopened it. The minimap ignores taps for REOPEN_GUARD.
	["closing the chart does not reopen it from the minimap tap that lands right after"] = function()
		local t = 100
		local panel = mountPanel("harbor", { expedition = harborView(8, 0) }, function()
			return t
		end)
		local gui = assert(panel.gui, "chart gui")
		local minimap: any = nil
		for _, item in panel.made do
			minimap = if item.Name == "MinimapChart" then item else minimap
		end
		local close = assert(panel.find("Close"), "close")
		assert(minimap, "minimap opener")
		minimap.Activated:Fire()
		assert(gui.Enabled == true, "a minimap tap opens the chart")
		close.Activated:Fire()
		assert(gui.Enabled == false, "X closes it")
		t += 0.1
		minimap.Activated:Fire()
		assert(gui.Enabled == false, "the tap landing on the minimap spot right after the close does not reopen")
		t += SeaChart.REOPEN_GUARD
		minimap.Activated:Fire()
		assert(gui.Enabled == true, "a later minimap tap opens it again")
		assert(SeaChart.minimapOpens(nil, 0), "never closed: opens")
		panel.destroy()
	end,
	["chart layout: no overlap, touch >= 44 px, text >= 13 px at 800x360, 850x411 and 1920x1080"] = function()
		for _, v in { VIEWPORTS[1], VIEWPORTS[2], VIEWPORTS[3], SQUEEZED } do
			local width, height, top = v[1], v[2], v[3]
			local tag = width .. "x" .. height .. "+" .. top
			local layout = SeaChart.layout(width, height, top)
			local cleared = layout.header.y
			assert(v == SQUEEZED or cleared == top, tag .. " keeps the top clearance: " .. cleared)
			local screen = { x = 0, y = cleared, width = width, height = height - cleared }
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
				local counted = harborView(60, 5)
				counted.role = "town"
				counted.routes = Party.routes(Content, counted.facts, 1, SeaChart.TTL)
				local cards = SeaChart.islands(Content, harborView(60, 5))
				for _, card in SeaChart.islands(Content, counted) do
					table.insert(cards, card)
				end
				for _, card in cards do
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
	["chart panel on the v40 phone: labels clear of other isles, no glyph-outline blob, rift badges"] = function()
		local facts = { level = 1, developmentRank = 1, instabilityAccess = 1 }
		local snapshot =
			{ expedition = { now = 1, facts = facts, routes = Party.routes(Content, facts, 1, SeaChart.TTL) } }
		local panel = mountPanel("onboarding", snapshot)
		local markers: { [string]: any } = {}
		for _, island in SeaChart.ISLANDS do
			markers[island.id] = panel.box(assert(panel.find("Isle-" .. island.id), island.id .. " marker"))
		end
		for _, island in SeaChart.ISLANDS do
			for _, kind in { "Name-", "Chip-" } do
				local label = panel.box(assert(panel.find(kind .. island.id), kind .. island.id))
				for other, marker in markers do
					assert(
						other == island.id or not overlaps(label, marker),
						kind .. island.id .. " label runs over the " .. other .. " isle"
					)
				end
				for _, peer in SeaChart.ISLANDS do
					if peer.id ~= island.id then
						for _, peerKind in { "Name-", "Chip-" } do
							local peerLabel = panel.box(panel.find(peerKind .. peer.id))
							assert(
								not overlaps(label, peerLabel),
								kind .. island.id .. " overlaps " .. peerKind .. peer.id
							)
						end
					end
				end
			end
		end
		-- The black blob under frontier50 was the compass "N": a UIStroke on a TextLabel outlines the
		-- glyph (Contextual) unless it is Border mode. No stroke on any label may outline its text.
		for _, item in panel.made do
			if item.ClassName == "UIStroke" and item.Parent and item.Parent.ClassName == "TextLabel" then
				assert(
					item.ApplyStrokeMode == roblox.Enum.ApplyStrokeMode.Border,
					"glyph-outline stroke on " .. item.Parent.Name
				)
			end
		end
		local compass = panel.box(assert(panel.find("Compass"), "compass"))
		assert(compass.width >= 44 and compass.height >= 44, "compass is a ring, not a blob")
		-- Rift badges on every chart island that has a rift (harbor and the drift isles).
		for _, island in SeaChart.ISLANDS do
			local marker = panel.find("Isle-" .. island.id)
			local rift = marker:FindFirstChild("Rift")
			assert((rift ~= nil and rift.Visible == true) == (island.rift == true), island.id .. " rift badge")
		end
		assert(panel.find("DriftTimer").Visible ~= true, "no drift countdown pill off a drift isle (onboarding)")
		panel.destroy()
	end,
	["drift countdown: every drift isle counts down on the chart; the HUD pill shows on a drift isle"] = function()
		local facts = { level = 60, developmentRank = 10, instabilityAccess = 5 }
		local routes = Party.routes(Content, facts, 1, SeaChart.TTL)
		local ko = text("ko-kr")
		for _, role in { "town", "home", "onboarding", "harbor" } do
			for _, card in SeaChart.islands(Content, { role = role, level = 60, facts = facts, routes = routes }) do
				local chip = SeaChart.copy(card, ko, 1).chip
				assert(
					(string.find(chip, "%d+:%d%d$") ~= nil) == (card.drift == true),
					role .. " " .. card.id .. " countdown: " .. chip
				)
			end
		end
		local trip = openTrip(3600)
		local snapshot = { expedition = { now = 3600, facts = facts, routes = routes }, archipelago = trip }
		local panel = mountPanel("archipelago", snapshot)
		local timer = panel.find("DriftTimer")
		assert(timer.Visible == true, "drift-isle HUD countdown pill visible")
		-- The panel clock runs on from the snapshot (os.clock), so allow the second it may have ticked.
		local left = trip.expiresAt - 3600
		assert(
			timer.Text == ko("hud_timer", SeaChart.clock(left))
				or timer.Text == ko("hud_timer", SeaChart.clock(left - 1)),
			"pill text " .. tostring(timer.Text)
		)
		panel.destroy()
		assert(SeaChart.ISLANDS[2].id == "harbor" and SeaChart.ISLANDS[2].rift, "harbor rift on the chart")
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
			if card.role and card.role ~= "home" and card.role ~= "harbor" and card.role ~= "town" then
				assert(card.band and card.band.min >= 10, card.id .. " band")
			end
		end
		local count = 0
		for _ in biomes do
			count += 1
		end
		assert(#cards >= 14 and drift == 5, "14 chart islands (town included), 5 drift isles")
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
	["R20 rift: a swirling ember crater (spinning transparent layers, embers, warm light), not a white slab"] = function()
		-- D2c Studio: the drift-camp rift read as a flat glowing pink-white slab (R20 2/5). Durango's
		-- warp hole is a red-orange glowing crack over a dark crater (R20-2/R20-3).
		local rowNames = { "town.rift-ring", "town.rift-ring__glow", "town.rift-ring__halo" }
		for _, id in { "rw.a1.s1", "rw.harbor" } do
			local engine = Engine.new()
			-- With the rift row loaded (the live case) and without it (headless fallback).
			for _, loaded in { true, false } do
				if loaded then
					local model = engine.newInstance("Model")
					model.Name = "town.rift-ring"
					for _, name in rowNames do
						local mesh = engine.newInstance("MeshPart")
						mesh.Name, mesh.Size = name, roblox.Vector3.new(4, 2, 4)
						mesh.Material, mesh.Color = roblox.Enum.Material.Neon, roblox.Color3.fromRGB(150, 236, 220)
						local light = engine.newInstance("PointLight")
						light.Parent = mesh
						mesh.Parent = model
					end
					engine.meshes.setTemplates({ ["town.rift-ring"] = model })
				else
					engine.meshes.setTemplates({})
				end
				local world = engine.role.build(Content, Source, Policy, function()
					return 0
				end, id, 1776)
				local root = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld")
				local prefix = if id == "rw.harbor" then "HarborRift" else "DriftCamp.rift"
				local host = root:FindFirstChild(prefix .. ".ForgeRiftFx")
				assert(host, id .. " rift effect host (loaded=" .. tostring(loaded) .. ")")
				assert(host.Transparency == 1 and host.CanCollide == false, "the host is invisible")
				assert(host:GetAttribute("ForgeEffectRank") == 1, "the phone profile keeps the rift effects")
				local spinning, embers, total = 0, 0, 0
				for _, item in host:GetDescendants() do
					if item.ClassName == "ParticleEmitter" then
						total += item.Rate

						assert(item.Texture ~= "", item.Name .. " uses an uploaded fx texture")
						if item.Orientation == roblox.Enum.ParticleOrientation.VelocityPerpendicular then
							assert(item.RotSpeed.Max ~= 0, item.Name .. " spins")
							local alpha = item.Transparency.Keypoints[2].Value
							assert(alpha > 0 and alpha < 1, item.Name .. " is partly transparent")
							spinning += 1
						else
							embers += 1
						end
					end
				end
				assert(spinning >= 3, "layered swirl: " .. spinning .. " spinning layers")
				-- Night2 (R20-3): a 14-20 stud glowing ring around a dark centre, not a narrow slit.
				local span = math.max(host.Size.X, host.Size.Z)
				assert(span >= 14 and span <= 20, "rift ring span " .. span)
				local ring = host:FindFirstChild(RiftFx.RING.name)
				assert(
					ring and ring.Shape == roblox.Enum.ParticleEmitterShape.Disc and ring.ShapePartial >= 0.5,
					"glowing ring emits from the outer annulus"
				)
				assert(ring.LightEmission == 1, "the ring glows")
				local core: any = nil
				for _, item in host:GetDescendants() do
					if item.ClassName == "ParticleEmitter" and item.Name == "DarkCore" then
						core = item
					end
				end
				assert(core, "dark centre emitter")
				assert(core.LightEmission == 0, "dark centre does not glow")
				assert(core.Color.Keypoints[1].Value.R < 0.2, "dark centre colour")
				-- Studio threw "NumberRange: invalid range" on a reversed RotSpeed (counter-spin layer):
				-- lune swaps min/max silently, so the ranges RiftFx builds are pinned in order here.
				for _, layer in RiftFx.LAYERS do
					local low, high = RiftFx.spinRange(layer.spin)
					assert(low <= high, layer.name .. " spin range ordered")
				end
				assert(embers >= 1, "rising embers")
				assert(total <= 40, "particle budget per rift: " .. total)
				local light = host:FindFirstChildOfClass("PointLight")
				assert(
					light and light.Color.R > light.Color.B + 0.5 and light.Shadows == false,
					"one warm unshadowed glow"
				)
				assert(host:GetAttribute("ForgeTorch") == true, "the rift light follows the day-night fire cycle")
				local set = root:FindFirstChild(prefix .. ".set")
				if loaded and id == "rw.a1.s1" then
					local glow = assert(set and set:FindFirstChild("town.rift-ring__glow", true), "row glow")
					assert(glow.Color.R > glow.Color.B + 0.5, "cleft glow is ember red, not teal-white")
					assert(glow.Transparency > 0, "cleft glow is see-through, not a solid slab")
					assert(glow:FindFirstChildOfClass("PointLight") == nil, "one light per rift (row light dropped)")
				elseif not loaded then
					local fissure = assert(root:FindFirstChild(prefix .. ".fissure"), "fallback fissure")
					assert(fissure.Color.R > fissure.Color.B + 0.5, "fallback fissure is ember red, not lilac")
				end
				world.destroy()
			end
		end
	end,
	["route p134: a Lv 2-8 profile after the start guides sails to a1 and the chart names each unlock"] = function()
		-- Staging v62: a Lv 8 account saw every route island locked; a1 needed level 30 and grade 2.
		-- Robango redesign: a1 opens at level 2 with the island grade the start guides give.
		local level, rank = Party.gates(Content, 1)
		assert(level <= 5, "a1 entry level reachable in the first session, got " .. level)
		local points, xp = 0, 0
		for _, guide in Content.guides do
			if (guide.gates.developmentRank or 0) == 0 and (guide.gates.characterLevel or 1) <= 1 then
				points += guide.rewards.development or 0
				xp += guide.rewards.xp or 0
			end
		end
		assert(points // 100 >= rank, "start guides give the a1 grade: " .. points .. " points for rank " .. rank)
		local tree, reached = Content.progressionPolicy.tree, 1
		while xp >= SkillTree.characterRequired(tree, reached) do
			xp -= SkillTree.characterRequired(tree, reached)
			reached += 1
		end
		assert(reached >= level, "start guide xp reaches the a1 level: L" .. reached .. " < L" .. level)
		local en = text("en-us")
		for at = 2, 8 do
			local facts = { level = at, developmentRank = points // 100, instabilityAccess = 1 }
			local ok, reason = Party.routeGate(Content, 1, facts)
			assert(ok, "a1 at level " .. at .. ": " .. tostring(reason))
			local cards = {}
			for _, card in SeaChart.islands(Content, { role = "harbor", level = at, facts = facts }) do
				cards[card.id] = card
			end
			assert(not cards.drift1.locked, "drift1 (a1) open on the chart at level " .. at)
			assert(cards.drift2.locked and cards.drift2.needLevel == 35, "drift2 names its level")
			assert(SeaChart.copy(cards.drift2, en).status == "Opens at Lv 35", SeaChart.copy(cards.drift2, en).status)
			assert(cards.explore10.needLevel == 10, "explore10 names its level")
		end
		local ko = SeaChart.copy({ id = "drift2", locked = true, needLevel = 35, band = { min = 35 } }, text("ko-kr"))
		assert(ko.status == "레벨 35에 열려요", ko.status)
		local graded = { level = 8, developmentRank = rank - 1, instabilityAccess = 1 }
		local cards = SeaChart.islands(Content, { role = "harbor", level = 8, facts = graded })
		for _, card in cards do
			if card.id == "drift1" then
				assert(card.locked and card.needRank == rank, "a1 below its grade names the grade")
				assert(SeaChart.copy(card, en).status == en("needs_grade", rank), SeaChart.copy(card, en).status)
			end
		end
		-- Away from the harbor a drift isle is refused by the role edge, not by level.
		local home = SeaChart.islands(Content, { role = "home", level = 8, facts = { level = 8, developmentRank = 2 } })
		for _, card in home do
			if card.id == "drift1" then
				assert(card.locked and card.reason == "transition_not_allowed" and card.needLevel == nil, "home edge")
			end
		end
	end,
	["fxB: an isle only the harbor reaches says 'sail from the harbor' and its primary sails there"] = function()
		-- journey6h @23m: from rw.home the chart sail to explore10 was refused with a nil reason and the
		-- tile offered a Set sail that went nowhere. Now the card names the harbor and sails to it.
		local facts = { level = 20, developmentRank = 2, instabilityAccess = 1 }
		for _, from in { "home", "explore10", "explore20" } do
			for _, card in SeaChart.islands(Content, { role = from, level = 20, facts = facts }) do
				if card.locked then
					assert(card.reason ~= nil, from .. " -> " .. card.id .. ": a locked card has a reason")
				end
				local wild = card.role == "explore10" or card.role == "explore20" or card.id == "drift1"
				if wild and not card.here then
					assert(card.viaHarbor, from .. " -> " .. card.id .. " routes via the harbor")
					local en = text("en-us")
					assert(SeaChart.copy(card, en, 0).status == en("via_harbor"), SeaChart.copy(card, en, 0).status)
				end
			end
		end
		-- Above its level an isle still names the level, never 'sail from the harbor'.
		for _, card in SeaChart.islands(Content, { role = "home", level = 1, facts = { level = 1 } }) do
			if card.role == "explore20" then
				assert(card.needLevel == 20 and not card.viaHarbor, "explore20 at level 1 names its level")
			end
		end
		local sent = {}
		local panel = mountPanel("home", { expedition = { now = 1, facts = facts } }, nil, {
			send = function(action, args)
				table.insert(sent, action .. ":" .. table.concat(args, ","))
				return { ok = true, reason = "travelling" }
			end,
		})
		panel.gui.Enabled = true
		panel.find("Isle-explore10").Activated:Fire()
		local sail = assert(panel.find("Sail"), "card primary")
		assert(sail.Text == text("ko-kr")("sail_harbor") and sail.Active, "primary sails to the harbor: " .. sail.Text)
		sail.Activated:Fire()
		assert(sent[1] == "survival-coop:mission-action:sail,harbor", "sails to the harbor: " .. tostring(sent[1]))
		panel.destroy()
	end,
	["route p134: the harbor (selling, departures) is open right after the opening"] = function()
		-- Staging v63: a Lv 8 solo account on onboarding saw the harbor padlocked ('Depart from the
		-- harbor'); harbor buyback only works on rw.harbor, so nothing could be sold.
		for _, from in { "onboarding", "home", "town" } do
			local ok, reason = SeaChart.sail("harbor", from, 1, "dock")
			assert(ok, from .. " -> harbor at level 1: " .. tostring(reason))
			for _, card in SeaChart.islands(Content, { role = from, level = 1, facts = { level = 1 } }) do
				if card.id == "harbor" then
					assert(not card.locked, from .. ": harbor card open")
				end
			end
		end
		-- Onboarding still cannot sail past the harbor directly.
		assert(select(2, SeaChart.sail("explore10", "onboarding", 60, "dock")) == "transition_not_allowed", "edge")
	end,
	["chart2: the shared town is a chart destination from onboarding, home and the harbor"] = function()
		-- v66/v67: the chart had no town tile, so Saltmeadow (C5a, 28 plots) was unreachable from it.
		local tile: any = nil
		for _, island in SeaChart.ISLANDS do
			tile = if island.role == "town" then island else tile
		end
		assert(tile, "a town tile on the chart")
		for _, from in { "onboarding", "home", "harbor" } do
			local ok, reason = SeaChart.sail("town", from, 1, "dock")
			assert(ok, from .. " -> town at level 1: " .. tostring(reason))
			local card: any = nil
			for _, c in SeaChart.islands(Content, { role = from, level = 1, facts = { level = 1 } }) do
				card = if c.id == tile.id then c else card
			end
			assert(card and not card.locked and card.role == "town", from .. ": town card open")
		end
		local here: any = nil
		for _, c in SeaChart.islands(Content, { role = "town", level = 1, facts = { level = 1 } }) do
			here = if c.id == tile.id then c else here
		end
		assert(here.here and not here.locked, "in town the town tile is 'you are here'")
		assert(select(2, SeaChart.sail("town", "town", 1, "dock")) == "transition_not_allowed", "not to itself")
		for _, locale in { "en-us", "ko-kr" } do
			assert(Fixture.packText(locale, "cli.chart.isle.town"), "town chart name " .. locale)
		end
	end,
	["chart2: a fresh account reaches the a1 island grade within its first two start guides"] = function()
		-- v66: a Lv 9 account after hours of play was at grade 1 (100/200) and a1 needed grade 2.
		-- Grade = points // 100; the 50-point start guides are gather fiber x3, craft an axe, deliver
		-- a contract and donate to the camp. Any two of them must open a1 (first hour target).
		local _, rank = Party.gates(Content, 1)
		local paying = {}
		for _, guide in Content.guides do
			if (guide.gates.developmentRank or 0) == 0 and (guide.gates.characterLevel or 1) <= 1 then
				if (guide.rewards.development or 0) > 0 then
					table.insert(paying, guide.rewards.development)
				end
			end
		end
		table.sort(paying)
		assert(#paying >= 2, "two development-paying start guides")
		local two = paying[1] + paying[2]
		assert(two // 100 >= rank, "two start guides give " .. two .. " points; a1 needs grade " .. rank)
		-- Every stage of route 1 and every route 1 mission opens at that grade too.
		for _, stage in Content.stages do
			if string.match(stage.layout, "^rw%.a1%.") then
				assert((stage.gates.developmentRank or 0) <= rank, stage.id .. " grade")
			end
		end
		-- Below the grade the locked a1 tile says what to do in both languages (the guides).
		local facts = { level = 9, developmentRank = rank - 1, instabilityAccess = 1 }
		for _, card in SeaChart.islands(Content, { role = "harbor", level = 9, facts = facts }) do
			if card.id == "drift1" then
				assert(card.locked and card.needRank == rank, "a1 names its grade")
				for _, locale in { "en-us", "ko-kr" } do
					local status = SeaChart.copy(card, text(locale)).status
					assert(status == text(locale)("needs_grade", rank), locale .. " " .. status)
				end
			end
		end
	end,
	["chart2: the selected-island sheet never covers the selected tile"] = function()
		-- v65: the harbor card text was drawn over the first drift isle's name and chip.
		for _, v in { VIEWPORTS[1], VIEWPORTS[2], VIEWPORTS[3], SQUEEZED } do
			local layout = SeaChart.layout(v[1], v[2], v[3])
			for _, island in SeaChart.ISLANDS do
				local placed = SeaChart.sheetFor(layout, island.id)
				local tag = v[1] .. "x" .. v[2] .. " " .. island.id
				assert(not overlaps(placed.frame, layout.tiles[island.id].tile), tag .. " sheet covers the selection")
				assert(not overlaps(placed.frame, layout.header), tag .. " sheet under the header")
				assert(placed.frame.y + placed.frame.height <= v[2], tag .. " sheet on screen")
				for _, key in { "name", "info", "status", "sail" } do
					assert(inside(placed[key], placed.frame), tag .. " " .. key .. " inside the sheet")
				end
			end
		end
		-- The panel draws the sheet above the tiles it covers.
		local facts = { level = 9, developmentRank = 1, instabilityAccess = 1 }
		local panel = mountPanel("harbor", { expedition = { now = 1, facts = facts } })
		local sheet = assert(panel.find("IslandSheet"), "sheet")
		assert((sheet.ZIndex or 1) > (panel.find("Isle-drift1").ZIndex or 1), "sheet above isle tiles")
		assert((sheet.ZIndex or 1) > (panel.find("Name-drift1").ZIndex or 1), "sheet above isle names")
		panel.find("Isle-harbor").Activated:Fire()
		local frame = panel.box(sheet)
		assert(not overlaps(frame, panel.box(panel.find("Isle-harbor"))), "harbor sheet clear of the harbor tile")
		panel.destroy()
	end,
	["dock3: away from every dock the chart card shows 'show the dock', walks there and marks it"] = function()
		-- p134 v68: the chart refused '부두나 균열 앞에서 출항하세요' everywhere but within ~8 studs of the
		-- onboarding town dock, and nothing marked the dock: the tester looked for it for 14 minutes.
		local dock = roblox.Vector3.new(23, 2, -72)
		local spots = "dock:23.0,2.0,-72.0;dock:-1.0,2.0,173.0;rift:400.0,2.0,400.0"
		local walks: { any } = {}
		local facts = { level = 3, developmentRank = 0, instabilityAccess = 0 }
		local panel = mountPanel("onboarding", { expedition = { now = 1, facts = facts } }, nil, {
			at = roblox.Vector3.new(-44, 2, 0),
			spots = spots,
			walkTo = function(goal, arrive)
				table.insert(walks, { goal = goal, arrive = arrive })
			end,
		})
		local chart = panel.gui
		panel.find("Isle-town").Activated:Fire()
		chart.Enabled = true
		panel.find("Isle-town").Activated:Fire()
		local sail = assert(panel.find("Sail"), "card primary")
		local ko = text("ko-kr")
		assert(sail.Text == ko("show_dock"), "away from a dock the primary reads 'show the dock': " .. sail.Text)
		assert(sail.Active, "the primary is pressable")
		assert(panel.find("SheetStatus").Text == "sail_unreachable", "the card says why")
		sail.Activated:Fire()
		assert(#walks == 1, "one walk")
		assert(walks[1].goal.X == 23 and walks[1].goal.Z == -72, "walks to the nearest dock")
		assert(walks[1].arrive <= SeaChart.SAIL_REACH, "stops inside the sail reach")
		assert(not chart.Enabled, "the chart closes for the walk")
		assert(panel.player:GetAttribute("ForgeWaypointOverride") == dock, "the dock owns the waypoint")
		panel.heartbeat:Fire(1 / 60)
		local beam = assert(panel.find("DockBeam"), "beam at the dock")
		assert(beam.Parent == panel.stage and beam.CFrame.Position.X == 23, "beam stands on the dock")
		local arrow = assert(panel.find("ForgeDockWaypoint"), "dock arrow gui")
		assert(arrow.Enabled, "the dock arrow shows once the chart is closed")
		assert(arrow.DisplayOrder < chart.DisplayOrder, "the dock arrow sits under the chart")
		-- Arriving clears the mark and hands the waypoint back to the opening.
		panel.player.Character:FindFirstChild("HumanoidRootPart").Position = roblox.Vector3.new(21, 2, -70)
		panel.heartbeat:Fire(1 / 60)
		assert(panel.player:GetAttribute("ForgeWaypointOverride") == nil, "arrived: override cleared")
		assert(beam.Parent == nil, "arrived: beam hidden")
		-- At the dock (inside SAIL_REACH, beyond the old 8-stud prompt) the primary sails.
		chart.Enabled = true
		panel.find("Isle-town").Activated:Fire()
		assert(sail.Text == ko("sail"), "at the dock the primary sails: " .. sail.Text)
		panel.destroy()
		-- Opening the chart away from a dock marks the dock even before any press.
		local marked = mountPanel("onboarding", { expedition = { now = 1, facts = facts } }, nil, {
			at = roblox.Vector3.new(-44, 2, 0),
			spots = spots,
		})
		marked.entries[1].setOpen(true) -- the menu tile / minimap open (view mode)
		assert(marked.gui.Enabled, "chart opened")
		assert(marked.player:GetAttribute("ForgeWaypointOverride") == nil, "an unpressed mark does not take the guide")
		marked.heartbeat:Fire(1 / 60)
		local mark = assert(marked.find("DockBeam"), "opening the chart away from a dock marks it")
		assert(mark.Parent == marked.stage and mark.CFrame.Position.X == 23, "beam on the nearest dock")
		assert(not marked.find("ForgeDockWaypoint").Enabled, "no arrow button over the open chart")
		marked.destroy()
		for _, locale in { "en-us", "ko-kr" } do
			assert(Fixture.packText(locale, "cli.chart.show_dock"), locale .. " show_dock")
			assert(string.format(text(locale)("dock_meters"), 12):find("12"), locale .. " dock_meters")
		end
	end,
	["dock3: the server sails within SAIL_REACH studs of a dock and publishes every sail spot"] = function()
		local engine = Engine.new()
		local world = engine.role.build(Content, Source, Policy, function()
			return 0
		end, "rw.onboarding", 1776)
		world.bind({} :: any)
		local root = engine.game:GetService("Workspace"):FindFirstChild("ForgeRoleWorld")
		local spots = SeaChart.spots(root:GetAttribute("ForgeSailSpots"))
		local town: any = nil
		for _, item in root:GetChildren() do
			if item.Name == "town-dock" then
				town = item
			end
		end
		assert(town, "onboarding town dock")
		local listed = false
		for _, spot in spots do
			listed = listed or (spot.kind == "dock" and spot.X == math.floor(town.Position.X * 10 + 0.5) / 10)
		end
		assert(listed and #spots >= 2, "the town dock and the home dock are published: " .. #spots)
		-- nearPart (12 studs + a clear ray) fails on the pier beside the dock; the flat reach still sails.
		world.nearPart = function()
			return false
		end
		local p = town.Position
		engine.move("1", { x = p.X + 15, y = p.Y, z = p.Z })
		assert(world.sailPoint("1") == "dock", "15 studs from the dock sails")
		engine.move("1", { x = p.X + SeaChart.SAIL_REACH + 30, y = p.Y, z = p.Z + 40 })
		assert(world.sailPoint("1") == nil, "far from every dock refuses")
		world.destroy()
	end,
	["v73 #4: a sail the session answers COMMAND_PENDING is re-sent by itself, not shown as final"] = function()
		local facts = { level = 3, developmentRank = 0 }
		local sent, waits = 0, 0
		local panel = mountPanel("onboarding", { expedition = { now = 1, facts = facts } }, nil, {
			spots = "dock:0,0,0",
			at = roblox.Vector3.new(1, 0, 1),
			wait = function()
				waits += 1
			end,
			send = function(_action, _args)
				sent += 1
				-- The actor is held for the first three answers (a recovery sweep), then the sail goes.
				return if sent <= 3
					then { ok = false, reason = "COMMAND_PENDING" }
					else { ok = true, reason = "travelling" }
			end,
		})
		panel.gui.Enabled = true
		panel.find("Isle-harbor").Activated:Fire()
		local sail = assert(panel.find("Sail"), "card primary")
		sail.Activated:Fire()
		assert(sent == 4 and waits == 3, "re-sent until it went: " .. sent .. " sends, " .. waits .. " waits")
		local status = assert(panel.find("SheetStatus"), "status line")
		assert(not string.find(status.Text, "COMMAND_PENDING", 1, true), "no pending refusal: " .. status.Text)
		panel.destroy()
	end,
}
