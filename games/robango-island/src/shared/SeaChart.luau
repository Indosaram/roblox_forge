--!strict
-- C7 sea chart and drift isles (plan G20, G25; ui-spec section 6.4). Our own style: a parchment
-- chart with ink islands, level bands, slate lock hatching and lilac drift-isle halos.
-- The pure part (island cards, voyage gate, layout, drift-isle seeds) runs under Lune; the view
-- builds Instances only when an ExtensionPanels context calls M.panel.
-- Names: "rift" is our warp hole, "drift isles" are the timed archipelago islands.
local M = {}
local Rng = require("../../../../core/domain/random/Rng")
local Topology = require("../../../../core/domain/island/Topology")
local Party = require("../../../../core/domain/island/Party")

M.TTL = 1800
M.HISTORY = 8
M.GRID = { columns = 5, rows = 3 }
-- Chart slots: { column, row } on the 5x3 sea grid plus a fixed nudge inside the cell (0-1).
-- Low bands sit near home on the left; higher bands and the drift isles sail further out.
-- `rift`: the island has a rift (RoleWorld: HarborRift on rw.harbor, the drift camp rift on every
-- archipelago stage); sea-chart.spec checks the flag against the built worlds.
local islandRows: { any } = {
	{ id = "home", role = "home", cell = { 0, 1 }, nudge = { 0.35, 0.3 } },
	{ id = "harbor", role = "harbor", cell = { 1, 1 }, nudge = { 0.6, 0.55 }, rift = true },
	-- Saltmeadow, the shared plot town (C5a): onboarding, home and the harbor sail there (Topology).
	{ id = "town", role = "town", cell = { 0, 0 }, nudge = { 0.4, 0.6 } },
	{ id = "explore10", role = "explore10", cell = { 1, 0 }, nudge = { 0.2, 0.75 } },
	{ id = "explore20", role = "explore20", cell = { 2, 0 }, nudge = { 0.7, 0.35 } },
	{ id = "frontier30", role = "frontier30", cell = { 3, 0 }, nudge = { 0.3, 0.8 } },
	{ id = "frontier40", role = "frontier40", cell = { 4, 0 }, nudge = { 0.65, 0.2 } },
	{ id = "frontier60", role = "frontier60", cell = { 3, 1 }, nudge = { 0.8, 0.45 } },
	{ id = "frontier50", role = "frontier50", cell = { 4, 1 }, nudge = { 0.25, 0.7 } },
	{ id = "drift1", route = 1, cell = { 0, 2 }, nudge = { 0.6, 0.4 }, rift = true },
	{ id = "drift2", route = 2, cell = { 1, 2 }, nudge = { 0.25, 0.85 }, rift = true },
	{ id = "drift3", route = 3, cell = { 2, 2 }, nudge = { 0.75, 0.6 }, rift = true },
	{ id = "drift4", route = 4, cell = { 3, 2 }, nudge = { 0.35, 0.3 }, rift = true },
	{ id = "drift5", route = 5, cell = { 2, 1 }, nudge = { 0.45, 0.5 }, rift = true },
}
M.ISLANDS = table.freeze(islandRows)
M.COMPASS_CELL = { 4, 2 }
local BANDS = { "explore10", "explore20", "frontier30", "frontier40", "frontier50", "frontier60" }

local function layoutOf(content: any, id: string): any?
	for _, layout in content.layouts do
		if layout.id == id then
			return layout
		end
	end
	return nil
end

local function roleMinimum(content: any, role: string): number
	for _, region in content.supportRegions do
		if region.role == role then
			return region.gates.characterLevel or 1
		end
	end
	return 1
end

--- Level band of a chart island: { min, max? } (max nil = open-ended), nil for home and harbor.
function M.band(content: any, island: any): any?
	if island.route then
		local low = Party.gates(content, island.route)
		local high = if island.route < Party.ROUTES then Party.gates(content, island.route + 1) - 1 else nil
		return { min = low, max = if high and high >= low then high else nil }
	end
	local index = table.find(BANDS, island.role)
	if not index then
		return nil
	end
	local low = roleMinimum(content, island.role)
	local nextRole = BANDS[index + 1]
	return { min = low, max = if nextRole then roleMinimum(content, nextRole) - 1 else nil }
end

--- World role of a layout id ("rw.harbor" -> "harbor", "rw.a3.s2" -> "archipelago").
function M.roleOf(layoutId: string): string
	if string.match(layoutId, "^rw%.a%d+%.s%d+$") then
		return "archipelago"
	end
	return (string.gsub(layoutId, "^rw%.", ""))
end

-- From a drift isle the rift leads home only (the route ends there); every other pair follows
-- the live Topology edges.
local function roleGate(from: string, to: string, level: number): (boolean, string?)
	if from == "archipelago" and to ~= "home" then
		return false, "transition_not_allowed"
	end
	return Topology.validateRoleTransition(from, to, level)
end

--- Island cards for the chart. view = { role, level, routes (expedition route cards), trip, now }.
--- Locks reuse the live gates: Topology.validateRoleTransition for role islands and the
--- server's Party.routeGate card (ok/reason) for drift isles, which sail only from the harbor.
function M.islands(content: any, view: any): { any }
	local cards = {}
	local level = view.level or 1
	for _, island in M.ISLANDS do
		local card: any = { id = island.id, cell = island.cell, nudge = island.nudge, band = M.band(content, island) }
		card.rift = island.rift == true
		if island.route then
			local layout = layoutOf(content, "rw.a" .. island.route .. ".s1")
			card.route, card.drift = island.route, true
			card.biomes = if layout then layout.biomes else {}
			local route = if view.routes then view.routes[island.route] else nil
			local trip = view.trip
			if trip and trip.status == "active" and trip.index == island.route then
				card.here, card.expiresAt = view.role == "archipelago", trip.expiresAt
			end
			-- The route window is the same rotation everywhere, so every drift isle counts down on
			-- the chart, not only at the harbor (v40: no countdown in town or onboarding).
			card.expiresAt = card.expiresAt or (if route then route.expiresAt else nil)
			if view.role ~= "harbor" then
				card.locked, card.reason = not card.here, if card.here then nil else "transition_not_allowed"
				if not card.here and view.role ~= "archipelago" then
					local gate = route
						or { ok = Party.routeGate(content, island.route, view.facts or { level = level }) }
					card.viaHarbor = gate.ok == true or gate.reason == "expiry_imminent"
				end
			elseif route then
				card.locked, card.reason = not route.ok, route.reason
			else
				local ok, reason = Party.routeGate(content, island.route, view.facts or { level = level })
				card.locked, card.reason = not ok, reason
			end
		else
			local layout = layoutOf(content, "rw." .. island.role)
			card.role, card.home = island.role, island.role == "home"
			card.biomes = if layout then layout.biomes else {}
			if island.role == view.role then
				card.here = true
			else
				local ok, reason = roleGate(view.role or "harbor", island.role, level)
				card.locked, card.reason = not ok, reason
				-- Not reachable from this port but from the harbor: the card sails to the harbor first.
				if reason == "transition_not_allowed" and view.role ~= "archipelago" and view.role ~= "harbor" then
					card.viaHarbor = roleGate(view.role or "harbor", "harbor", level)
						and roleGate("harbor", island.role, level)
				end
			end
		end
		card.locked = card.locked == true
		-- What unlocks it (route p134): the level the player still needs, or the island grade a
		-- drift isle needs, so a locked card names its unlock instead of only a refusal.
		if card.locked and card.band and level < card.band.min then
			card.needLevel = card.band.min
		elseif card.locked and island.route and card.reason == "development_gate" then
			card.needRank = select(2, Party.gates(content, island.route))
		end
		table.insert(cards, card)
	end
	return cards
end

--- Server voyage gate for a role island picked on the chart. `from` is the sail point the actor
--- stands at ("dock" or "rift", nil when none is in reach); the level gate is the live
--- Topology rule, so a locked island is refused here and again by the teleport router.
-- Sail reach in studs (flat) around a dock or rift (RoleWorld.SAIL_REACH, the server's rule). Further
-- out the chart card shows 'show the dock' (walk + waypoint to the nearest sail spot) instead of
-- Set sail (p134 v68: the tester spent 14 min finding the onboarding town dock).
M.SAIL_REACH = 20
M.DOCK_ARRIVE = 6 -- the 'show the dock' walk stops this close to the sail spot
M.DOCK_MARK_SECONDS = 60 -- an unpressed dock mark (chart opened away from it) stays this long
-- p134 v73: the first Set sail after the dock walk answered COMMAND_PENDING (the session held the
-- actor for a moment: a recovery sweep or lease renew on a slow DataStore) and the card showed
-- 'still finishing your last action' as final. The same request (same id, replay-safe) is re-sent
-- this many times, this far apart, before that line shows.
M.SAIL_RETRIES, M.SAIL_RETRY_SECONDS = 10, 1

--- Whether the chart offers 'show the dock' for a player at `root` with `spot` the nearest sail
--- spot (nil: none known, never offered).
function M.awayFromDock(root: any?, spot: any?): boolean
	if root == nil or spot == nil then
		return false
	end
	return math.sqrt((root.X - spot.X) ^ 2 + (root.Z - spot.Z) ^ 2) > M.SAIL_REACH
end

--- Sail spots RoleWorld publishes on ForgeRoleWorld (attribute ForgeSailSpots, `kind:x,y,z;...`):
--- every dock and rift a chart voyage leaves from. Rows { kind, X, Y, Z }.
function M.spots(encoded: any): { any }
	local rows = {}
	if type(encoded) ~= "string" then
		return rows
	end
	for kind, x, y, z in string.gmatch(encoded, "(%a+):([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)") do
		local px, py, pz = tonumber(x), tonumber(y), tonumber(z)
		if px and py and pz then
			table.insert(rows, { kind = kind, X = px, Y = py, Z = pz })
		end
	end
	return rows
end

--- The sail spot nearest `at` (flat distance), or nil when none is published.
function M.nearestSpot(encoded: any, at: any): any?
	local best, bestDistance = nil, math.huge
	for _, spot in M.spots(encoded) do
		local d = (spot.X - at.X) ^ 2 + (spot.Z - at.Z) ^ 2
		if d < bestDistance then
			best, bestDistance = spot, d
		end
	end
	return best
end

function M.sail(destination: any, role: string, level: number, from: string?): (boolean, string?)
	if from ~= "dock" and from ~= "rift" then
		return false, "sail_unreachable"
	end
	local known = false
	for _, island in M.ISLANDS do
		known = known or (island.role ~= nil and island.role == destination)
	end
	if not known then
		return false, "invalid_route"
	end
	if destination == role then
		return false, "transition_not_allowed"
	end
	return roleGate(role, destination, level)
end

--- Drift-isle departure seed: a recorded seed from the explicit clock and the actor id.
function M.departureSeed(now: number, actor: string): number
	return Rng.new(math.max(0, math.floor(now))):fork("drift-departure"):fork(actor):nextU32()
end

--- Next recorded seed after `previous`; never equal to it.
function M.reseed(previous: number, generation: number): number
	local seed = Rng.new(previous):fork("drift-reset|" .. tostring(generation)):nextU32()
	return if seed == previous then (seed + 1) % 2 ^ 32 else seed
end

--- Drift-isle reset: an expired, still active isle regenerates from a new recorded seed and opens
--- a fresh window. The previous and new seeds are kept in state.driftSeeds (latest M.HISTORY).
function M.driftReset(state: any, now: number, ttl: number): (boolean, string?)
	if state.status ~= "active" then
		return false, "expedition_inactive"
	end
	if now < state.expiresAt then
		return false, "not_expired"
	end
	local generation = (state.driftGeneration or 0) + 1
	local seed = M.reseed(state.seed, generation)
	local history = table.clone(state.driftSeeds or {})
	table.insert(history, { from = state.seed, to = seed, at = now })
	while #history > M.HISTORY do
		table.remove(history, 1)
	end
	state.seed, state.driftGeneration, state.driftSeeds = seed, generation, history
	state.expiresAt = now + ttl
	return true, nil
end

--- Countdown text "m:ss" ("h:mm:ss" from an hour); never negative.
function M.clock(seconds: number): string
	local left = math.max(0, math.floor(seconds))
	local h, m, s = left // 3600, (left % 3600) // 60, left % 60
	return if h > 0 then string.format("%d:%02d:%02d", h, m, s) else string.format("%d:%02d", m, s)
end

local function rect(x: number, y: number, w: number, h: number): any
	return {
		x = math.floor(x + 0.5),
		y = math.floor(y + 0.5),
		width = math.floor(w + 0.5),
		height = math.floor(h + 0.5),
	}
end

--- Text sizes on the spec scale (pt = safeHeight / 360), never under 13 px.
function M.textSizes(safeHeight: number): any
	local function size(pt: number, cap: number): number
		return math.clamp(math.floor(pt * safeHeight / 360 + 0.5), 13, cap)
	end
	return { title = size(20, 30), heading = size(16, 24), name = size(14, 22), chip = size(13, 18) }
end

--- Full-screen chart rects in gui pixels: header (title, close), the sea grid with one tile per
--- island (marker, name, band chip), the compass, the 0.28H bottom sheet and the HUD timer pill.
--- A top clearance that leaves no room for a whole tile per grid cell is given back row by row
--- (the header slides up) so island tiles and their labels never overlap.
function M.layout(width: number, height: number, topClear: number?): any
	local top = math.max(0, math.floor(topClear or 0))
	local layout = M.layoutAt(width, height, top)
	while not layout.fits and top > 0 do
		top -= 1
		layout = M.layoutAt(width, height, top)
	end
	return layout
end

--- One layout pass at a fixed top clearance; `fits` is false when a tile is taller than its cell.
function M.layoutAt(width: number, height: number, top: number): any
	local h = height - top
	local text = M.textSizes(h)
	local pad = math.max(8, math.floor(0.03 * h + 0.5))
	local headerHeight = math.max(44, math.floor(0.12 * h + 0.5))
	local header = rect(0, top, width, headerHeight)
	local close = rect(width - pad - headerHeight, top, headerHeight, headerHeight)
	local title = rect(pad, top, close.x - 2 * pad, headerHeight)
	local chart = rect(pad, top + headerHeight + pad / 2, width - 2 * pad, h - headerHeight - pad * 1.5)
	local cellW, cellH = chart.width / M.GRID.columns, chart.height / M.GRID.rows
	local marker = math.clamp(math.floor(cellH * 0.42), 44, 96)
	local tileH = marker + 2 + (text.name + 4) + (text.chip + 4)
	local tileW = math.min(cellW - 8, 240)
	local fits = tileH <= cellH - 2
	local tiles = {}
	for _, island in M.ISLANDS do
		local cx, cy = chart.x + island.cell[1] * cellW, chart.y + island.cell[2] * cellH
		local x = cx + 4 + (cellW - 8 - tileW) * island.nudge[1]
		local y = cy + 1 + math.max(0, cellH - 2 - tileH) * island.nudge[2]
		local tile = rect(x, y, tileW, tileH)
		tiles[island.id] = {
			tile = tile,
			marker = rect(tile.x + (tile.width - marker) / 2, tile.y, marker, marker),
			name = rect(tile.x, tile.y + marker + 2, tile.width, text.name + 4),
			chip = rect(tile.x, tile.y + marker + 2 + text.name + 4, tile.width, text.chip + 4),
		}
	end
	local side = math.floor(math.min(cellW, cellH) * 0.7)
	local compass = rect(
		chart.x + M.COMPASS_CELL[1] * cellW + (cellW - side) / 2,
		chart.y + M.COMPASS_CELL[2] * cellH + (cellH - side) / 2,
		side,
		side
	)
	local button = math.max(44, math.floor(0.12 * h + 0.5))
	local lines = (text.heading + 4) + 2 * (text.chip + 4)
	local sheetH = math.max(math.floor(0.28 * h + 0.5), lines + 2 * pad, button + 2 * pad)
	local sheetW = math.min(width - 2 * pad, 760)
	local sheet = rect((width - sheetW) / 2, top + h - sheetH - pad / 2, sheetW, sheetH)
	local buttonW = math.max(160, math.floor(0.5 * h + 0.5))
	local sail = rect(sheet.x + sheet.width - pad - buttonW, sheet.y + (sheet.height - button) / 2, buttonW, button)
	local textW = sail.x - sheet.x - 2 * pad
	local lineY = sheet.y + (sheet.height - lines) / 2
	local timerH = math.max(28, math.floor(0.08 * h + 0.5))
	local timerW = math.max(240, math.floor(0.62 * h + 0.5))
	return {
		safeHeight = h,
		top = top,
		fits = fits,
		text = text,
		header = header,
		title = title,
		close = close,
		chart = chart,
		tiles = tiles,
		compass = compass,
		sheet = {
			frame = sheet,
			name = rect(sheet.x + pad, lineY, textW, text.heading + 4),
			info = rect(sheet.x + pad, lineY + text.heading + 4, textW, text.chip + 4),
			status = rect(sheet.x + pad, lineY + text.heading + 4 + text.chip + 4, textW, text.chip + 4),
			sail = sail,
		},
		timer = rect((width - timerW) / 2, top + math.floor(0.02 * h + 0.5), timerW, timerH),
	}
end

--- The bottom sheet for a selected island: at the bottom of the chart unless that would cover the
--- selected tile, then at the top of the chart (v65: the harbor card's lines were drawn over the
--- first drift isle's name and chip). The sheet is opaque and drawn above the tiles it covers.
function M.sheetFor(layout: any, islandId: string?): any
	local sheet = layout.sheet
	local tile = if islandId then layout.tiles[islandId] else nil
	if not tile then
		return sheet
	end
	local box, frame = tile.tile, sheet.frame
	local covered = box.y < frame.y + frame.height and frame.y < box.y + box.height
	if not covered then
		return sheet
	end
	local dy = layout.chart.y - frame.y
	local moved = {}
	for key, r in sheet do
		moved[key] = { x = r.x, y = r.y + dy, width = r.width, height = r.height }
	end
	return moved
end

--- Card copy through `text(key, ...)` (cli.chart.* rows). Returns name, band chip and status.
function M.copy(card: any, text: (string, ...any) -> string, now: number?, reason: ((string) -> string)?): any
	local band = card.band
	local chip = if not band
		then text(if card.home then "your_island" elseif card.role == "harbor" then "harbor" else "town")
		elseif band.max then text("band", band.min, band.max)
		else text("band_open", band.min)
	local left = if card.expiresAt and now then M.clock(card.expiresAt - now) else nil
	if card.drift and left then
		chip = chip .. " · " .. left
	end
	local status = if card.here
		then text("here")
		elseif card.needLevel then text("opens_at", card.needLevel)
		elseif card.needRank then text("needs_grade", card.needRank)
		elseif card.viaHarbor then text("via_harbor")
		elseif card.locked then (if reason and card.reason then reason(card.reason) else text("locked"))
		elseif card.drift and left then text("time_left", left)
		else text("open")
	return { name = text("isle." .. card.id), chip = chip, status = status }
end

-- View --------------------------------------------------------------------------------------

local PARCHMENT, INK, LOCK, LILAC = { 185, 165, 140 }, { 27, 34, 36 }, { 110, 116, 119 }, { 154, 143, 181 }
local WASH, HOME = { 127, 163, 91 }, { 201, 154, 59 }
-- U7: each isle is land in its first biome's colour on a sea disc (R19-3 green/brown blobs on
-- parchment); a locked isle keeps its land, faded, under a padlock badge instead of a grey blob.
local SEA, LEATHER, BONE, CLOSE = { 96, 150, 150 }, { 74, 52, 36 }, { 246, 238, 220 }, { 176, 72, 52 }
local LAND: { [string]: { number } } = {
	grassland = { 127, 163, 91 },
	beach = { 226, 204, 152 },
	tropical = { 84, 146, 80 },
	desert = { 208, 164, 98 },
	snow = { 232, 236, 238 },
	volcano = { 132, 74, 62 },
	forest = { 72, 112, 70 },
	swamp = { 104, 114, 72 },
}

-- p134 v60: the chart's close X sits where the HUD minimap is, and the minimap opens the chart, so a
-- second tap on the X spot right after closing reopened it. The minimap ignores taps this long after
-- a close.
M.REOPEN_GUARD = 0.4

--- Whether a minimap tap at `now` may open the chart, the last close having been at `closedAt`
--- (seconds on the same UI clock; nil = never closed).
function M.minimapOpens(closedAt: number?, now: number): boolean
	return closedAt == nil or now - closedAt >= M.REOPEN_GUARD
end

--- Panel factory (ExtensionPanels context plus `text`, `reason`, `biome` and `content`). Opens
--- from the menu tile, the minimap and the world prompts ForgePanel = sea-chart-dock / -rift.
function M.panel(ctx: any): any
	local players = game:GetService("Players")
	local run = game:GetService("RunService")
	local guiService = game:GetService("GuiService")
	local player = players.LocalPlayer
	local function rgb(value: { number }): Color3
		return Color3.fromRGB(value[1], value[2], value[3])
	end
	local function put(item: any, r: any)
		item.Position, item.Size = UDim2.fromOffset(r.x, r.y), UDim2.fromOffset(r.width, r.height)
	end
	local function label(parent: Instance, name: string, size: number, color: { number }): TextLabel
		local item = Instance.new("TextLabel")
		item.Name, item.BackgroundTransparency, item.TextColor3 = name, 1, rgb(color)
		item.Font, item.TextSize, item.TextWrapped = Enum.Font.GothamBold, size, false
		item.TextTruncate, item.Parent = Enum.TextTruncate.AtEnd, parent
		return item
	end
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeSeaChart", false, 31, false
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")
	local hud = Instance.new("ScreenGui")
	hud.Name, hud.ResetOnSpawn, hud.DisplayOrder = "ForgeSeaChartHud", false, 23
	hud.IgnoreGuiInset = true
	hud.Parent = gui.Parent
	-- Parchment: driftPale fill, a darker deckle rim and faint 10% grid lines.
	local sheetFrame = Instance.new("Frame")
	sheetFrame.Name, sheetFrame.BackgroundColor3, sheetFrame.Size = "Chart", rgb(PARCHMENT), UDim2.fromScale(1, 1)
	sheetFrame.Parent = gui
	local rim = Instance.new("UIStroke")
	rim.Color, rim.Thickness, rim.Parent = Color3.fromRGB(138, 117, 96), 6, sheetFrame
	for i = 1, 9 do
		for _, vertical in { true, false } do
			local line = Instance.new("Frame")
			line.Name, line.BorderSizePixel = "Grid", 0
			line.BackgroundColor3, line.BackgroundTransparency = rgb(INK), 0.9
			line.Position = if vertical then UDim2.fromScale(i / 10, 0) else UDim2.fromScale(0, i / 10)
			line.Size = if vertical then UDim2.new(0, 1, 1, 0) else UDim2.new(1, 0, 0, 1)
			line.Parent = sheetFrame
		end
	end
	-- HudShell.sheetOpen reads a visible Frame with Header > Close as a full sheet.
	local header = Instance.new("Frame")
	header.Name, header.BackgroundColor3, header.Parent = "Header", rgb(LEATHER), sheetFrame
	header.BorderSizePixel = 0
	local function art(parent: Instance, name: string, id: string): ImageLabel
		local image = Instance.new("ImageLabel")
		image.Name, image.BackgroundTransparency, image.ScaleType = name, 1, Enum.ScaleType.Fit
		local icon = if ctx.icons then ctx.icons.ui(id) else nil
		image.Image, image.Parent = if icon and icon.image then icon.image else "", parent
		return image
	end
	local headerIcon = art(header, "TitleIcon", "exploration-rank")
	local title = label(sheetFrame, "Title", 20, BONE)
	title.Text, title.TextXAlignment, title.ZIndex = ctx.text("title"), Enum.TextXAlignment.Left, 2
	local close = Instance.new("TextButton")
	close.Name, close.Text, close.TextColor3 = "Close", "X", rgb(BONE)
	close.BackgroundColor3, close.Font, close.Parent = rgb(CLOSE), Enum.Font.GothamBold, header
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius, closeCorner.Parent = UDim.new(0.5, 0), close
	local hint = label(sheetFrame, "PickHint", 14, BONE)
	hint.Text, hint.BackgroundTransparency, hint.BackgroundColor3 = ctx.text("pick"), 0.1, rgb(LEATHER)
	local hintCorner = Instance.new("UICorner")
	hintCorner.CornerRadius, hintCorner.Parent = UDim.new(0.5, 0), hint
	local compass = label(sheetFrame, "Compass", 18, INK)
	compass.Text, compass.TextYAlignment = ctx.text("compass"), Enum.TextYAlignment.Top
	compass.BackgroundColor3, compass.BackgroundTransparency = rgb(BONE), 0.35
	local rose = art(compass, "Rose", "explore")
	rose.AnchorPoint, rose.Position = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.58)
	rose.Size = UDim2.fromScale(0.6, 0.6)
	-- Border mode: a UIStroke on a TextLabel defaults to Contextual and outlines the glyph, which
	-- read as an unlabelled black blob under the frontier50 isle (staging v40).
	local compassRing = Instance.new("UIStroke")
	compassRing.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	compassRing.Color, compassRing.Thickness, compassRing.Parent = rgb(INK), 2, compass
	local compassCorner = Instance.new("UICorner")
	compassCorner.CornerRadius, compassCorner.Parent = UDim.new(0.5, 0), compass
	local tiles: { [string]: any } = {}
	local selected: string? = nil
	local status: string? = nil
	local mode = "view"
	-- 'Show the dock' state (see markDock below): the card's primary walks to the nearest sail spot.
	local showDock, refusedReach = false, false
	local nearestDock: () -> Vector3?, rootPosition: () -> Vector3?
	local setOpen: (boolean, string) -> ()
	local closedAt: number? = nil
	local cards: { any } = {}
	local latest: any, received = nil, os.clock()
	local sheet = Instance.new("Frame")
	sheet.Name, sheet.BackgroundColor3, sheet.Visible = "IslandSheet", Color3.fromRGB(237, 230, 214), false
	-- Above the isle tiles (ZIndex 1) it covers, below its own lines and button (ZIndex 3).
	sheet.ZIndex = 2
	sheet.Parent = sheetFrame
	local sheetCorner = Instance.new("UICorner")
	sheetCorner.CornerRadius, sheetCorner.Parent = UDim.new(0, 12), sheet
	local sheetStroke = Instance.new("UIStroke")
	sheetStroke.Color, sheetStroke.Thickness, sheetStroke.Parent = Color3.fromRGB(122, 92, 62), 3, sheet
	local sheetName = label(sheetFrame, "SheetName", 16, INK)
	local sheetInfo = label(sheetFrame, "SheetInfo", 13, INK)
	local sheetStatus = label(sheetFrame, "SheetStatus", 13, INK)
	for _, item in { sheetName, sheetInfo, sheetStatus } do
		item.TextXAlignment, item.ZIndex, item.Visible = Enum.TextXAlignment.Left, 3, false
	end
	local sail = Instance.new("TextButton")
	sail.Name, sail.BackgroundColor3, sail.TextColor3 =
		"Sail", Color3.fromRGB(31, 78, 76), Color3.fromRGB(237, 230, 214)
	sail.Font, sail.ZIndex, sail.Visible, sail.Parent = Enum.Font.GothamBold, 3, false, sheetFrame
	local sailCorner = Instance.new("UICorner")
	sailCorner.CornerRadius, sailCorner.Parent = UDim.new(0, 10), sail
	local timer = label(hud, "DriftTimer", 14, { 237, 230, 214 })
	timer.BackgroundTransparency, timer.BackgroundColor3, timer.Visible = 0.2, rgb(LILAC), false
	-- The HUD's contextual banner (hunger tip) steers around the pill (HudShell.HUD_PILL_TAG).
	timer:AddTag("ForgeHudPill")
	local timerCorner = Instance.new("UICorner")
	timerCorner.CornerRadius, timerCorner.Parent = UDim.new(0.5, 0), timer
	-- The round HUD minimap (HudShell overlays) opens the chart: a transparent button fills it.
	local minimap = Instance.new("TextButton")
	minimap.Name, minimap.Text, minimap.BackgroundTransparency = "MinimapChart", "", 1
	minimap.Size, minimap.ZIndex = UDim2.fromScale(1, 1), 5
	local function now(): number
		local expedition = latest and latest.expedition
		return (if expedition and expedition.now then expedition.now else 0) + (os.clock() - received)
	end
	local function view(): any
		local expedition = latest and latest.expedition or {}
		local trip = latest and latest.archipelago
		return {
			role = workspace:GetAttribute("ForgeWorldRole") or "harbor",
			level = if expedition.facts then expedition.facts.level else 1,
			facts = expedition.facts,
			routes = expedition.routes,
			trip = if trip and trip.status then trip else nil,
		}
	end
	-- Both guis IgnoreGuiInset, so gui y 0 is the screen top and TopbarInset.Max.Y is the clearance.
	-- HudShell.guiClear also subtracted the gui's AbsolutePosition.Y (-58 on the phone) and cleared
	-- the bar twice: 116 px of 411, rows shorter than a tile, labels over the next row (v40).
	local function topClear(): number
		local inset = if guiService then guiService.TopbarInset else nil
		return if inset then inset.Max.Y else 0
	end
	local function render()
		local size = gui.AbsoluteSize
		local layout = M.layout(size.X, size.Y, topClear())
		local sizes = layout.text
		put(header, layout.header)
		put(title, layout.title)
		title.TextSize = sizes.title
		-- Header icon left of the title (U7): the title starts one icon width further right.
		local iconSide = math.floor(layout.header.height * 0.72)
		headerIcon.Size = UDim2.fromOffset(iconSide, iconSide)
		headerIcon.Position = UDim2.fromOffset(layout.title.x - layout.header.x, (layout.header.height - iconSide) // 2)
		title.Position = UDim2.fromOffset(layout.title.x + iconSide + 8, layout.title.y)
		title.Size = UDim2.fromOffset(layout.title.width - iconSide - 8, layout.title.height)
		-- Close is a child of Header (HudShell.sheetOpen reads Header > Close): header-relative.
		put(close, layout.close)
		close.Position = UDim2.fromOffset(layout.close.x - layout.header.x, layout.close.y - layout.header.y)
		close.TextSize = sizes.heading
		put(compass, layout.compass)
		compass.TextSize = sizes.chip
		cards = M.islands(ctx.content, view())
		local t = now()
		for _, card in cards do
			local r = layout.tiles[card.id]
			local tile = tiles[card.id]
			local copy = M.copy(card, ctx.text, t, ctx.reason)
			put(tile.marker, r.marker)
			put(tile.name, r.name)
			put(tile.chip, r.chip)
			tile.name.Text, tile.name.TextSize = copy.name, sizes.name
			tile.chip.Text, tile.chip.TextSize = copy.chip, sizes.chip
			-- Sea disc with the isle's land; home is gold, the current isle has a thick bone ring.
			tile.marker.BackgroundColor3 = rgb(if card.home then HOME else SEA)
			tile.marker.BackgroundTransparency = if card.locked then 0.45 else 0.1
			tile.land.BackgroundColor3 = rgb(LAND[(card.biomes or {})[1] or ""] or WASH)
			tile.land.BackgroundTransparency = if card.locked then 0.5 else 0
			tile.land.Visible = not card.home
			tile.stroke.Color = rgb(if card.here then BONE elseif card.drift then LILAC else INK)
			tile.stroke.Thickness = if card.here then 5 elseif card.id == selected then 4 else 2
			tile.lock.Visible = card.locked
			tile.name.TextColor3 = rgb(if card.locked then LOCK else INK)
			tile.rift.Visible = card.rift
			-- Drift isles: the band chip carries the window countdown as a lilac pill.
			local counting = card.drift and card.expiresAt ~= nil
			tile.chip.BackgroundColor3 = rgb(if counting then LILAC else BONE)
			tile.chip.BackgroundTransparency = if counting then 0.25 else 0.45
			if card.id == selected then
				local placed = M.sheetFor(layout, selected)
				put(sheet, placed.frame)
				put(sheetName, placed.name)
				put(sheetInfo, placed.info)
				put(sheetStatus, placed.status)
				put(sail, placed.sail)
				sheetName.TextSize, sheetInfo.TextSize, sheetStatus.TextSize = sizes.heading, sizes.chip, sizes.chip
				sail.TextSize = sizes.heading
				local climate = {}
				for _, biome in card.biomes do
					table.insert(climate, ctx.biome(biome))
				end
				sheetName.Text = copy.name .. (if card.drift then " · " .. ctx.text("drift") else "")
				sheetInfo.Text = copy.chip .. (if #climate > 0 then " · " .. table.concat(climate, ", ") else "")
				sheetStatus.Text = status or copy.status
				-- Away from every dock and rift (or refused for reach) an open island's primary is
				-- 'show the dock' and the status names why (p134 v68).
				local openCard = (not card.locked or card.viaHarbor == true) and not card.here
				showDock = openCard
					and mode == "view"
					and (refusedReach or M.awayFromDock(rootPosition(), nearestDock()))
					and nearestDock() ~= nil
				if showDock and not status then
					sheetStatus.Text = ctx.reason("sail_unreachable")
				end
				sail.Text = ctx.text(
					if showDock
						then "show_dock"
						elseif card.viaHarbor then "sail_harbor"
						elseif mode == "rift" then "step"
						else "sail"
				)
				sail.Active = openCard
				sail.AutoButtonColor = sail.Active
				sail.BackgroundTransparency = if sail.Active then 0 else 0.5
			end
		end
		local shown = selected ~= nil
		for _, item: GuiObject in { sheet :: GuiObject, sheetName, sheetInfo, sheetStatus, sail } do
			item.Visible = shown
		end
		-- Nothing picked yet: one pill in the header strip, between the title and Close, says what to
		-- do (sheets3: at the sheet's slot it covered the bottom row's isle names and band chips).
		hint.Visible = not shown
		if not shown then
			local hintH = math.min(layout.header.height - 8, sizes.name + 14)
			local right = layout.close.x - 12
			local left = layout.title.x
				+ iconSide
				+ 8
				+ math.floor(sizes.title * (utf8.len(title.Text) or 4) + 0.5)
				+ 16
			local hintW =
				math.min(math.max(0, right - left), math.floor(sizes.name * 0.62 * (utf8.len(hint.Text) or 20) + 48))
			put(hint, {
				x = right - hintW,
				y = layout.header.y + (layout.header.height - hintH) // 2,
				width = hintW,
				height = hintH,
			})
			hint.TextSize, hint.ZIndex = sizes.name, 3
			hint.BackgroundColor3, hint.BackgroundTransparency = rgb(BONE), 0.82
		end
		-- HUD: the drift-isle countdown on an active drift isle, and the minimap as a chart opener.
		local playerGui = gui.Parent :: Instance
		local mapParent = minimap.Parent
		if mapParent == nil or not mapParent:IsDescendantOf(playerGui) then
			minimap.Parent = playerGui:FindFirstChild("Minimap", true)
		end
		local trip = latest and latest.archipelago
		-- A boolean: `and trip.expiresAt` yielded a number, `== true` was always false and the pill
		-- never showed. It shows only on an active drift isle, never in onboarding, home or town.
		local drifting = workspace:GetAttribute("ForgeWorldRole") == "archipelago"
			and trip ~= nil
			and trip.status == "active"
			and type(trip.expiresAt) == "number"
		timer.Visible = drifting and not gui.Enabled
		if timer.Visible then
			put(timer, layout.timer)
			timer.TextSize = sizes.name
			timer.Text = ctx.text("hud_timer", M.clock(trip.expiresAt - t))
		end
	end
	for _, island in M.ISLANDS do
		local marker = Instance.new("TextButton")
		marker.Name, marker.Text, marker.Parent = "Isle-" .. island.id, "", sheetFrame
		local corner = Instance.new("UICorner")
		corner.CornerRadius, corner.Parent = UDim.new(0.45, 0), marker
		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode, stroke.Parent = Enum.ApplyStrokeMode.Border, marker
		-- Land: an off-centre rounded blob inside the sea disc.
		local land = Instance.new("Frame")
		land.Name, land.BorderSizePixel, land.Rotation = "Land", 0, 18
		land.AnchorPoint, land.Position = Vector2.new(0.5, 0.5), UDim2.fromScale(0.48, 0.52)
		land.Size, land.Parent = UDim2.fromScale(0.62, 0.5), marker
		local landCorner = Instance.new("UICorner")
		landCorner.CornerRadius, landCorner.Parent = UDim.new(0.5, 0), land
		local lock = Instance.new("Frame")
		lock.Name, lock.BackgroundColor3, lock.Size = "Lock", rgb(BONE), UDim2.fromScale(0.42, 0.42)
		lock.Position, lock.AnchorPoint, lock.Parent = UDim2.fromScale(1.04, 1.04), Vector2.new(1, 1), marker
		local lockCorner = Instance.new("UICorner")
		lockCorner.CornerRadius, lockCorner.Parent = UDim.new(0.5, 0), lock
		local padlock = art(lock, "Padlock", "locked")
		padlock.Position, padlock.Size = UDim2.fromScale(0.1, 0.1), UDim2.fromScale(0.8, 0.8)
		-- Rift badge (top-left, opposite the lock): a lilac disc with an ink rim and a bone fissure.
		local rift = Instance.new("Frame")
		rift.Name, rift.BackgroundColor3, rift.Size = "Rift", rgb(LILAC), UDim2.fromScale(0.4, 0.4)
		rift.Position, rift.Visible, rift.Parent = UDim2.fromScale(0, 0), false, marker
		local riftCorner = Instance.new("UICorner")
		riftCorner.CornerRadius, riftCorner.Parent = UDim.new(0.5, 0), rift
		local riftRim = Instance.new("UIStroke")
		riftRim.ApplyStrokeMode, riftRim.Color, riftRim.Thickness = Enum.ApplyStrokeMode.Border, rgb(INK), 1.5
		riftRim.Parent = rift
		local fissure = Instance.new("Frame")
		fissure.Name, fissure.BorderSizePixel, fissure.BackgroundColor3 = "Fissure", 0, Color3.fromRGB(237, 230, 214)
		fissure.AnchorPoint, fissure.Position = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
		fissure.Size, fissure.Rotation, fissure.Parent = UDim2.fromScale(0.18, 0.7), 20, rift
		local name = label(sheetFrame, "Name-" .. island.id, 14, INK)
		local chip = label(sheetFrame, "Chip-" .. island.id, 13, INK)
		local chipCorner = Instance.new("UICorner")
		chipCorner.CornerRadius, chipCorner.Parent = UDim.new(0.5, 0), chip
		tiles[island.id] =
			{ marker = marker, stroke = stroke, land = land, lock = lock, rift = rift, name = name, chip = chip }
		marker.Activated:Connect(function()
			selected, status = island.id, nil
			render()
		end)
	end
	local busy = false
	-- 'Show the dock' (p134 v68): away from every dock and rift the card's primary walks to the
	-- nearest sail spot (TapRouter pathfinding via ctx.walkTo) and pins the Waypoint marker (arrow,
	-- minimap pin, beam) on it; the opening's own step marker yields while it is pinned. Opening the
	-- chart away from a dock arms the marker for DOCK_MARK_SECONDS after it closes, pressed or not.
	local Waypoint = require("./Waypoint")
	local dockWay: any = nil
	local dockTarget: Vector3? = nil
	local dockUntil: number? = nil -- presentation clock; nil while pinned by the button
	function rootPosition(): Vector3?
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		return if root then root.Position else nil
	end
	function nearestDock(): Vector3?
		local world = workspace:FindFirstChild("ForgeRoleWorld")
		local at = rootPosition()
		local spot = if world and at then M.nearestSpot(world:GetAttribute("ForgeSailSpots"), at) else nil
		return if spot then Vector3.new(spot.X, spot.Y, spot.Z) else nil
	end
	local function markDock(target: Vector3?, pinned: boolean)
		dockTarget = target
		dockUntil = if target and not pinned then os.clock() + M.DOCK_MARK_SECONDS else nil
		player:SetAttribute(Waypoint.OVERRIDE_ATTRIBUTE, if target and pinned then target else nil)
		if target and not dockWay then
			local playerGui = player:WaitForChild("PlayerGui")
			local minimapCache: Instance? = nil
			dockWay = Waypoint.start({
				name = "ForgeDockWaypoint",
				playerGui = playerGui,
				stage = workspace,
				camera = function()
					return workspace.CurrentCamera
				end,
				minimap = function(): any
					if not minimapCache or not minimapCache:IsDescendantOf(playerGui) then
						minimapCache = playerGui:FindFirstChild("Minimap", true)
					end
					return minimapCache
				end,
				label = function(meters: number): string
					return ctx.text("dock_meters", meters)
				end,
				color = Color3.fromRGB(110, 196, 178),
			})
			dockWay.beam.Name = "DockBeam"
			dockWay.arrow.Activated:Connect(function()
				if dockTarget and ctx.walkTo then
					ctx.walkTo(dockTarget, M.DOCK_ARRIVE)
				end
			end)
		end
	end
	local function stepDock()
		if not dockWay then
			return
		end
		local at = rootPosition()
		local expired = dockUntil ~= nil and not gui.Enabled and os.clock() > dockUntil
		if dockTarget and (expired or (at and not Waypoint.shown(at, dockTarget))) then
			markDock(nil, false) -- arrived (or the unpressed mark ran out)
		end
		dockWay.step(at, dockTarget)
		-- The arrow is a button: it never sits over the chart or another sheet.
		dockWay.gui.Enabled = not gui.Enabled
			and not Waypoint.covered(gui.Parent, function(name: string): any
				return player:GetAttribute(name)
			end)
	end
	sail.Activated:Connect(function()
		local card: any = nil
		for _, candidate in cards do
			card = if candidate.id == selected then candidate else card
		end
		if busy or not card or (card.locked and not card.viaHarbor) or card.here then
			return
		end
		if showDock then
			local target = nearestDock()
			if target then
				markDock(target, true)
				if ctx.walkTo then
					ctx.walkTo(target, M.DOCK_ARRIVE)
				end
				closedAt = os.clock()
				setOpen(false, "view")
			end
			return
		end
		busy = true
		local function go(): any
			return if card.viaHarbor
				then ctx.send("survival-coop:mission-action", { "sail", "harbor" })
				elseif card.drift then ctx.send("survival-coop:party-action", { "depart", tostring(card.route) })
				else ctx.send("survival-coop:mission-action", { "sail", card.role })
		end
		local result = go()
		for _ = 1, M.SAIL_RETRIES do
			if not (result and result.reason == "COMMAND_PENDING") then
				break
			end
			task.wait(M.SAIL_RETRY_SECONDS)
			result = go()
		end
		busy = false
		local reason = if result and result.ok then "travelling" else (result and result.reason or "travel_refused")
		status = ctx.reason(reason)
		-- The server refused for reach: the card's primary turns into 'show the dock'.
		refusedReach = reason == "sail_unreachable"
		render()
	end)
	function setOpen(open: boolean, opened: string)
		gui.Enabled = open
		mode = opened
		refusedReach = false
		if not open then
			selected, status = nil, nil
		elseif opened == "view" and dockTarget == nil then
			local target = nearestDock()
			if M.awayFromDock(rootPosition(), target) then
				markDock(target, false)
			end
		end
		render()
	end
	local function isOpen(): boolean
		return gui.Enabled
	end
	local entries = {}
	for index, id in { "sea-chart", "sea-chart-dock", "sea-chart-rift" } do
		local opened = if index == 1 then "view" elseif index == 2 then "dock" else "rift"
		table.insert(
			entries,
			ctx.dock({
				id = id,
				label = ctx.text("title"),
				order = 60 + index,
				hidden = index > 1,
				setOpen = function(value: boolean)
					setOpen(value, opened)
				end,
				isOpen = isOpen,
			})
		)
	end
	-- UI debounce only (presentation clock, never game logic).
	close.Activated:Connect(function()
		closedAt = os.clock()
		setOpen(false, "view")
	end)
	minimap.Activated:Connect(function()
		if M.minimapOpens(closedAt, os.clock()) then
			entries[1].open()
		end
	end)
	local stop = ctx.onSnapshot(function(snapshot)
		latest, received = snapshot, os.clock()
		render()
	end)
	local elapsed = 0
	local beat = run.Heartbeat:Connect(function(dt)
		stepDock()
		elapsed += dt
		if elapsed >= 0.5 then
			elapsed = 0
			render()
		end
	end)
	return {
		destroy = function()
			stop()
			beat:Disconnect()
			if dockWay then
				dockWay.destroy()
			end
			player:SetAttribute(Waypoint.OVERRIDE_ATTRIBUTE, nil)
			gui:Destroy()
			hud:Destroy()
			minimap:Destroy()
		end,
	}
end

return M
